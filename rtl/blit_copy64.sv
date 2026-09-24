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
    parameter int FIFO_DEPTH = 16
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
    logic [63:0] data_fifo [0:FIFO_DEPTH-1];
    logic [FIFO_DEPTH-1:0] valid_fifo;
    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    logic [PTR_W-1:0] resp_ptr;
    logic [LENB-1:0] pair_count;
    // FIFO slots are reserved at request formation and freed on head
    // capture. pair_count counts only responses still in the FIFO; neither
    // count includes the independent head/output registers.
    logic [LENB-1:0] reserved_count;
    logic [15:0] col, row, width_r, height_r;
    logic [15:0] row_remain_r;
    logic [31:0] pairs_issued, pairs_done, total_pairs;
    logic [ADDR_WIDTH-1:0] src_row, dst_row;
    logic [15:0] dst_pitch_r, src_pitch_r;
    logic key_enable_r;
    logic [31:0] key_r;
    logic active, scalar_tail;
    logic scalar_second;
    // Registered read request -- see the comment at form_req below.
    logic req_valid;
    logic [LENB-1:0] req_len;
    logic [ADDR_WIDTH-1:0] req_addr;
    // want_len PREPARE/COMMIT pipeline -- see the comment at want_len16
    // below. want_len_p is the already-decided length for the request
    // currently being formed; want_len_p_valid marks whether one is ready.
    logic [LENB-1:0] want_len_p;
    logic want_len_p_valid;
    // Registered with want_len_p: whether that request finishes the row.
    // COMMIT uses it instead of comparing col + 2 * want_len against width,
    // keeping the column counter off the row-change and address paths.
    logic row_end_p;
    // Byte addresses of the current column in the source and destination
    // rows, kept alongside col so requests and destination FIFO entries are
    // a register plus a constant offset rather than row + col * 4.
    logic [ADDR_WIDTH-1:0] src_cur, dst_cur;
    // Registered paired-write output -- see the comment at stage_paired
    // below. Mirrors req_valid/req_len/req_addr's role on the read side:
    // decouples "we've decided this pair is a paired write" from "ddram_
    // adapter's wr64_ready happened to be high in this exact cycle".
    logic pwr_valid;
    logic [ADDR_WIDTH-1:0] pwr_addr;
    logic [63:0] pwr_data;
    // Registered scalar-write output -- see the comment at stage_scalar
    // below. Same role as pwr_valid/pwr_addr/pwr_data on the paired-write
    // side, but for the colorkeyed/misaligned half-word path.
    logic swr_valid;
    logic [ADDR_WIDTH-1:0] swr_addr;
    logic [31:0] swr_data;

    logic head_valid;
    logic [ADDR_WIDTH-1:0] head_addr;
    logic [63:0] head_data;

    wire lower_key = key_enable_r && head_data[31:0] == key_r;
    wire upper_key = key_enable_r && head_data[63:32] == key_r;
    wire pair_ready = active && head_valid;
    // No dst1_fifo: the second pixel of a pair is always the first + 4
    // bytes by construction (both come from the same pair_col, one pixel
    // apart, and a pair never straddles a row because want_len is clamped
    // to row_remain). Storing it would need a second bank of 16 32-bit
    // adders whose results land on this module's critical path, so it is
    // derived here at the read side, where there is slack.
    wire [ADDR_WIDTH-1:0] dst1_cur = head_addr + ADDR_WIDTH'(4);
    // The old "dst1 == dst0 + 4" guard here was always true for the reason
    // above; only the 8-byte alignment of dst0 still needs checking, since
    // an unaligned pair cannot be merged into a single 64-bit write.
    wire paired_write = pair_ready && !lower_key && !upper_key &&
                         (head_addr[2] == 1'b0);
    wire scalar_first_skip = pair_ready && !paired_write &&
                             !scalar_second && lower_key;
    wire scalar_first_cand = pair_ready && !paired_write &&
                              !scalar_second && !lower_key;
    wire scalar_second_skip = pair_ready && !paired_write &&
                              scalar_second && upper_key;
    wire scalar_second_cand = pair_ready && !paired_write &&
                               scalar_second && !upper_key;
    wire scalar_write_cand = scalar_first_cand || scalar_second_cand;
    // Key/alignment decisions operate only on the registered head; the
    // output registers isolate them from the adapter's write queue.
    wire stage_scalar = scalar_write_cand && (!swr_valid || wr_ready) &&
                        (!pwr_valid || wr64_ready);
    wire stage_scalar_first = stage_scalar && !scalar_second;
    wire stage_scalar_second = stage_scalar && scalar_second;
    wire scalar_pair_done = scalar_second_skip || stage_scalar_second ||
                            (stage_scalar_first && upper_key);
    wire scalar_advance = scalar_first_skip ||
                          (stage_scalar_first && !upper_key);
    // The head owns a copy of the FIFO entry until all its drawable pixels
    // have been staged. Opposite-port pending writes must drain first to
    // preserve ordering when transitioning between paired and scalar writes.
    wire stage_paired = paired_write && (!pwr_valid || wr64_ready) &&
                        (!swr_valid || wr_ready);
    wire retire_now = stage_paired || scalar_pair_done;

    // FIFO muxes end at this register, before key/alignment decisions.
    // rd_ptr always selects the next uncaptured entry, so retiring a head
    // can refill it on the same edge without a look-ahead read-pointer mux.
    wire load_head = active && (!head_valid || retire_now) &&
                     pair_count != 0 && valid_fifo[rd_ptr];

    // How many contiguous pairs the CURRENT burst request should ask for:
    // bounded by free FIFO capacity and by the pairs remaining in the
    // current source row (crossing into the next row means a
    // non-contiguous DRAM address, so it must end this burst, not extend
    // it).
    //
    // This is split into two phases across a register (want_len_p) rather
    // than computed and consumed in the same cycle. The naive single-cycle
    // version chains: min(row_remain_r, avail_pairs) -> new_col adder ->
    // new_col>=width_r compare -> row_remain_r/col next-value select, a
    // 10-level, ~11.5ns path (the 100MHz critical path) ending back in
    // row_remain_r itself -- register-to-register in one hop no matter
    // which of row_remain_r/col/avail_pairs is nominally "the" state.
    // PREPARE computes only the cheap first half (a 16-bit compare/select)
    // from the CURRENT row_remain_r/avail_pairs and stops at a register;
    // COMMIT consumes the already-registered want_len_p to do the cheap
    // second half (a 16-bit add/compare) that actually advances
    // row_remain_r/col. Splitting is safe: PREPARE only runs when no
    // request is pending (avail_pairs can only grow via retirements before
    // COMMIT consumes it, never shrink out from under it, since we are the
    // only source of new reservations), and row_remain_r/col are provably
    // unchanged between a PREPARE and its matching COMMIT (only COMMIT
    // advances them). The cost is one idle cycle between forming
    // consecutive requests -- free, since a burst covers up to
    // FIFO_DEPTH pairs and takes far longer than that to drain.
    wire [15:0] avail_pairs = 16'(FIFO_DEPTH) - {{(16-LENB){1'b0}}, reserved_count};
    wire [15:0] want_len16_prep = (row_remain_r < avail_pairs) ? row_remain_r : avail_pairs;
    wire prepare_now = active && !scalar_tail && (pairs_issued < total_pairs) &&
                       !want_len_p_valid;

    wire [15:0] new_col = col + {{(15-LENB){1'b0}}, want_len_p, 1'b0};

    // The read request is REGISTERED rather than driven combinationally from
    // col/reserved_count. ddram_adapter's rd64_ready depends on rd64_len
    // (it checks rsp_committed + rd64_len against its queue depth), so a
    // combinational rd64_len made one single path out of this module's
    // subtract/compare chain AND the adapter's accept logic AND the write
    // back into its address RAM -- 12.3ns, the 100MHz critical path.
    // Registering splits it into two short halves at the cost of nothing:
    // a burst covers up to FIFO_DEPTH pairs and takes far longer than a
    // cycle to drain, and the next request is formed in the same cycle the
    // current one is accepted, so the issue rate is unchanged.
    wire commit_now = want_len_p_valid && (want_len_p != 0) &&
                      (!req_valid || rd64_ready);

    assign rd64_en = req_valid;
    assign rd64_len = {{(8-LENB){1'b0}}, req_len};
    assign rd64_addr = req_addr;
    assign wr64_addr = pwr_addr;
    assign wr64_data = pwr_data;
    assign wr64_en = pwr_valid;
    assign wr_addr = swr_addr;
    assign wr_data = swr_data;
    assign wr_en = swr_valid;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            busy <= 0; done <= 0; active <= 0; scalar_tail <= 0;
            pair_count <= 0; reserved_count <= 0;
            req_valid <= 0; req_len <= 0; req_addr <= 0;
            want_len_p <= 0; want_len_p_valid <= 0;
            pwr_valid <= 0; pwr_addr <= 0; pwr_data <= 0;
            swr_valid <= 0; swr_addr <= 0; swr_data <= 0;
            head_valid <= 0; head_addr <= 0; head_data <= 0;
            wr_ptr <= 0; rd_ptr <= 0; resp_ptr <= 0; valid_fifo <= 0;
            scalar_second <= 0;
            col <= 0; row <= 0; width_r <= 0; height_r <= 0;
            row_remain_r <= 0;
            pairs_issued <= 0; pairs_done <= 0; total_pairs <= 0;
            src_row <= 0; dst_row <= 0; dst_pitch_r <= 0; src_pitch_r <= 0;
            src_cur <= 0; dst_cur <= 0; row_end_p <= 0;

            key_enable_r <= 0; key_r <= 0;
        end else begin
            done <= 0;
            if (!active && start && width != 0 && height != 0) begin
                active <= 1; busy <= 1; col <= 0; row <= 0;
                width_r <= width; height_r <= height;
                row_remain_r <= width >> 1;
                dst_pitch_r <= dst_pitch; src_pitch_r <= src_pitch;
                src_row <= src_addr; dst_row <= dst_addr;
                src_cur <= src_addr; dst_cur <= dst_addr;
                row_end_p <= 0;

                key_enable_r <= key_enable; key_r <= key_value;
                pairs_issued <= 0; pairs_done <= 0;
                total_pairs <= (width * height) >> 1;
                pair_count <= 0; reserved_count <= 0;
                req_valid <= 0;
                want_len_p <= 0; want_len_p_valid <= 0;
                pwr_valid <= 0;
                swr_valid <= 0;
                head_valid <= 0;
                valid_fifo <= 0; wr_ptr <= 0; rd_ptr <= 0; resp_ptr <= 0;
                scalar_second <= 0;
                scalar_tail <= 0;
            end else if (active) begin
                if (load_head) begin
                    head_valid <= 1'b1;
                    head_addr <= dst0_fifo[rd_ptr];
                    head_data <= data_fifo[rd_ptr];
                end else if (retire_now) begin
                    head_valid <= 1'b0;
                end
                // PREPARE: compute the next want_len_p from the CURRENT
                // row_remain_r/avail_pairs. This is the "slow" compare
                // chain, but it terminates here in a register and does not
                // continue combinationally into col/row_remain_r this
                // cycle. Only runs when the previous want_len_p has been
                // consumed (mutually exclusive with COMMIT below).
                if (prepare_now) begin
                    want_len_p <= want_len16_prep[LENB-1:0];
                    want_len_p_valid <= (want_len16_prep != 0);
                    row_end_p <= (want_len16_prep == row_remain_r);
                end
                // COMMIT: consume the already-registered want_len_p. State
                // advances when the request is FORMED, not when it is
                // accepted: the request registers hold it stable until the
                // adapter takes it, so committing early is what lets the
                // next PREPARE start from already-updated state.
                if (commit_now) begin
                    req_valid <= 1'b1;
                    req_len <= want_len_p;
                    req_addr <= src_cur;
                    for (int i = 0; i < FIFO_DEPTH; i++) begin
                        if (i < int'(want_len_p)) begin
                            automatic logic [PTR_W-1:0] idx = wr_ptr + i[PTR_W-1:0];
                            dst0_fifo[idx] <= dst_cur + ADDR_WIDTH'(8 * i);
                            valid_fifo[idx] <= 1'b0;
                        end
                    end
                    wr_ptr <= wr_ptr + want_len_p[PTR_W-1:0];
                    pairs_issued <= pairs_issued + 32'(want_len_p);
                    want_len_p_valid <= 1'b0;
                    if (row_end_p) begin
                        col <= 0; row <= row + 1'b1;
                        src_row <= src_row + src_pitch_r;
                        dst_row <= dst_row + dst_pitch_r;
                        src_cur <= src_row + src_pitch_r;
                        dst_cur <= dst_row + dst_pitch_r;
                        row_remain_r <= width_r >> 1;
                    end else begin
                        col <= new_col;
                        src_cur <= src_cur + {{(ADDR_WIDTH-LENB-3){1'b0}}, want_len_p, 3'b000};
                        dst_cur <= dst_cur + {{(ADDR_WIDTH-LENB-3){1'b0}}, want_len_p, 3'b000};
                        row_remain_r <= row_remain_r - {{(16-LENB){1'b0}}, want_len_p};
                    end
                end else if (req_valid && rd64_ready) begin
                    // Accepted with no new request to replace it.
                    req_valid <= 1'b0;
                end
                if (stage_paired) begin
                    pwr_valid <= 1'b1;
                    pwr_addr <= head_addr;
                    pwr_data <= head_data;
                end else if (pwr_valid && wr64_ready) begin
                    // Drained with no new pair to replace it.
                    pwr_valid <= 1'b0;
                end
                if (stage_scalar) begin
                    swr_valid <= 1'b1;
                    swr_addr <= scalar_second ? dst1_cur : head_addr;
                    swr_data <= scalar_second ? head_data[63:32] :
                                                head_data[31:0];
                end else if (swr_valid && wr_ready) begin
                    // Drained with no new half-word to replace it.
                    swr_valid <= 1'b0;
                end
                if (rd64_valid) begin
                    data_fifo[resp_ptr] <= rd64_data;
                    valid_fifo[resp_ptr] <= 1'b1;
                    resp_ptr <= resp_ptr + 1'b1;
                end
                case ({rd64_valid, load_head})
                    2'b10: pair_count <= pair_count + 1'b1;
                    2'b01: begin
                        valid_fifo[rd_ptr] <= 1'b0;
                        rd_ptr <= rd_ptr + 1'b1;
                        pair_count <= pair_count - 1'b1;
                    end
                    2'b11: begin
                        valid_fifo[rd_ptr] <= 1'b0;
                        rd_ptr <= rd_ptr + 1'b1;
                    end
                    default: pair_count <= pair_count;
                endcase
                // A copied head no longer occupies a FIFO slot, even while
                // stalled. Combine reservation and release on the same edge.
                reserved_count <= reserved_count +
                                  (commit_now ? want_len_p : {LENB{1'b0}}) -
                                  (load_head ? {{(LENB-1){1'b0}}, 1'b1} : {LENB{1'b0}});
                if (retire_now) begin
                    pairs_done <= pairs_done + 1'b1;
                    scalar_second <= 1'b0;
                end
                if (scalar_advance)
                    scalar_second <= 1'b1;
                // Retirement means staged or skipped, not yet accepted.
                // Keep active until the final output drains; a new start
                // must never clear an outstanding write.
                if (pairs_done == total_pairs && !head_valid &&
                    !pwr_valid && !swr_valid) begin
                    active <= 0; busy <= 0; done <= 1;
                end
            end
        end
    end
endmodule
