// PRESENT: display-buffer flip, synced to the framework's vertical blank so
// changing FB_BASE never happens mid-scan-out (tearing). Owns a two-bit
// front_idx register (0 = buffer A, 1 = buffer B, 2 = buffer C) that
// Noodles.sv uses to drive FB_BASE; the host draws into a buffer that is
// neither front nor awaiting a flip, then issues a PRESENT to show it.
//
// fb_vbl is FB_VBL, the framework's vblank level signal -- safe to sample
// directly with no cross-clock synchronizer, because CLK_VIDEO (this
// core's own output) IS what the framework uses to generate it: Noodles.sv
// ties CLK_VIDEO to clk_sys, so fb_vbl is already in this exact clock
// domain, not a separate one.
//
// Deliberately its own tiny module, not folded into cmdq.sv or an existing
// engine: it never touches DDRAM_* at all (no read or write port), it only
// flips a register, so it doesn't share any of blit.sv/blit_copy.sv's
// structure. ai/core-reference.md OUT-004 defines legacy PRESENT's
// semantics and OUT-013 the queued three-buffer flip.
//
// Legacy PRESENT (queued=0) toggles between A and B, captures the
// retirement acknowledgement level when it starts and pulses done when it
// retires, which is what completes its command. A queued flip (queued=1)
// shows the explicit target buffer; CMDQ has already completed its command
// on acceptance, so it pulses only retired. It captures the acknowledgement
// level at the flip, so retirement always follows a scaler boundary after
// the new base took effect and the previous front buffer is no longer read
// before the next queued flip can be accepted and later draws reuse it.

module present #(
    // Keep one fresh video boundary after ascal reports its output-domain
    // retirement boundary so outstanding activity has an extra interval.
    parameter integer RETIRE_VBLANKS = 1
) (
    input  logic clk,
    input  logic reset,

    input  logic fb_vbl,
    input  logic fb_retired,

    input  logic       start,
    input  logic       queued,
    input  logic [1:0] target,     // queued flips only
    output logic busy,
    output logic done,        // one-cycle pulse, legacy PRESENT only
    output logic retired,     // one-cycle pulse, every flip

    output logic [1:0] front_idx
);

    logic fb_vbl_d;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) fb_vbl_d <= 1'b0;
        else       fb_vbl_d <= fb_vbl;
    end
    wire vbl_rising = fb_vbl && !fb_vbl_d;

    typedef enum logic [2:0] {IDLE, WAIT_VBL, WAIT_ACK, RETIRE, FINISH} state_t;
    state_t state;
    integer vbl_count;
    logic ack_baseline;
    logic notify;
    logic capture_at_flip;
    logic [1:0] next_idx;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state        <= IDLE;
            busy         <= 1'b0;
            done         <= 1'b0;
            retired      <= 1'b0;
            front_idx    <= 2'd0;
            vbl_count    <= 0;
            ack_baseline <= 1'b0;
            notify       <= 1'b0;
            capture_at_flip <= 1'b0;
            next_idx     <= 2'd0;
        end else begin
            done    <= 1'b0;
            retired <= 1'b0;

            unique case (state)
                IDLE: begin
                    if (start) begin
                        busy         <= 1'b1;
                        vbl_count    <= 0;
                        ack_baseline <= fb_retired;
                        notify       <= !queued;
                        capture_at_flip <= queued;
                        next_idx     <= queued ? target : (front_idx == 2'd1 ? 2'd0 : 2'd1);
                        state        <= WAIT_VBL;
                    end
                end

                // Waits for the NEXT vblank rising edge, even if fb_vbl is
                // already high when start arrives -- flipping right at the
                // start of a blanking interval gives the most margin
                // before active video resumes, rather than risking a flip
                // moments before vblank ends.
                WAIT_VBL: begin
                    if (vbl_rising) begin
                        front_idx <= next_idx;
                        if (capture_at_flip) ack_baseline <= fb_retired;
                        state <= WAIT_ACK;
                    end
                end

                WAIT_ACK: begin
                    if (fb_retired != ack_baseline) begin
                        vbl_count <= 0;
                        if (RETIRE_VBLANKS == 0)
                            state <= FINISH;
                        else
                            state <= RETIRE;
                    end
                end

                RETIRE: begin
                    if (vbl_rising) begin
                        if (vbl_count + 1 >= RETIRE_VBLANKS)
                            state <= FINISH;
                        else
                            vbl_count <= vbl_count + 1;
                    end
                end

                FINISH: begin
                    busy    <= 1'b0;
                    done    <= notify;
                    retired <= 1'b1;
                    state   <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
