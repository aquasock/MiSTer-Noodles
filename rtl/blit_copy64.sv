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
    // Pairs reserved (fifo slots claimed) since their read was accepted,
    // freed only once written out -- distinct from pair_count, which only
    // starts counting once a pair's DATA has actually arrived. Gates new
    // burst requests so wr_ptr can never lap rd_ptr regardless of how many
    // requests are still in flight awaiting their response.
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
    // Registered paired-write output -- see the comment at stage_paired
    // below. Mirrors req_valid/req_len/req_addr's role on the read side:
    // decouples "we've decided this pair is a paired write" from "ddram_
    // adapter's wr64_ready happened to be high in this exact cycle".
    logic pwr_valid;
    logic [ADDR_WIDTH-1:0] pwr_addr;
    logic [63:0] pwr_data;

    wire lower_key = key_enable_r && data_fifo[rd_ptr][31:0] == key_r;
    wire upper_key = key_enable_r && data_fifo[rd_ptr][63:32] == key_r;
    wire pair_ready = active && pair_count != 0 && valid_fifo[rd_ptr];
    // No dst1_fifo: the second pixel of a pair is always the first + 4
    // bytes by construction (both come from the same pair_col, one pixel
    // apart, and a pair never straddles a row because want_len is clamped
    // to row_remain). Storing it would need a second bank of 16 32-bit
    // adders whose results land on this module's critical path, so it is
    // derived here at the read side, where there is slack.
    wire [ADDR_WIDTH-1:0] dst1_cur = dst0_fifo[rd_ptr] + ADDR_WIDTH'(4);
    // The old "dst1 == dst0 + 4" guard here was always true for the reason
    // above; only the 8-byte alignment of dst0 still needs checking, since
    // an unaligned pair cannot be merged into a single 64-bit write.
    wire paired_write = pair_ready && !lower_key && !upper_key &&
                         (dst0_fifo[rd_ptr][2] == 1'b0);
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
    // paired_write itself never depended on wr64_ready (unlike the old
    // write_complete gating below), so it is safe to use directly as the
    // "should we stage a paired write" decision.
    //
    // stage_paired/pwr_valid/pwr_addr/pwr_data replace the previous direct
    // combinational wr64_en/wr64_addr/wr64_data assigns. The old code fed
    // data_fifo[rd_ptr] (a 16:1, 64-bit read mux) through the key compares
    // straight into wr64_en/wr64_data, which crossed the module boundary
    // combinationally into ddram_adapter's wr64_fire and its wr_data_q
    // register -- one continuous register-to-register path with no break
    // at the boundary, 11.1ns and the 100MHz critical path once the
    // want_len chain (fixed separately) was no longer the bottleneck.
    // stage_paired instead only has to reach a LOCAL register (pwr_valid/
    // pwr_addr/pwr_data); wr64_en/wr64_addr/wr64_data are that register's
    // registered output, so ddram_adapter now sees a clean register-to-
    // register input with no combinational logic in front of it.
    //
    // Retiring the pair (freeing its FIFO slot, advancing rd_ptr) happens
    // when the pair is STAGED here, not when ddram_adapter's wr64_fire
    // actually commits it to the adapter's own write queue -- exactly the
    // same "commit at formation, not acceptance" reasoning already used
    // for the read-request register above: pwr_addr/pwr_data hold a COPY
    // of dst0_fifo[rd_ptr]/data_fifo[rd_ptr], so freeing valid_fifo[rd_ptr]
    // the instant that copy is taken is correct regardless of how long the
    // copy then waits to actually drain into ddram_adapter (bounded to one
    // pair, since a second stage_paired cannot happen until pwr_valid is
    // free or draining this same cycle).
    wire stage_paired = paired_write && (!pwr_valid || wr64_ready);
    wire retire_now = stage_paired || scalar_pair_done;

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
    assign wr_addr = scalar_second ? dst1_cur : dst0_fifo[rd_ptr];
    assign wr_data = scalar_second ? data_fifo[rd_ptr][63:32] :
                                     data_fifo[rd_ptr][31:0];
    assign wr_en = scalar_write;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            busy <= 0; done <= 0; active <= 0; scalar_tail <= 0;
            pair_count <= 0; reserved_count <= 0;
            req_valid <= 0; req_len <= 0; req_addr <= 0;
            want_len_p <= 0; want_len_p_valid <= 0;
            pwr_valid <= 0; pwr_addr <= 0; pwr_data <= 0;
            wr_ptr <= 0; rd_ptr <= 0; resp_ptr <= 0; valid_fifo <= 0;
            scalar_second <= 0;
            col <= 0; row <= 0; width_r <= 0; height_r <= 0;
            row_remain_r <= 0;
            pairs_issued <= 0; pairs_done <= 0; total_pairs <= 0;
            src_row <= 0; dst_row <= 0; dst_pitch_r <= 0; src_pitch_r <= 0;

            key_enable_r <= 0; key_r <= 0;
        end else begin
            done <= 0;
            if (!active && start && width != 0 && height != 0) begin
                active <= 1; busy <= 1; col <= 0; row <= 0;
                width_r <= width; height_r <= height;
                row_remain_r <= width >> 1;
                dst_pitch_r <= dst_pitch; src_pitch_r <= src_pitch;
                src_row <= src_addr; dst_row <= dst_addr;

                key_enable_r <= key_enable; key_r <= key_value;
                pairs_issued <= 0; pairs_done <= 0;
                total_pairs <= (width * height) >> 1;
                pair_count <= 0; reserved_count <= 0;
                req_valid <= 0;
                want_len_p <= 0; want_len_p_valid <= 0;
                pwr_valid <= 0;
                valid_fifo <= 0; wr_ptr <= 0; rd_ptr <= 0; resp_ptr <= 0;
                scalar_second <= 0;
                scalar_tail <= 0;
            end else if (active) begin
                // PREPARE: compute the next want_len_p from the CURRENT
                // row_remain_r/avail_pairs. This is the "slow" compare
                // chain, but it terminates here in a register and does not
                // continue combinationally into col/row_remain_r this
                // cycle. Only runs when the previous want_len_p has been
                // consumed (mutually exclusive with COMMIT below).
                if (prepare_now) begin
                    want_len_p <= want_len16_prep[LENB-1:0];
                    want_len_p_valid <= (want_len16_prep != 0);
                end
                // COMMIT: consume the already-registered want_len_p. State
                // advances when the request is FORMED, not when it is
                // accepted: the request registers hold it stable until the
                // adapter takes it, so committing early is what lets the
                // next PREPARE start from already-updated state.
                if (commit_now) begin
                    req_valid <= 1'b1;
                    req_len <= want_len_p;
                    req_addr <= src_row + col * 4;
                    for (int i = 0; i < FIFO_DEPTH; i++) begin
                        if (i < int'(want_len_p)) begin
                            automatic logic [PTR_W-1:0] idx = wr_ptr + i[PTR_W-1:0];
                            automatic logic [15:0] pair_col = col + 16'(2 * i);
                            dst0_fifo[idx] <= dst_row + ADDR_WIDTH'(pair_col) * 4;
                            valid_fifo[idx] <= 1'b0;
                        end
                    end
                    wr_ptr <= wr_ptr + want_len_p[PTR_W-1:0];
                    pairs_issued <= pairs_issued + 32'(want_len_p);
                    want_len_p_valid <= 1'b0;
                    if (new_col >= width_r) begin
                        col <= 0; row <= row + 1'b1;
                        src_row <= src_row + src_pitch_r;
                        dst_row <= dst_row + dst_pitch_r;
                        row_remain_r <= width_r >> 1;
                    end else begin
                        col <= new_col;
                        row_remain_r <= row_remain_r - {{(16-LENB){1'b0}}, want_len_p};
                    end
                end else if (req_valid && rd64_ready) begin
                    // Accepted with no new request to replace it.
                    req_valid <= 1'b0;
                end
                // Stage a paired write into the local output register
                // (pwr_valid/pwr_addr/pwr_data) rather than driving
                // wr64_en/wr64_addr/wr64_data straight off data_fifo[rd_ptr]
                // -- see the comment at stage_paired above.
                if (stage_paired) begin
                    pwr_valid <= 1'b1;
                    pwr_addr <= dst0_fifo[rd_ptr];
                    pwr_data <= data_fifo[rd_ptr];
                end else if (pwr_valid && wr64_ready) begin
                    // Drained with no new pair to replace it.
                    pwr_valid <= 1'b0;
                end
                if (rd64_valid) begin
                    data_fifo[resp_ptr] <= rd64_data;
                    valid_fifo[resp_ptr] <= 1'b1;
                    resp_ptr <= resp_ptr + 1'b1;
                end
                case ({rd64_valid, retire_now})
                    2'b10: pair_count <= pair_count + 1'b1;
                    2'b01: begin
                        valid_fifo[rd_ptr] <= 1'b0;
                        rd_ptr <= rd_ptr + 1'b1;
                        pair_count <= pair_count - 1'b1;
                        pairs_done <= pairs_done + 1'b1;
                        scalar_second <= 1'b0;
                    end
                    2'b11: begin
                        valid_fifo[rd_ptr] <= 1'b0;
                        rd_ptr <= rd_ptr + 1'b1;
                        pairs_done <= pairs_done + 1'b1;
                        scalar_second <= 1'b0;
                    end
                    default: pair_count <= pair_count;
                endcase
                // reserved_count must reflect BOTH a newly reserved burst
                // (+want_len, now charged when the request is FORMED rather
                // than when it is accepted -- reserving a cycle earlier is
                // strictly more conservative and keeps avail_pairs correct
                // for the very next formation) and a pair retiring (-1)
                // even when they land on the very same cycle: formation is
                // independent of retire_now timing, so with wide rows
                // forcing multiple bursts per FIFO_DEPTH window this
                // coincidence is common, not a corner case. Two separate
                // nonblocking assignments to reserved_count in different
                // branches would let one silently clobber the other; this
                // single combined assignment is the only writer.
                reserved_count <= reserved_count +
                                  (commit_now ? want_len_p : {LENB{1'b0}}) -
                                  (retire_now ? {{(LENB-1){1'b0}}, 1'b1} : {LENB{1'b0}});
                if (scalar_advance)
                    scalar_second <= 1'b1;
                if (retire_now) begin
                    valid_fifo[rd_ptr] <= 1'b0;
                    rd_ptr <= rd_ptr + 1'b1;
                    pairs_done <= pairs_done + 1'b1;
                    scalar_second <= 1'b0;
                end
                // Completion must be gated on pairs_done (every pair
                // actually WRITTEN), not pairs_issued/pair_count -- a burst
                // request marks pairs_issued as soon as it is FORMED, which
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
