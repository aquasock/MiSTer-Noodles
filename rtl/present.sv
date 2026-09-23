// PRESENT: double-buffer flip, synced to the framework's vertical blank so
// changing FB_BASE never happens mid-scan-out (tearing). Owns a single
// front_sel register (0 = buffer A front, 1 = buffer B front) that
// Noodles.sv uses to drive FB_BASE; the host draws into whichever buffer
// is NOT currently front, then issues this command to swap.
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
// structure. ai/core-reference.md OUT-004 defines PRESENT's semantics and
// the double-buffer address layout.

module present #(
    // Keep one fresh video boundary after ascal reports its output-domain
    // retirement boundary so outstanding activity has an extra interval.
    parameter integer RETIRE_VBLANKS = 1
) (
    input  logic clk,
    input  logic reset,

    input  logic fb_vbl,
    input  logic fb_retired,

    input  logic start,
    output logic busy,
    output logic done,        // one-cycle pulse

    output logic front_sel    // 0 = buffer A front, 1 = buffer B front
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

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state     <= IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            front_sel <= 1'b0;
            vbl_count <= 0;
        end else begin
            done <= 1'b0;

            unique case (state)
                IDLE: begin
                    if (start) begin
                        busy      <= 1'b1;
                        vbl_count <= 0;
                        ack_baseline <= fb_retired;
                        state     <= WAIT_VBL;
                    end
                end

                // Waits for the NEXT vblank rising edge, even if fb_vbl is
                // already high when start arrives -- flipping right at the
                // start of a blanking interval gives the most margin
                // before active video resumes, rather than risking a flip
                // moments before vblank ends.
                WAIT_VBL: begin
                    if (vbl_rising) begin
                        if (vbl_count == 0)
                            front_sel <= ~front_sel;
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
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
