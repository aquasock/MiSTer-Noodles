// LINK-005: a completion fence for LINK-001's ring buffer. link_ring's own
// read_ptr (LINK-003) advances the moment CMDQ ACCEPTS a command for
// dispatch, not when it finishes executing -- fine for ring-slot reuse
// (CMDQ has already copied every field it needs out of DRAM by then), but
// it gives the host no way to know when a command's pixels have actually
// landed. This module is a separate, minimal answer to that: a monotonic
// counter in DRAM, incremented once per command that genuinely finishes
// (CMDQ's blit_done/copy_done, ORed together upstream in Noodles.sv), that
// the host can poll and compare against its own submitted-command count.
//
// Deliberately NOT folded into link_ring.sv's own FSM: that module's
// polling/fetch/dispatch/writeback cycle was hard-won (see DDR-005), and
// this concern -- "publish a value to DRAM whenever an unrelated pulse
// fires" -- doesn't need any of that state machine's complexity. It only
// needs a write port, which Noodles.sv's existing write-mux pattern
// (marker_test, blit, blit_copy, link_ring) already knows how to share.
//
// ai/core-reference.md LINK-005 defines the DRAM field and host-visible
// contract this module implements.

module link_fence #(
    parameter logic [31:0] FENCE_ADDR = 32'h3002_000C
) (
    input  logic clk,
    input  logic reset,

    input  logic done_pulse,  // one cycle high per command that finished (not just dispatched)

    output logic [31:0] wr_addr,
    output logic [31:0] wr_data,
    output logic         wr_en,
    input  logic         wr_ready
);

    typedef enum logic {IDLE, WRITE_REQ} state_t;
    state_t state;

    // done_count is free-running and never stalls waiting for a write --
    // a completion is never lost even if several land faster than this
    // module can publish them (CMDQ's own serial dispatch makes that
    // realistically impossible today, but the design doesn't depend on
    // that assumption). published_count/write_value track what has
    // actually made it to DRAM; IDLE re-checks after every completed write
    // and immediately starts another if done_count moved again meanwhile,
    // so the host always eventually sees the true latest count.
    //
    // `initialized` (not a separate INIT state) is what makes the very
    // first publish write a 0 -- DRAM isn't cleared by an FPGA reset, so
    // without it a fresh core load could read back a stale nonzero count
    // from a previous session, exactly the same hazard LINK-003's
    // INIT_WPTR/INIT_RPTR exist to prevent for write_ptr/read_ptr. Folding
    // it into `pending` rather than a distinct state matters: state resets
    // to IDLE (wr_en=0), not a write-asserting state, so wr_en never goes
    // high while `reset` itself is still asserted -- the write mux/adapter
    // downstream have no `reset` input of their own to gate against that.
    logic [31:0] done_count;
    logic [31:0] published_count;
    logic [31:0] write_value;
    logic        initialized;

    wire pending = !initialized || (done_count != published_count);

    assign wr_addr = FENCE_ADDR;
    assign wr_data = write_value;
    assign wr_en   = (state == WRITE_REQ);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state           <= IDLE;
            done_count      <= '0;
            published_count <= '0;
            write_value     <= '0;
            initialized     <= 1'b0;
        end else begin
            if (done_pulse) done_count <= done_count + 32'd1;

            unique case (state)
                IDLE: begin
                    if (pending) begin
                        write_value <= initialized ? done_count : 32'd0;
                        state       <= WRITE_REQ;
                    end
                end

                WRITE_REQ: begin
                    if (wr_en && wr_ready) begin
                        published_count <= write_value;
                        initialized     <= 1'b1;
                        state           <= IDLE;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
