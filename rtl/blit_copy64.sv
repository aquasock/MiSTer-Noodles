// Coalesced sprite compositor.  Aligned source pixels are fetched two at a
// time; destination writes use a full DDRAM word only when both pixels are
// drawable and naturally aligned, otherwise the pair is retired as ordered
// half-word writes.  The pair FIFO counts requests, responses, and retired
// pixels independently so keyed pixels cannot confuse completion.
//
// DDR-007: reads are issued as an explicit multi-pair burst request
// (rd64_len declares how many contiguous pairs to fetch) instead of one
// rd64_en pulse per pair. A burst never crosses a row boundary (source rows
// are not necessarily contiguous in DRAM) and never exceeds the FIFO's own
// free capacity, so this is purely a request-shape change: the same pairs
// are still fetched in the same order, one 64-bit response per pair,
// consumed by the unchanged response/write-out logic below.
module blit_copy64 #(
    parameter int ADDR_WIDTH = 32,
    parameter int FIFO_DEPTH = 8
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
    output logic [7:0] rd64_len,
    input logic rd64_ready,
    input logic [63:0] rd64_data, input logic rd64_valid,
    output logic [ADDR_WIDTH-1:0] wr_addr, output logic [31:0] wr_data,
    output logic wr_en, input logic wr_ready,
    output logic [ADDR_WIDTH-1:0] wr64_addr,
    output logic [63:0] wr64_data, output logic wr64_en,
    input logic wr64_ready
);
    localparam int PTR_W = $clog2(FIFO_DEPTH);
    localparam int LENB = $clog2(FIFO_DEPTH + 1);

    logic [ADDR_WIDTH-1:0] dst0_fifo [0:FIFO_DEPTH-1];
    logic [ADDR_WIDTH-1:0] dst1_fifo [0:FIFO_DEPTH-1];
    logic [63:0] data_fifo [0:FIFO_DEPTH-1];
    logic [FIFO_DEPTH-1:0] valid_fifo;
    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    logic [PTR_W-1:0] resp_ptr;
    logic [3:0] pair_count;
    // Pairs reserved (fifo slots claimed) since their read was accepted,
    // freed only once written out -- distinct from pair_count, which only
    // starts counting once a pair's DATA has actually arrived. Gates new
    // burst requests so wr_ptr can never lap rd_ptr regardless of how many
    // requests are still in flight awaiting their response.
    logic [3:0] reserved_count;
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
    wire write_complete = (paired_write && wr64_ready) || scalar_pair_done;

    // How many contiguous pairs can be requested right now: bounded by free
    // FIFO capacity and by the pairs remaining in the current source row
    // (crossing into the next row means a non-contiguous DRAM address, so
    // it must end this burst, not extend it).
    wire [15:0] avail_pairs = 16'(FIFO_DEPTH) - {12'b0, reserved_count};
    wire [15:0] row_remain = (width_r - col) >> 1;
    wire [15:0] want_len16 = (row_remain < avail_pairs) ? row_remain : avail_pairs;
    wire [LENB-1:0] want_len = want_len16[LENB-1:0];
    wire [15:0] new_col = col + {want_len16[14:0], 1'b0};

    assign rd64_en = active && !scalar_tail && (pairs_issued < total_pairs) &&
                     (want_len != 0);
    assign rd64_len = {{(8-LENB){1'b0}}, want_len};
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
            pair_count <= 0; reserved_count <= 0;
            wr_ptr <= 0; rd_ptr <= 0; resp_ptr <= 0; valid_fifo <= 0;
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
                pair_count <= 0; reserved_count <= 0;
                valid_fifo <= 0; wr_ptr <= 0; rd_ptr <= 0; resp_ptr <= 0;
                scalar_second <= 0;
                scalar_tail <= 0;
            end else if (active) begin
                if (rd64_en && rd64_ready) begin
                    for (int i = 0; i < FIFO_DEPTH; i++) begin
                        if (i < int'(want_len)) begin
                            automatic logic [PTR_W-1:0] idx = wr_ptr + i[PTR_W-1:0];
                            automatic logic [15:0] pair_col = col + 16'(2 * i);
                            dst0_fifo[idx] <= dst_row + ADDR_WIDTH'(pair_col) * 4;
                            dst1_fifo[idx] <= dst_row + ADDR_WIDTH'(pair_col + 16'd1) * 4;
                            valid_fifo[idx] <= 1'b0;
                        end
                    end
                    wr_ptr <= wr_ptr + want_len[PTR_W-1:0];
                    pairs_issued <= pairs_issued + 32'(want_len);
                    reserved_count <= reserved_count + {{(4-LENB){1'b0}}, want_len};
                    if (new_col >= width_r) begin
                        col <= 0; row <= row + 1'b1;
                        src_row <= src_row + src_pitch_r;
                        dst_row <= dst_row + dst_pitch_r;
                    end else col <= new_col;
                end
                if (rd64_valid) begin
                    data_fifo[resp_ptr] <= rd64_data;
                    valid_fifo[resp_ptr] <= 1'b1;
                    resp_ptr <= resp_ptr + 1'b1;
                end
                case ({rd64_valid, write_complete})
                    2'b10: pair_count <= pair_count + 1'b1;
                    2'b01: begin
                        valid_fifo[rd_ptr] <= 1'b0;
                        rd_ptr <= rd_ptr + 1'b1;
                        pair_count <= pair_count - 1'b1;
                        reserved_count <= reserved_count - 1'b1;
                        pairs_done <= pairs_done + 1'b1;
                        scalar_second <= 1'b0;
                    end
                    2'b11: begin
                        valid_fifo[rd_ptr] <= 1'b0;
                        rd_ptr <= rd_ptr + 1'b1;
                        reserved_count <= reserved_count - 1'b1;
                        pairs_done <= pairs_done + 1'b1;
                        scalar_second <= 1'b0;
                    end
                    default: pair_count <= pair_count;
                endcase
                if (scalar_advance)
                    scalar_second <= 1'b1;
                if (write_complete) begin
                    valid_fifo[rd_ptr] <= 1'b0;
                    rd_ptr <= rd_ptr + 1'b1;
                    pairs_done <= pairs_done + 1'b1;
                    scalar_second <= 1'b0;
                end
                // Completion must be gated on pairs_done (every pair
                // actually WRITTEN), not pairs_issued/pair_count -- a burst
                // request marks pairs_issued as soon as it's ACCEPTED, which
                // can now run well ahead of its data actually arriving (the
                // adapter may still be draining earlier descriptors, or
                // yielding to a write under DDR-007's read/write fairness),
                // so pair_count==0 no longer implies nothing is still
                // outstanding once bursts are in play.
                if (pairs_done == total_pairs) begin
                    active <= 0; busy <= 0; done <= 1;
                end
            end
        end
    end
endmodule
