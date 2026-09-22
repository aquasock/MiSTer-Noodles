// CMDQ: command processor. v1 decodes one 32-byte command slot at a time,
// presented on a simple valid/ready front end, and dispatches it to BLIT.
// The front end that fetches slots from a host-built command list over the
// HPS-FPGA link (LINK-001) is not implemented yet -- see core-reference.md
// LINK-001's consequence. Today cmd_valid/cmd_data are driven directly by
// whatever front end exists (currently just the simulation testbench).
//
// ai/core-reference.md CMDQ-001 defines the command slot layout this module
// decodes.

module cmdq #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32
) (
    input  logic          clk,
    input  logic          reset,

    input  logic          cmd_valid,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [255:0]  cmd_data,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic          cmd_ready,

    output logic                  blit_start,
    output logic [ADDR_WIDTH-1:0] blit_dst_addr,
    output logic [15:0]           blit_dst_pitch,
    output logic [15:0]           blit_width,
    output logic [15:0]           blit_height,
    output logic [DATA_WIDTH-1:0] blit_color,
    input  logic                  blit_busy,
    input  logic                  blit_done
);

    // Command slot layout (32 bytes / 256 bits), all fields plain uint32:
    //   [ 31:  0] opcode    (only [7:0] used)
    //   [ 63: 32] dst_addr
    //   [ 95: 64] dst_pitch (only [15:0] used)
    //   [127: 96] width     (only [15:0] used)
    //   [159:128] height    (only [15:0] used)
    //   [191:160] color
    //   [223:192] reserved0
    //   [255:224] reserved1
    localparam logic [7:0] OP_SOLID_FILL = 8'h01;

    wire [7:0]  op        = cmd_data[7:0];
    wire [31:0] c_dst_addr  = cmd_data[63:32];
    wire [15:0] c_dst_pitch = cmd_data[79:64];
    wire [15:0] c_width     = cmd_data[111:96];
    wire [15:0] c_height    = cmd_data[143:128];
    wire [31:0] c_color     = cmd_data[191:160];

    typedef enum logic {IDLE, WAIT_DONE} state_t;
    state_t state;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state          <= IDLE;
            blit_start     <= 1'b0;
            blit_dst_addr  <= '0;
            blit_dst_pitch <= '0;
            blit_width     <= '0;
            blit_height    <= '0;
            blit_color     <= '0;
        end else begin
            blit_start <= 1'b0;

            unique case (state)
                IDLE: begin
                    // An unrecognized opcode is accepted and dropped: there
                    // is only one opcode until a later milestone adds more.
                    if (cmd_valid && !blit_busy && op == OP_SOLID_FILL) begin
                        blit_dst_addr  <= c_dst_addr;
                        blit_dst_pitch <= c_dst_pitch;
                        blit_width     <= c_width;
                        blit_height    <= c_height;
                        blit_color     <= c_color;
                        blit_start     <= 1'b1;
                        state          <= WAIT_DONE;
                    end
                end

                WAIT_DONE: begin
                    if (blit_done) state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    assign cmd_ready = (state == IDLE) && !blit_busy;

endmodule
