// One-shot diagnostic/bring-up helper: on a rising edge of `trigger`, feeds
// one fixed 256-bit command through CMDQ's front end and stops -- holding
// trigger high does not cause repeated submissions. Same shape as
// rtl/ddram_marker_test.sv, but through CMDQ's real command interface
// (CMDQ-001) instead of BLIT's write port directly.
//
// This stands in for LINK's not-yet-built ring buffer: an OSD button is
// today's only way to get a command into CMDQ. See the note in
// ai/core-reference.md CMDQ-002 and LINK-001's still-open consequence.

module cmd_test_trigger #(
    parameter logic [255:0] COMMAND = 256'd0
) (
    input  logic clk,
    input  logic reset,

    input  logic trigger,   // raw level; edge-detected internally
    output logic busy,
    output logic done,      // one-cycle pulse when CMDQ accepts the command

    output logic [255:0] cmd_data,
    output logic         cmd_valid,
    input  logic         cmd_ready
);

    logic trigger_d;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) trigger_d <= 1'b0;
        else       trigger_d <= trigger;
    end
    wire trigger_rise = trigger & ~trigger_d;

    typedef enum logic [1:0] {IDLE, SEND, FINISH} state_t;
    state_t state;

    assign cmd_data  = COMMAND;
    assign cmd_valid = (state == SEND);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state <= IDLE;
            busy  <= 1'b0;
            done  <= 1'b0;
        end else begin
            done <= 1'b0;

            unique case (state)
                IDLE: begin
                    if (trigger_rise) begin
                        busy  <= 1'b1;
                        state <= SEND;
                    end
                end

                SEND: begin
                    if (cmd_valid && cmd_ready) state <= FINISH;
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
