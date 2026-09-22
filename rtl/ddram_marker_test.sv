// One-shot diagnostic: on a rising edge of `trigger`, writes exactly one
// fixed marker word to a fixed address via the generic write port (DDR-001)
// and then stops -- holding trigger high does not cause repeated writes.
// This is the executable form of DDR-002's planned check: whether
// DDRAM_ADDR=0 really is Linux physical address 0x20000000. It exists to be
// deliberately, individually triggered (an OSD button), never wired to
// anything automatic -- see the header comment in Noodles.sv.

module ddram_marker_test #(
    parameter logic [31:0] MARKER_ADDR  = 32'h0000_0000,
    parameter logic [31:0] MARKER_VALUE = 32'hDEAD_BEEF
) (
    input  logic clk,
    input  logic reset,

    input  logic trigger,   // raw level; edge-detected internally
    output logic busy,
    output logic done,      // one-cycle pulse when the write is accepted

    output logic [31:0] wr_addr,
    output logic [31:0] wr_data,
    output logic        wr_en,
    input  logic        wr_ready
);

    logic trigger_d;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) trigger_d <= 1'b0;
        else       trigger_d <= trigger;
    end
    wire trigger_rise = trigger & ~trigger_d;

    typedef enum logic [1:0] {IDLE, WRITE, FINISH} state_t;
    state_t state;

    assign wr_addr = MARKER_ADDR;
    assign wr_data = MARKER_VALUE;
    assign wr_en   = (state == WRITE);

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
                        state <= WRITE;
                    end
                end

                WRITE: begin
                    if (wr_en && wr_ready) state <= FINISH;
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
