// Temporary diagnostic (see ai/core-log.md, present-stage stutter
// investigation): publishes ascal.vhd's o_dbg_retire_wait_cyc /
// o_dbg_missed_boundaries / o_dbg_read_outstanding_pk /
// o_dbg_retire_gate_mask to two fixed DRAM
// words, once per PRESENT retirement, so a host tool can poll it without a
// Signal Tap license. Modeled directly on rtl/link_fence.sv's
// publish-on-change pattern; not folded into link_fence itself since it
// publishes on a different event (every FB_RETIRED edge, not every command
// completion) and carries different payload semantics.
//
// A prior recovered version of this probe published a single 32-bit word
// with a 16-bit retire_wait_cyc field, which saturated at 65535 on every
// hardware sample -- the underlying ascal.vhd counter also reset itself at
// every frame boundary even while a retirement was still pending, so a
// multi-frame stall could never be measured. Both problems are fixed at the
// source (ascal.vhd's dbg_retire_wait_ctr is now 32-bit and keeps counting
// across additional boundaries instead of resetting); this module widens
// its payload to match and adds the new missed-boundary count.
//
// word 0 (DBG_ADDR + 0): retire_wait_cyc, full 32 bits, saturating.
// word 1 (DBG_ADDR + 4), bit 31 downto 0:
//   [15:0]  missed_boundaries   -- additional frame boundaries seen while
//                                   this retirement was pending, saturating
//   [19:16] read_outstanding_pk -- peak avl_read_outstanding seen in the
//                                   same window (0-8)
//   [27:20] seq                 -- rolling sample counter, so the host can
//                                   tell a fresh sample from a repeated one
//   [31:28] gate_mask:
//              bit 0: framebuffer base latch had not arrived
//              bit 1: scanout reads remained outstanding
//              bit 2: scanout read data was still arriving
//              bit 3: Avalon request state was not idle
//
// The two words are written back-to-back on the same retirement sample and
// are not updated atomically as a pair: if FB_RETIRED toggles again between
// the two writes (impossible in practice -- retirements are frames apart,
// tens of milliseconds, while a DRAM write completes in a handful of
// cycles), a reader could observe one word from an old sample and one from
// a new one. A host wanting to rule that out entirely can re-read both
// words and check word 1's seq field is unchanged.
//
// Not intended to stay in the tree long-term: remove once the stutter's
// root cause is confirmed and any resulting fix is qualified.
module dbg_present_probe #(
    parameter logic [31:0] DBG_ADDR = 32'h3003_0000
) (
    input logic clk,
    input logic reset,

    input logic         retired_edge,     // one cycle high per fresh FB_RETIRED edge
    input logic [31:0]  retire_wait_cyc,
    input logic [15:0]  missed_boundaries,
    input logic  [3:0]  read_outstanding_pk,
    input logic  [3:0]  retire_gate_mask,

    output logic [31:0] wr_addr,
    output logic [31:0] wr_data,
    output logic        wr_en,
    input  logic        wr_ready
);

    typedef enum logic [1:0] {IDLE, WRITE_W0, WRITE_W1} state_t;
    state_t state;

    logic [7:0]  sample_seq;
    logic [7:0]  published_seq;
    logic [31:0] latched_wait_cyc;
    logic [15:0] latched_missed_boundaries;
    logic  [3:0] latched_outstanding_pk;
    logic  [3:0] latched_gate_mask;
    logic        initialized;

    wire pending = !initialized || (sample_seq != published_seq);

    assign wr_addr = (state == WRITE_W1) ? (DBG_ADDR + 32'd4) : DBG_ADDR;
    assign wr_data = (state == WRITE_W1)
                      ? {latched_gate_mask, sample_seq, latched_outstanding_pk, latched_missed_boundaries}
                      : latched_wait_cyc;
    assign wr_en   = (state == WRITE_W0) || (state == WRITE_W1);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state                     <= IDLE;
            sample_seq                <= '0;
            published_seq             <= '0;
            latched_wait_cyc          <= '0;
            latched_missed_boundaries <= '0;
            latched_outstanding_pk    <= '0;
            latched_gate_mask         <= '0;
            initialized               <= 1'b0;
        end else begin
            if (retired_edge) begin
                sample_seq                <= sample_seq + 8'd1;
                latched_wait_cyc          <= retire_wait_cyc;
                latched_missed_boundaries <= missed_boundaries;
                latched_outstanding_pk    <= read_outstanding_pk;
                latched_gate_mask         <= retire_gate_mask;
            end

            unique case (state)
                IDLE: begin
                    if (pending) state <= WRITE_W0;
                end

                WRITE_W0: begin
                    if (wr_en && wr_ready) state <= WRITE_W1;
                end

                WRITE_W1: begin
                    if (wr_en && wr_ready) begin
                        published_seq <= sample_seq;
                        initialized   <= 1'b1;
                        state         <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
