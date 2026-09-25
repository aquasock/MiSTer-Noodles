// SDR-003 (core-log entry 66's step 5a): one-shot DDR3 -> SDRAM bulk
// loader. SDR-001 established that the SDRAM board has NO path from
// HPS/Linux -- only the FPGA fabric can write it -- so the sprite source
// bitmap (uploaded by the host into DDR3, same as always) must be copied
// into SDRAM by this module before sdram_adapter.sv's rd64 port can read
// it. Triggered by a new host-issued CMDQ command (OP_LOAD_SDRAM), not
// automatically: matches this project's existing command-driven
// architecture (every action in cmdq.sv is an explicit host request), and
// avoids the cache-invalidation ambiguity an automatic/implicit copy
// would create if the host later re-uploads different sprite data.
//
// sdram.sv's copy port (cpsel/cpaddr/cpdin/cprd/cpreq/cpbusy) is a bulk
// one-time-load mechanism, traced from its own STATE_IDLE/STATE_WAITCP/
// STATE_CP logic: once triggered (cpreq rising edge while cpsel is high),
// it demands a NEW 16-bit word every single clk_sys cycle for exactly
// 512 consecutive cycles (one full page, 1KB) -- there is no
// backpressure, so whatever supplies cpdin must never stall mid-burst.
// DDR3 reads (via ddram_adapter's rd64 port) are comparatively slow and
// non-deterministic, so this module cannot stream DDR3 straight into the
// copy port; it stages one page (1KB) at a time in sdram_page_buffer, a
// small single-clock BRAM, then flushes that whole page in one uninterrupted
// burst. This mirrors the reference design this project's sdram.sv was
// vendored from (MiSTer-devel/NeoGeo_MiSTer's neogeo.sv memcp_state
// machine): fill a small page-sized buffer from the ROM/DDR3 source, then
// drain it into the copy port, one page at a time, advancing both
// pointers by 1024 bytes per page.
//
// SDR-008: fill and flush share clk_sys. A registered start pulse hands
// each completed page to the flush sequencer; fill waits for completion
// before reusing the buffer. Buffering is still required to supply 512
// uninterrupted words despite variable-latency DDR3 responses.
//
// Preconditions/limitations (documented here, not enforced in hardware,
// matching this project's existing single-outstanding-first precedent):
//   - dst_addr must already be caller-aligned to a 1024-byte (one page)
//     boundary within sdram_adapter's 128MB address window; every page
//     write always flushes a full 512-word page regardless of length, so
//     an unaligned or partial-length request still writes (and may
//     partially overwrite) whole pages at the destination.
//   - length is rounded up internally to whole pages; any bytes beyond
//     the requested length that end up written to the final page are
//     leftover stale page_buffer content, not real data -- harmless as
//     long as no later read goes past the intended length (the same
//     assumption this project's other bulk copies already rely on).
//   - src_addr/length are not bounds-checked against ddram_adapter's own
//     valid ranges; the caller (cmdq.sv's new OP_LOAD_SDRAM decode) is
//     responsible for passing sane values, same as every other cmdq
//     opcode's fields today.
module sdram_loader #(
    parameter int ADDR_WIDTH = 32,
    // Registers between the page buffer and cpdin. Each one must be matched
    // by an extra STATE_WAITCP cycle in sdram.sv (its TRCD_EXTRA), during
    // which cprd is already high and the read address advances once more.
    parameter int CPDIN_STAGES = 0
) (
    // Client-facing control (driven by cmdq.sv) and
    // the DDR3-side rd64 read port (driven into ddram_adapter, arbitrated
    // alongside sprite_batch/blit_copy64/link_ring in Noodles.sv).
    input  logic                   clk,
    input  logic                   reset,

    input  logic                   start,
    input  logic [ADDR_WIDTH-1:0]  src_addr,
    input  logic [ADDR_WIDTH-1:0]  dst_addr,
    input  logic [ADDR_WIDTH-1:0]  length,
    output logic                   busy,
    output logic                   done,

    output logic [ADDR_WIDTH-1:0]  rd64_addr,
    output logic                   rd64_en,
    output logic                   rd64_active,
    output logic [7:0]             rd64_len,
    input  logic                   rd64_ready,
    input  logic [63:0]            rd64_data,
    input  logic                   rd64_valid,

    output logic                   cpsel,
    output logic [26:1]            cpaddr,
    output logic [15:0]            cpdin,
    input  logic                   cprd,
    output logic                   cpreq,
    input  logic                   cpbusy
);

    // Fill owns the write port until handoff; flush then owns the read
    // data until completion. The final registered write precedes handoff.
    logic        pbuf_we_a;
    logic [8:0]  pbuf_addr_a;
    logic [15:0] pbuf_din_a;
    logic [8:0]  pbuf_addr_b;
    logic [15:0] pbuf_dout_b;

    sdram_page_buffer page_buffer (
        .clk(clk), .we_a(pbuf_we_a), .addr_a(pbuf_addr_a), .din_a(pbuf_din_a),
        .addr_b(pbuf_addr_b), .dout_b(pbuf_dout_b)
    );

    // ---- Synchronous per-page handoff ----
    logic        handoff_en;
    logic        handoff_ready;
    logic [25:0] handoff_dst_word;
    logic        handoff_done;
    logic        b_start;
    logic [25:0] b_dst_word;
    logic        b_done;

    assign b_start = handoff_en;
    assign b_dst_word = handoff_dst_word;
    assign handoff_done = b_done;

    // =========================================================
    // Fill sequencer
    // =========================================================
    typedef enum logic [2:0] {
        A_IDLE, A_FILL_REQ, A_FILL_WAIT, A_FILL_UNPACK, A_HANDOFF, A_WAIT_DONE
    } state_a_t;
    state_a_t   state_a;

    logic [ADDR_WIDTH-1:0] cur_src_addr;
    logic [25:0]           cur_dst_word;      // current page's base word addr
    logic [ADDR_WIDTH-1:0] bytes_remaining;   // total bytes left, whole transfer
    logic [9:0]             page_word_idx;    // 0..511, next page_buffer write slot
    logic [63:0]            unpack_data;
    logic [1:0]             unpack_idx;

    assign rd64_addr = cur_src_addr;
    assign rd64_len  = 8'd1;
    assign rd64_en   = (state_a == A_FILL_REQ);
    // Mirrors Noodles.sv's existing rd_active convention (link_ring/
    // sprite_batch): must span the whole REQ+WAIT pair, not just the
    // single REQ cycle, so the top-level read mux stays pinned to this
    // module's address for the entire round trip -- letting it fall back
    // to en-only would repeat the exact silent-wrong-half bug link_ring
    // hit before rd_active was introduced (see Noodles.sv's own comment).
    assign rd64_active = (state_a == A_FILL_REQ) || (state_a == A_FILL_WAIT);

    assign handoff_dst_word = cur_dst_word;
    assign busy = (state_a != A_IDLE);


    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state_a         <= A_IDLE;
            done            <= 1'b0;
            cur_src_addr    <= '0;
            cur_dst_word    <= '0;
            bytes_remaining <= '0;
            page_word_idx   <= '0;
            unpack_data     <= '0;
            unpack_idx      <= '0;
            pbuf_we_a       <= 1'b0;
            handoff_en      <= 1'b0;
        end else begin
            done       <= 1'b0;
            pbuf_we_a  <= 1'b0;
            handoff_en <= 1'b0;

            case (state_a)
                A_IDLE: if (start && length != 0) begin
                    cur_src_addr    <= src_addr;
                    cur_dst_word    <= dst_addr[26:1];
                    bytes_remaining <= length;
                    page_word_idx   <= 10'd0;
                    state_a         <= A_FILL_REQ;
                end

                // A page's fill loop ends either when 512 words have been
                // written (page_word_idx reaches 512) or when there is no
                // more real source data left (bytes_remaining reaches 0)
                // -- whichever comes first. The remainder of an
                // under-full final page is left as stale buffer content
                // (see header: harmless as long as nothing reads past
                // the requested length).
                A_FILL_REQ: begin
                    if (page_word_idx == 10'd512 || bytes_remaining == '0) begin
                        state_a <= A_HANDOFF;
                    end else if (rd64_ready) begin
                        state_a <= A_FILL_WAIT;
                    end
                end

                A_FILL_WAIT: if (rd64_valid) begin
                    unpack_data <= rd64_data;
                    unpack_idx  <= 2'd0;
                    state_a     <= A_FILL_UNPACK;
                end

                // Little-endian sub-word order, matching sdram_adapter's
                // own rd64 assembly convention: unpack_data[15:0] is the
                // lowest-addressed 16-bit word.
                A_FILL_UNPACK: begin
                    pbuf_we_a   <= 1'b1;
                    pbuf_addr_a <= page_word_idx[8:0] + {7'b0, unpack_idx};
                    pbuf_din_a  <= unpack_data[16*unpack_idx +: 16];
                    if (unpack_idx == 2'd3) begin
                        page_word_idx   <= page_word_idx + 10'd4;
                        cur_src_addr    <= cur_src_addr + 32'd8;
                        bytes_remaining <= (bytes_remaining > 32'd8)
                                          ? bytes_remaining - 32'd8 : '0;
                        state_a         <= A_FILL_REQ;
                    end else begin
                        unpack_idx <= unpack_idx + 2'd1;
                    end
                end

                A_HANDOFF: if (handoff_ready) begin
                    handoff_en <= 1'b1;
                    state_a    <= A_WAIT_DONE;
                end

                A_WAIT_DONE: if (handoff_done) begin
                    if (bytes_remaining == '0) begin
                        done    <= 1'b1;
                        state_a <= A_IDLE;
                    end else begin
                        cur_dst_word  <= cur_dst_word + 26'd512;
                        page_word_idx <= 10'd0;
                        state_a       <= A_FILL_REQ;
                    end
                end

                default: state_a <= A_IDLE;
            endcase
        end
    end

    // =========================================================
    // Flush sequencer -- streams one page into sdram.sv's
    // copy port per b_start pulse, then reports completion via b_done.
    // =========================================================
    typedef enum logic [1:0] {B_IDLE, B_ISSUE, B_WAIT_RISE, B_WAIT_FALL} state_b_t;
    state_b_t state_b;
    logic     cpbusy_prev;
    assign handoff_ready = (state_b == B_IDLE) && !handoff_en && !b_done;

    assign cpsel  = 1'b1;
    assign cpaddr = b_dst_word;
    generate
        if (CPDIN_STAGES == 0) begin : g_cpdin_direct
            assign cpdin = pbuf_dout_b;
        end else begin : g_cpdin_reg
            logic [15:0] cpdin_q [0:CPDIN_STAGES-1];
            always_ff @(posedge clk) begin
                cpdin_q[0] <= pbuf_dout_b;
                for (int i = 1; i < CPDIN_STAGES; i++) cpdin_q[i] <= cpdin_q[i-1];
            end
            assign cpdin = cpdin_q[CPDIN_STAGES-1];
        end
    endgenerate

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state_b     <= B_IDLE;
            cpreq       <= 1'b0;
            b_done      <= 1'b0;
            cpbusy_prev <= 1'b0;
        end else begin
            b_done      <= 1'b0;
            cpbusy_prev <= cpbusy;

            case (state_b)
                // cpreq is held asserted as a LEVEL (not a one-cycle
                // pulse) until cpbusy is actually observed rising -- the
                // same fix sdram_adapter.sv's SEQ_ISSUE applies to
                // sd_sel/sd_rd, and for the identical reason. sdram.sv's
                // STATE_IDLE only samples/acts on cpreq via an edge
                // check (`~old_cpreq & cpreq & cpsel`), and old_cpreq
                // itself is only updated while the controller is
                // actually sitting in STATE_IDLE's real-idle branch (see
                // its own always block): during a periodic auto-refresh
                // (STATE_RFSH/IDLE_x) or a concurrent sdram_adapter read,
                // STATE_IDLE's else-branch never runs, so old_cpreq is
                // frozen. A one-cycle cpreq pulse landing entirely inside
                // one of those windows drops back to 0 before the
                // controller ever reaches real idle again, and the edge
                // that would have triggered CMD_ACTIVE is gone forever --
                // permanently hanging this state (and, transitively,
                // cmdq.sv's WAIT_DONE, since nothing else ever follows an
                // OP_LOAD_SDRAM that never completes). Holding cpreq
                // high is safe here for the same reason it is for
                // sd_sel/sd_rd: old_cpreq necessarily still lags behind
                // (frozen at its pre-request value) the first time the
                // controller reaches true idle after cpreq rises, so the
                // edge condition fires correctly on that first
                // opportunity, however long it takes to arrive.
                B_IDLE: if (b_start) begin
                    cpreq   <= 1'b1;
                    state_b <= B_ISSUE;
                end
                B_ISSUE: if (cpbusy) begin
                    cpreq   <= 1'b0;
                    state_b <= B_WAIT_RISE;
                end
                // B_WAIT_RISE is now a one-cycle formality (cpbusy is
                // already high on entry to B_ISSUE's transition above),
                // kept as its own state so the cpbusy_prev-based
                // high-to-low edge check below still has a clean prior
                // sample to compare against.
                B_WAIT_RISE: state_b <= B_WAIT_FALL;
                B_WAIT_FALL: if (cpbusy_prev && !cpbusy) begin
                    b_done  <= 1'b1;
                    state_b <= B_IDLE;
                end
                default: state_b <= B_IDLE;
            endcase
        end
    end

    // ---- Page buffer read-side prefetch: cpdin must be valid one
    // clk_sys cycle before sdram.sv actually samples it, since
    // sdram_page_buffer's port B has one cycle of read latency. Traced
    // from sdram.sv's own STATE_WAITCP/STATE_CP timing: STATE_WAITCP
    // (cprd's first high cycle) does not itself consume cpdin -- the
    // first real sample happens the cycle after, in STATE_CP. So
    // addr_b=0 is armed when this page's request is issued (b_start,
    // one cycle before cpreq is even visible to sdram.sv), landing
    // dout_b=mem[0] exactly on STATE_WAITCP's cycle -- one clk_sys
    // cycle ahead of when STATE_CP's first iteration actually needs it.
    // From there, incrementing addr_b once every cycle cprd is high
    // (including the WAITCP cycle itself, for 511 total increments)
    // keeps dout_b exactly one step ahead of each of the 512 STATE_CP
    // consumption cycles.
    logic [9:0] page_inc_count;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            pbuf_addr_b    <= '0;
            page_inc_count <= '0;
        end else if (state_b == B_IDLE && b_start) begin
            pbuf_addr_b    <= 9'd0;
            page_inc_count <= 10'd0;
        end else if (cprd && page_inc_count < 10'd511) begin
            pbuf_addr_b    <= pbuf_addr_b + 9'd1;
            page_inc_count <= page_inc_count + 10'd1;
        end
    end

endmodule
