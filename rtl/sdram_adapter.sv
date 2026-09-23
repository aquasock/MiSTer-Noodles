// sdram_adapter.sv -- step 4 of core-log entry 61's SDRAM plan (SDR-001).
//
// Presents a client-facing rd64 read port shaped like ddram_adapter.sv's
// (rd64_addr/rd64_en/rd64_ready/rd64_data/rd64_valid), on clk_sys, backed
// by the real rtl/sdram.sv board controller on clk_sdram, crossing the
// domain via step 3's sdram_cdc.
//
// Deliberately scoped narrower than ddram_adapter.sv for this first cut:
//   - Only the 64-bit rd64 port is implemented. There is no scalar 32-bit
//     rd port and no write port at all: SDR-001 scopes SDRAM to
//     host-write-once/FPGA-read-many sprite-source-bitmap data, and the
//     only client that will ever read it (sprite_batch.sv's copy engine,
//     via blit_copy64.sv) only ever uses the 64-bit port. Bulk-loading the
//     bitmap into SDRAM at boot is a separate, later step and will most
//     likely use sdram.sv's own dedicated "cp" burst-write port rather
//     than this read adapter.
//   - rd64_len (burst length, SDR-004/step 5b) IS supported, but not as a
//     real Avalon-style burst command the way ddram_adapter.sv issues one
//     -- sdram_cdc is single-outstanding by design (SDR-002's own header),
//     so a length-N request here becomes N sequential single-word CDC
//     round trips instead, each one a full 4-sub-word domain-B sequence,
//     with the client-facing rd64_ready held low for the WHOLE burst (see
//     the domain-A burst state machine below). This is required, not
//     optional: blit_copy64.sv (DDR-007) accepts a burst request once and
//     then expects exactly rd64_len separate rd64_valid pulses to follow,
//     with no further rd64_en/rd64_ready handshake in between -- treating
//     every request as length-1 (this module's original step-4 behavior)
//     silently stranded blit_copy64's later pairs in a FIFO slot that
//     never became valid, hanging sprite_batch forever the first time a
//     real width>2 sprite tried to read through this adapter. The address
//     for each successive sub-request advances by 8 bytes (one 64-bit
//     word), mirroring how ddram_adapter's real Avalon burst
//     auto-increments its own internal address per beat.
//
// Domain B (clk_sdram) is a small 4-step sequencer that turns one 64-bit
// request into four consecutive 16-bit accesses through sdram.sv's normal
// (non-copy) port -- that port is natively 16 bits wide (SDRAM_DQ), so
// this is the minimum number of real SDRAM commands a 64-bit read costs.
// b_addr is a byte address; the low 3 bits (8-byte alignment) are dropped
// and the remaining bits are right-shifted by 1 to form sdram.sv's own
// 16-bit-word address space (its addr[0] is defined to always be 0 in
// 16-bit mode). The four sub-words are assembled little-endian: the
// lowest address holds a_data[15:0], the next a_data[31:16], and so on --
// consistent with how ddram_adapter.sv hands back ddram_dout unmodified
// (lowest byte at the LSBs).
//
// reset_b resolves entry 64's open question: sdram.sv's own init/startup
// sequencing is already, separately, tied to ~pll_locked in Noodles.sv
// (untouched here) -- this module's own domain-B flops (the sequencer and
// sdram_cdc's domain-B half) use a *different* signal, reset_b, which
// Noodles.sv now derives via a small async-assert/2FF-synchronized-
// deassert bridge from the general `reset` signal. That is the standard,
// minimal-risk way to bring an async, clk_sys-domain reset safely into a
// second clock domain without needing it to be cycle-exact with clk_sys's
// own reset.
module sdram_adapter #(
    parameter int ADDR_WIDTH = 32
) (
    // Domain A: clk_sys client-facing read port.
    input  logic                  clk_sys,
    input  logic                  reset,

    input  logic [ADDR_WIDTH-1:0] rd64_addr,
    input  logic                  rd64_en,
    input  logic [7:0]            rd64_len,   // sequential single-word round trips; see header
    output logic                  rd64_ready,
    output logic [63:0]           rd64_data,
    output logic                  rd64_valid,

    // Domain B: clk_sdram, wired straight to sdram.sv's normal port.
    input  logic                  clk_sdram,
    input  logic                  reset_b,

    output logic                  sd_sel,
    output logic [26:1]           sd_addr,
    input  logic [15:0]           sd_dout,
    output logic                  sd_rd,
    input  logic                  sd_ready
);

    // ---- Domain A: burst-to-sequential-round-trips state machine ----
    // See header comment: a length-N rd64 request is accepted ONCE (the
    // client never re-strobes rd64_en mid-burst) and must then produce N
    // separate rd64_valid pulses, one per contiguous 64-bit word, with
    // rd64_ready held low until the whole burst has round-tripped.
    typedef enum logic {A_IDLE, A_BURST} a_state_t;
    a_state_t              a_state;
    logic [ADDR_WIDTH-1:0] a_next_addr;
    logic [7:0]            a_words_left;

    logic [ADDR_WIDTH-1:0] a_addr_in;
    logic                  a_en_in;
    logic                  a_ready_out;
    logic [63:0]           a_data_out;
    logic                  a_valid_out;

    wire [7:0] a_req_len = (rd64_len == 8'd0) ? 8'd1 : rd64_len;
    // Only accept a brand-new request once fully idle AND the CDC itself
    // is ready (it always will be here, but this stays correct even if a
    // future change makes idle-but-still-busy possible).
    wire a_ready_for_client = (a_state == A_IDLE) && a_ready_out;

    assign a_addr_in  = (a_state == A_IDLE) ? rd64_addr : a_next_addr;
    assign a_en_in    = (a_state == A_IDLE) ? (rd64_en && a_ready_for_client)
                                             : (a_words_left != 8'd0);
    assign rd64_ready = a_ready_for_client;
    assign rd64_data  = a_data_out;
    assign rd64_valid = a_valid_out;

    always_ff @(posedge clk_sys or posedge reset) begin
        if (reset) begin
            a_state      <= A_IDLE;
            a_next_addr  <= '0;
            a_words_left <= '0;
        end else begin
            case (a_state)
                A_IDLE: if (rd64_en && a_ready_for_client) begin
                    if (a_req_len > 8'd1) begin
                        a_next_addr  <= rd64_addr + 32'd8;
                        a_words_left <= a_req_len - 8'd1;
                        a_state      <= A_BURST;
                    end
                    // a_req_len == 1: stays in A_IDLE -- the single CDC
                    // round trip already in flight is enough; a_ready_out
                    // dropping (via busy_a) is what blocks a second
                    // acceptance until it completes.
                end
                A_BURST: if (a_en_in && a_ready_out) begin
                    if (a_words_left == 8'd1) begin
                        a_words_left <= 8'd0;
                        a_state      <= A_IDLE;
                    end else begin
                        a_words_left <= a_words_left - 8'd1;
                        a_next_addr  <= a_next_addr + 32'd8;
                    end
                end
                default: a_state <= A_IDLE;
            endcase
        end
    end

    logic [ADDR_WIDTH-1:0] b_addr_out;
    logic                  b_start_out;
    logic [63:0]           b_data_in;
    logic                  b_done_in;

    sdram_cdc #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(64)) cdc_i (
        .clk_a  (clk_sys),
        .reset_a(reset),
        .a_addr (a_addr_in),
        .a_en   (a_en_in),
        .a_ready(a_ready_out),
        .a_data (a_data_out),
        .a_valid(a_valid_out),

        .clk_b  (clk_sdram),
        .reset_b(reset_b),
        .b_addr (b_addr_out),
        .b_start(b_start_out),
        .b_data (b_data_in),
        .b_done (b_done_in)
    );

    // ---- Domain B: 4-step 16-bit read sequencer ----
    typedef enum logic [2:0] {
        SEQ_IDLE,
        SEQ_ISSUE,
        SEQ_WAIT_READY_HIGH,
        SEQ_DONE
    } seq_state_t;

    seq_state_t  seq_state;
    // word_base is the 16-bit-word address of this request's first
    // sub-word: since b_addr_out is a byte address and sdram.sv's own
    // addr[26:1] already IS the byte address with bit 0 dropped (16-bit
    // mode), word_base == b_addr_out[26:1] directly -- no separate
    // multiply/shift needed, only a required 8-byte (b_addr[2:0]==0)
    // alignment on the caller's part. Sub-word i then simply sits at
    // word_base + i, since consecutive 16-bit-word addresses are
    // consecutive 2-byte chunks.
    logic [25:0] word_base;
    logic [1:0]  word_idx;    // which of the 4 16-bit sub-words we're on
    logic [63:0] assembled;

    wire [25:0] sd_addr_word = word_base + {24'b0, word_idx};
    assign sd_addr = sd_addr_word;

    always_ff @(posedge clk_sdram or posedge reset_b) begin
        if (reset_b) begin
            seq_state  <= SEQ_IDLE;
            word_base  <= '0;
            word_idx   <= 2'd0;
            assembled  <= '0;
            b_data_in  <= '0;
            b_done_in  <= 1'b0;
            sd_sel     <= 1'b0;
            sd_rd      <= 1'b0;
        end else begin
            b_done_in <= 1'b0;
            case (seq_state)
                SEQ_IDLE: begin
                    sd_sel <= 1'b0;
                    sd_rd  <= 1'b0;
                    if (b_start_out) begin
                        word_base <= b_addr_out[26:1];
                        word_idx  <= 2'd0;
                        seq_state <= SEQ_ISSUE;
                    end
                end
                SEQ_ISSUE: begin
                    // Hold sel&rd asserted as a LEVEL, not a one-cycle
                    // pulse, until sd_ready is actually observed to drop
                    // -- that is sdram.sv's only real acknowledgement
                    // that our request landed while it happened to be in
                    // its own STATE_IDLE. A blind one-cycle pulse is NOT
                    // safe: sdram.sv also silently ignores sel&rd for
                    // several cycles during its own periodic auto-refresh
                    // sequence (STATE_RFSH + 5 IDLE_x cycles, driven
                    // independently by Noodles.sv's free-running refresh
                    // toggle) and during the loader's copy-port bursts
                    // (STATE_WAITCP/STATE_CP) -- and, critically, `ready`
                    // does NOT drop during either of those windows (it
                    // only drops for real reads/writes), so a request
                    // that lands there would vanish with zero visible
                    // sign of rejection. This was a real bug (hung
                    // sprite_batch on actual hardware within the first
                    // second, though never observed in sim's mock model,
                    // which always accepts sel&rd immediately) --
                    // holding the level until !sd_ready is confirmed
                    // fixes it unconditionally, regardless of how long
                    // the controller happens to be busy elsewhere.
                    sd_sel <= 1'b1;
                    sd_rd  <= 1'b1;
                    if (!sd_ready) begin
                        sd_sel    <= 1'b0;
                        sd_rd     <= 1'b0;
                        seq_state <= SEQ_WAIT_READY_HIGH;
                    end
                end
                SEQ_WAIT_READY_HIGH: begin
                    if (sd_ready) begin
                        case (word_idx)
                            2'd0: assembled[15:0]  <= sd_dout;
                            2'd1: assembled[31:16] <= sd_dout;
                            2'd2: assembled[47:32] <= sd_dout;
                            2'd3: assembled[63:48] <= sd_dout;
                        endcase
                        if (word_idx == 2'd3) begin
                            seq_state <= SEQ_DONE;
                        end else begin
                            word_idx  <= word_idx + 1'b1;
                            seq_state <= SEQ_ISSUE;
                        end
                    end
                end
                SEQ_DONE: begin
                    b_data_in <= assembled;
                    b_done_in <= 1'b1;
                    seq_state <= SEQ_IDLE;
                end
                default: seq_state <= SEQ_IDLE;
            endcase
        end
    end

endmodule
