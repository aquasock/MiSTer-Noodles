// PRESENT: display-buffer flip, synced to the framework's vertical blank so
// changing FB_BASE never happens mid-scan-out (tearing). Owns a two-bit
// front_idx register (0 = buffer A, 1 = buffer B, 2 = buffer C) that
// Noodles.sv uses to drive FB_BASE; the host draws into a buffer that is
// neither front nor awaiting a flip, then issues a PRESENT to show it.
//
// fb_vbl and fb_retired are the framework's vertical-blank level and
// retirement toggle after Noodles.sv's two-flop synchronizers into clk.
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

`ifdef FORMAL
    // Properties proved by fv/present.sby. fb_vbl and fb_retired are
    // unconstrained; start follows CMDQ's proved contract (never while busy,
    // and a queued flip names buffer 0-2).
    logic f_past_valid = 1'b0;
    always_ff @(posedge clk) f_past_valid <= 1'b1;
    always_comb begin
        if (!f_past_valid) assume(reset);
        if (start) assume(!busy);
        if (start && queued) assume(target != 2'd3);
    end

    // f_pending: a flip was started and has not yet retired. f_flipped: its
    // new buffer has been selected. f_level is the acknowledgement level the
    // flip must see change before it retires: sampled at start for a legacy
    // PRESENT and at the flip for a queued one, f_changed records a change.
    logic f_pending, f_flipped, f_queued, f_changed, f_level;
    logic [1:0] f_target;
    wire f_flip_now = state == WAIT_VBL && vbl_rising;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            {f_pending, f_flipped, f_queued, f_changed, f_level} <= '0;
            f_target <= 2'd0;
        end else if (start) begin
            f_pending <= 1'b1;
            f_flipped <= 1'b0;
            f_queued  <= queued;
            f_target  <= target;
            f_level   <= fb_retired;
            f_changed <= 1'b0;
        end else begin
            if (retired) f_pending <= 1'b0;
            if (f_flip_now) begin
                f_flipped <= 1'b1;
                if (f_queued) begin
                    f_level   <= fb_retired;
                    f_changed <= 1'b0;
                end
            end else if (fb_retired != f_level) begin
                f_changed <= 1'b1;
            end
        end
    end

    always_ff @(posedge clk) if (f_past_valid && !reset && !$past(reset)) begin
        // The displayed buffer changes only at the start of vertical blank.
        if (front_idx != $past(front_idx)) assert($past(f_flip_now));
    end

    always_comb if (f_past_valid && !reset) begin
        assert(front_idx != 2'd3 && next_idx != 2'd3);
        // busy spans exactly the flips that have started and not retired.
        assert(busy == (f_pending && !retired));
        // Each flip retires once, only after its buffer was selected and the
        // scaler acknowledged a boundary after the relevant sample; a queued
        // flip shows the buffer it named. Only a legacy PRESENT reports done.
        if (retired) assert(f_pending && f_flipped && f_changed);
        if (retired && f_queued) assert(front_idx == f_target);
        if (done) assert(retired && !f_queued);
        // Inductive link between the model and the state machine.
        assert((state == IDLE) == (!f_pending || retired));
        if (state == WAIT_VBL) assert(!f_flipped && notify == !f_queued && ack_baseline == f_level &&
                                      capture_at_flip == f_queued &&
                                      (f_queued ? next_idx == f_target : 1'b1));
        if (state == WAIT_ACK || state == RETIRE || state == FINISH)
            assert(f_flipped && ack_baseline == f_level && (!f_queued || front_idx == f_target) &&
                   notify == !f_queued && capture_at_flip == f_queued);
        if (state == RETIRE || state == FINISH) assert(f_changed);
    end

    always_comb if (f_past_valid && !reset) begin
        cover(retired && f_queued);
        cover(done);
        cover(f_pending && f_flipped && !retired && start == 1'b0 && state == WAIT_ACK);
    end
`endif

endmodule
