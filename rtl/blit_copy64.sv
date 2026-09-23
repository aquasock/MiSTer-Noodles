// Coalesced sprite compositor.  Aligned source pixels are fetched two at a
// time; destination writes use a full DDRAM word only when both pixels are
// drawable and naturally aligned, otherwise the pair is retired as ordered
// half-word writes.  The pair FIFO counts requests, responses, and retired
// pixels independently so keyed pixels cannot confuse completion.
module blit_copy64 #(
    parameter int ADDR_WIDTH = 32,
    parameter int FIFO_DEPTH = 4
) (
    input logic clk, input logic reset,
    input logic start,
    input logic [ADDR_WIDTH-1:0] dst_addr,
    input logic [15:0] dst_pitch,
    input logic [ADDR_WIDTH-1:0] src_addr,
    input logic [15:0] src_pitch,
    input logic [15:0] width, input logic [15:0] height,
    input logic key_enable, input logic [31:0] key_value,
    output logic busy, output logic done,
    output logic [ADDR_WIDTH-1:0] rd64_addr, output logic rd64_en,
    input logic rd64_ready,
    input logic [63:0] rd64_data, input logic rd64_valid,
    output logic [ADDR_WIDTH-1:0] wr_addr, output logic [31:0] wr_data,
    output logic wr_en, input logic wr_ready,
    output logic [ADDR_WIDTH-1:0] wr64_addr,
    output logic [63:0] wr64_data, output logic wr64_en,
    input logic wr64_ready
);
    logic [ADDR_WIDTH-1:0] dst0_fifo [0:FIFO_DEPTH-1];
    logic [ADDR_WIDTH-1:0] dst1_fifo [0:FIFO_DEPTH-1];
    logic [63:0] data_fifo [0:FIFO_DEPTH-1];
    logic [FIFO_DEPTH-1:0] valid_fifo;
    logic [$clog2(FIFO_DEPTH)-1:0] wr_ptr, rd_ptr;
    logic [$clog2(FIFO_DEPTH)-1:0] resp_ptr;
    logic [3:0] pair_count;
    logic [15:0] col, row, width_r, height_r;
    logic [31:0] pairs_issued, pairs_done, total_pairs;
    logic [ADDR_WIDTH-1:0] src_row, dst_row;
    logic [15:0] dst_pitch_r, src_pitch_r;
    logic key_enable_r;
    logic [31:0] key_r;
    logic active, scalar_tail;
    logic scalar_second;

    wire lower_key = key_enable_r && data_fifo[rd_ptr][31:0] == key_r;
    wire upper_key = key_enable_r && data_fifo[rd_ptr][63:32] == key_r;
    wire pair_ready = active && pair_count != 0 && valid_fifo[rd_ptr];
    wire paired_write = pair_ready && !lower_key && !upper_key &&
                         (dst0_fifo[rd_ptr][2] == 1'b0) &&
                         (dst1_fifo[rd_ptr] == dst0_fifo[rd_ptr] + 32'd4);
    wire scalar_first_skip = pair_ready && !paired_write &&
                             !scalar_second && lower_key;
    wire scalar_first_write = pair_ready && !paired_write &&
                              !scalar_second && !lower_key && wr_ready;
    wire scalar_second_skip = pair_ready && !paired_write &&
                              scalar_second && upper_key;
    wire scalar_second_write = pair_ready && !paired_write &&
                               scalar_second && !upper_key && wr_ready;
    wire scalar_write = scalar_first_write || scalar_second_write;
    wire scalar_pair_done = scalar_second_skip || scalar_second_write ||
                            (scalar_first_write && upper_key);
    wire scalar_advance = scalar_first_skip ||
                          (scalar_first_write && !upper_key);

    assign rd64_en = active && !scalar_tail && (pairs_issued < total_pairs) &&
                     (pair_count < FIFO_DEPTH);
    assign rd64_addr = src_row + col * 4;
    assign wr64_addr = dst0_fifo[rd_ptr];
    assign wr64_data = data_fifo[rd_ptr];
    assign wr64_en = paired_write;
    assign wr_addr = scalar_second ? dst1_fifo[rd_ptr] : dst0_fifo[rd_ptr];
    assign wr_data = scalar_second ? data_fifo[rd_ptr][63:32] :
                                     data_fifo[rd_ptr][31:0];
    assign wr_en = scalar_write;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            busy <= 0; done <= 0; active <= 0; scalar_tail <= 0;
            pair_count <= 0; wr_ptr <= 0; rd_ptr <= 0; resp_ptr <= 0; valid_fifo <= 0;
            scalar_second <= 0;
            col <= 0; row <= 0; width_r <= 0; height_r <= 0;
            pairs_issued <= 0; pairs_done <= 0; total_pairs <= 0;
            src_row <= 0; dst_row <= 0; dst_pitch_r <= 0; src_pitch_r <= 0;
            key_enable_r <= 0; key_r <= 0;
        end else begin
            done <= 0;
            if (!active && start && width != 0 && height != 0) begin
                active <= 1; busy <= 1; col <= 0; row <= 0;
                width_r <= width; height_r <= height;
                dst_pitch_r <= dst_pitch; src_pitch_r <= src_pitch;
                src_row <= src_addr; dst_row <= dst_addr;
                key_enable_r <= key_enable; key_r <= key_value;
                pairs_issued <= 0; pairs_done <= 0;
                total_pairs <= (width * height) >> 1;
                pair_count <= 0; valid_fifo <= 0; wr_ptr <= 0; rd_ptr <= 0; resp_ptr <= 0;
                scalar_second <= 0;
                scalar_tail <= 0;
            end else if (active) begin
                if (rd64_en && rd64_ready) begin
                    dst0_fifo[wr_ptr] <= dst_row + col * 4;
                    dst1_fifo[wr_ptr] <= dst_row + (col + 1) * 4;
                    valid_fifo[wr_ptr] <= 1'b0;
                    wr_ptr <= wr_ptr + 1'b1;
                    pairs_issued <= pairs_issued + 1'b1;
                    if (col + 2 >= width_r) begin
                        col <= 0; row <= row + 1'b1;
                        src_row <= src_row + src_pitch_r;
                        dst_row <= dst_row + dst_pitch_r;
                    end else col <= col + 2;
                end
                if (rd64_valid) begin
                    data_fifo[resp_ptr] <= rd64_data;
                    valid_fifo[resp_ptr] <= 1'b1;
                    resp_ptr <= resp_ptr + 1'b1;
                end
                case ({rd64_valid, (paired_write && wr64_ready) ||
                      (scalar_pair_done)})
                    2'b10: pair_count <= pair_count + 1'b1;
                    2'b01: begin
                        valid_fifo[rd_ptr] <= 1'b0;
                        rd_ptr <= rd_ptr + 1'b1;
                        pair_count <= pair_count - 1'b1;
                        pairs_done <= pairs_done + 1'b1;
                        scalar_second <= 1'b0;
                    end
                    default: pair_count <= pair_count;
                endcase
                if (scalar_advance)
                    scalar_second <= 1'b1;
                if ((paired_write && wr64_ready) ||
                    scalar_pair_done) begin
                    valid_fifo[rd_ptr] <= 1'b0;
                    rd_ptr <= rd_ptr + 1'b1;
                    pairs_done <= pairs_done + 1'b1;
                    scalar_second <= 1'b0;
                end
                if (pairs_issued == total_pairs && pair_count == 0 &&
                    !rd64_valid && row >= height_r) begin
                    active <= 0; busy <= 0; done <= 1;
                end
            end
        end
    end
endmodule
