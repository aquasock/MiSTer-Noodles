// BLIT_COPY / BLIT_COPY_KEY pixel compositor.  Reads are issued ahead of
// writes through the generic read port, while small FIFOs preserve source
// order and destination addresses.  The DDRAM adapter accepts up to four
// ordered outstanding reads; writes remain serialized by the shared adapter.

module blit_copy #(
    parameter int ADDR_WIDTH      = 32,
    parameter int DATA_WIDTH      = 32,
    parameter int BYTES_PER_PIXEL = 4,
    parameter int FIFO_DEPTH      = 8
) (
    input logic clk, input logic reset,
    input logic start,
    input logic [ADDR_WIDTH-1:0] dst_addr,
    input logic [15:0] dst_pitch,
    input logic [ADDR_WIDTH-1:0] src_addr,
    input logic [15:0] src_pitch,
    input logic [15:0] width, input logic [15:0] height,
    input logic key_enable, input logic [DATA_WIDTH-1:0] key_value,
    output logic busy, output logic done,
    output logic [ADDR_WIDTH-1:0] rd_addr, output logic rd_en,
    input logic rd_ready, input logic [DATA_WIDTH-1:0] rd_data, input logic rd_valid,
    output logic [ADDR_WIDTH-1:0] wr_addr, output logic [DATA_WIDTH-1:0] wr_data,
    output logic wr_en, input logic wr_ready
);
    localparam int PTR_W = $clog2(FIFO_DEPTH);
    logic [ADDR_WIDTH-1:0] addr_fifo [0:FIFO_DEPTH-1];
    logic [ADDR_WIDTH-1:0] write_addr_fifo [0:FIFO_DEPTH-1];
    logic [DATA_WIDTH-1:0] data_fifo [0:FIFO_DEPTH-1];
    logic [PTR_W-1:0] addr_wr_ptr, addr_rd_ptr, data_wr_ptr, data_rd_ptr;
    logic [PTR_W:0] addr_count, data_count;
    logic [15:0] issue_col, issue_row;
    logic [31:0] issued, total_pixels;
    logic [15:0] width_r;
    logic [15:0] dst_pitch_r, src_pitch_r;
    logic [ADDR_WIDTH-1:0] src_row_addr, dst_row_addr;
    logic key_enable_r;
    logic [DATA_WIDTH-1:0] key_value_r;
    logic active;

    // The adapter can hold four requests while this engine can retain up to
    // FIFO_DEPTH source addresses and completed pixels.
    wire issue_space = (addr_count < FIFO_DEPTH) &&
                       (addr_count + data_count < FIFO_DEPTH * 2);
    wire all_issued = (issued == total_pixels);
    wire key_match = key_enable_r && (data_fifo[data_rd_ptr] == key_value_r);
    wire do_write = active && data_count != 0 && !key_match;

    assign rd_addr = src_row_addr + ADDR_WIDTH'(issue_col) * BYTES_PER_PIXEL;
    // Leave room for returned data so the shared adapter can switch to the
    // write side and drain the response FIFO instead of overrunning it.
    // Keep the response queue shallow so destination writes are interleaved
    // with source reads instead of arriving as long four-pixel bursts.
    assign rd_en = active && !all_issued && issue_space && (data_count < 3);
    assign wr_addr = write_addr_fifo[data_rd_ptr];
    assign wr_data = data_fifo[data_rd_ptr];
    assign wr_en = do_write;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            busy <= 0; done <= 0; active <= 0;
            addr_wr_ptr <= 0; addr_rd_ptr <= 0; data_wr_ptr <= 0; data_rd_ptr <= 0;
            addr_count <= 0; data_count <= 0; issued <= 0; total_pixels <= 0;
            issue_col <= 0; issue_row <= 0; src_row_addr <= 0; dst_row_addr <= 0;
            width_r <= 0; dst_pitch_r <= 0; src_pitch_r <= 0;
            key_enable_r <= 0; key_value_r <= 0;
        end else begin
            done <= 0;

            if (!active && start && width != 0 && height != 0) begin
                active <= 1; busy <= 1;
                width_r <= width;
                dst_pitch_r <= dst_pitch; src_pitch_r <= src_pitch;
                key_enable_r <= key_enable; key_value_r <= key_value;
                issue_col <= 0; issue_row <= 0;
                src_row_addr <= src_addr; dst_row_addr <= dst_addr;
                issued <= 0; total_pixels <= width * height;
                addr_wr_ptr <= 0; addr_rd_ptr <= 0;
                data_wr_ptr <= 0; data_rd_ptr <= 0;
                addr_count <= 0; data_count <= 0;
            end else if (active) begin
                if (rd_en && rd_ready) begin
                    addr_fifo[addr_wr_ptr] <= dst_row_addr + ADDR_WIDTH'(issue_col) * BYTES_PER_PIXEL;
                    addr_wr_ptr <= addr_wr_ptr + 1'b1;
                    issued <= issued + 1'b1;
                    if (issue_col == width_r - 1) begin
                        issue_col <= 0;
                        issue_row <= issue_row + 1'b1;
                        src_row_addr <= src_row_addr + ADDR_WIDTH'(src_pitch_r);
                        dst_row_addr <= dst_row_addr + ADDR_WIDTH'(dst_pitch_r);
                    end else begin
                        issue_col <= issue_col + 1'b1;
                    end
                end

                if (rd_valid) begin
                    write_addr_fifo[data_wr_ptr] <= addr_fifo[addr_rd_ptr];
                    data_fifo[data_wr_ptr] <= rd_data;
                    data_wr_ptr <= data_wr_ptr + 1'b1;
                end
                if (rd_valid) addr_rd_ptr <= addr_rd_ptr + 1'b1;
                case ({rd_en && rd_ready, rd_valid})
                    2'b10: addr_count <= addr_count + 1'b1;
                    2'b01: addr_count <= addr_count - 1'b1;
                    default: addr_count <= addr_count;
                endcase

                if ((do_write && wr_ready) || (data_count != 0 && key_match)) begin
                    data_rd_ptr <= data_rd_ptr + 1'b1;
                end

                case ({rd_valid, ((do_write && wr_ready) || (data_count != 0 && key_match))})
                    2'b10: data_count <= data_count + 1'b1;
                    2'b01: data_count <= data_count - 1'b1;
                    default: data_count <= data_count;
                endcase

                if (all_issued && addr_count == 0 && data_count == 0 && !rd_valid) begin
                    active <= 0; busy <= 0; done <= 1;
                end
            end
        end
    end
endmodule
