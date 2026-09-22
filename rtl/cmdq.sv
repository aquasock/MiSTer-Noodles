// CMDQ: command processor. v1 decodes one 32-byte command slot at a time,
// presented on a simple valid/ready front end, and dispatches it to BLIT
// (SOLID_FILL) or blit_copy (BLIT_COPY). The front end that fetches slots
// from a host-built command list over the HPS-FPGA link (LINK-001) is not
// implemented yet -- see core-reference.md LINK-001's consequence. Today
// cmd_valid/cmd_data are driven directly by whatever front end exists
// (currently the simulation testbenches and Noodles.sv's hardcoded OSD test
// triggers).
//
// ai/core-reference.md CMDQ-001 defines the command slot layout this module
// decodes; BLIT-002/BLIT-003 define what each opcode's fields mean.

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
    input  logic                  blit_done,

    output logic                  copy_start,
    output logic [ADDR_WIDTH-1:0] copy_dst_addr,
    output logic [15:0]           copy_dst_pitch,
    output logic [ADDR_WIDTH-1:0] copy_src_addr,
    output logic [15:0]           copy_src_pitch,
    output logic [15:0]           copy_width,
    output logic [15:0]           copy_height,
    input  logic                  copy_busy,
    input  logic                  copy_done
);

    // Command slot layout (32 bytes / 256 bits), all fields plain uint32:
    //   [ 31:  0] opcode    (only [7:0] used)
    //   [ 63: 32] dst_addr
    //   [ 95: 64] dst_pitch (only [15:0] used)
    //   [127: 96] width     (only [15:0] used)
    //   [159:128] height    (only [15:0] used)
    //   [191:160] color                          (SOLID_FILL only)
    //   [223:192] src_addr                       (BLIT_COPY only)
    //   [255:224] src_pitch (only [15:0] used)    (BLIT_COPY only)
    localparam logic [7:0] OP_SOLID_FILL = 8'h01;
    localparam logic [7:0] OP_BLIT_COPY  = 8'h02;

    wire [7:0]  op          = cmd_data[7:0];
    wire [31:0] c_dst_addr  = cmd_data[63:32];
    wire [15:0] c_dst_pitch = cmd_data[79:64];
    wire [15:0] c_width     = cmd_data[111:96];
    wire [15:0] c_height    = cmd_data[143:128];
    wire [31:0] c_color     = cmd_data[191:160];
    wire [31:0] c_src_addr  = cmd_data[223:192];
    wire [15:0] c_src_pitch = cmd_data[239:224];

    typedef enum logic {IDLE, WAIT_DONE} state_t;
    state_t state;

    logic active_copy;
    wire  engine_busy = active_copy ? copy_busy : blit_busy;
    wire  engine_done = active_copy ? copy_done : blit_done;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state          <= IDLE;
            active_copy    <= 1'b0;
            blit_start     <= 1'b0;
            blit_dst_addr  <= '0;
            blit_dst_pitch <= '0;
            blit_width     <= '0;
            blit_height    <= '0;
            blit_color     <= '0;
            copy_start     <= 1'b0;
            copy_dst_addr  <= '0;
            copy_dst_pitch <= '0;
            copy_src_addr  <= '0;
            copy_src_pitch <= '0;
            copy_width     <= '0;
            copy_height    <= '0;
        end else begin
            blit_start <= 1'b0;
            copy_start <= 1'b0;

            unique case (state)
                IDLE: begin
                    // An unrecognized opcode is accepted and dropped: only
                    // two opcodes exist until a later milestone adds more.
                    if (cmd_valid && !blit_busy && !copy_busy) begin
                        if (op == OP_SOLID_FILL) begin
                            blit_dst_addr  <= c_dst_addr;
                            blit_dst_pitch <= c_dst_pitch;
                            blit_width     <= c_width;
                            blit_height    <= c_height;
                            blit_color     <= c_color;
                            blit_start     <= 1'b1;
                            active_copy    <= 1'b0;
                            state          <= WAIT_DONE;
                        end else if (op == OP_BLIT_COPY) begin
                            copy_dst_addr  <= c_dst_addr;
                            copy_dst_pitch <= c_dst_pitch;
                            copy_width     <= c_width;
                            copy_height    <= c_height;
                            copy_src_addr  <= c_src_addr;
                            copy_src_pitch <= c_src_pitch;
                            copy_start     <= 1'b1;
                            active_copy    <= 1'b1;
                            state          <= WAIT_DONE;
                        end
                    end
                end

                WAIT_DONE: begin
                    if (engine_done) state <= IDLE;
                end

                default: state <= IDLE;
            endcase
        end
    end

    assign cmd_ready = (state == IDLE) && !engine_busy;

endmodule
