// CMDQ: command processor. Decodes one 32-byte command slot at a time,
// presented on a simple valid/ready front end, and dispatches it to BLIT
// (SOLID_FILL), blit_copy (BLIT_COPY / BLIT_COPY_KEY -- both dispatch to
// the same engine, differing only in whether colorkey transparency is on),
// blit_blend (BLIT_BLEND / BLEND_FILL -- BLIT-007/BLIT-010), or present (PRESENT, the
// double-buffer flip -- OUT-004).
//
// ai/core-reference.md CMDQ-001 defines the command slot layout this module
// decodes; BLIT-002/BLIT-003/BLIT-006/BLIT-007 define what each BLIT opcode's fields
// mean; OUT-004 defines PRESENT's.

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
    input  logic                  memory_idle,

    output logic                  copy_start,
    output logic [ADDR_WIDTH-1:0] copy_dst_addr,
    output logic [15:0]           copy_dst_pitch,
    output logic [ADDR_WIDTH-1:0] copy_src_addr,
    output logic [15:0]           copy_src_pitch,
    output logic [15:0]           copy_width,
    output logic [15:0]           copy_height,
    output logic                  copy_key_enable,
    output logic [DATA_WIDTH-1:0] copy_key_value,
    input  logic                  copy_busy,
    input  logic                  copy_done,

    // BLIT_BLEND and BLEND_FILL share the copy_* destination geometry above.
    output logic                  blend_start,
    output logic [7:0]            blend_mod,
    output logic                  blend_solid,
    output logic [DATA_WIDTH-1:0] blend_solid_color,
    output logic                  blend_mode_en,
    output logic [23:0]           blend_mode,
    input  logic                  blend_busy,
    input  logic                  blend_done,

    output logic                  batch_start,
    output logic [ADDR_WIDTH-1:0] batch_base,
    output logic [15:0]           batch_count,
    input  logic                  batch_busy,
    input  logic                  batch_done,

    output logic                  present_start,
    input  logic                  present_busy,
    input  logic                  present_done,

    output logic                   loader_start,
    output logic [ADDR_WIDTH-1:0]  loader_src_addr,
    output logic [ADDR_WIDTH-1:0]  loader_dst_addr,
    output logic [ADDR_WIDTH-1:0]  loader_length,
    input  logic                   loader_busy,
    input  logic                   loader_done
);

    // Command slot layout (32 bytes / 256 bits), all fields plain uint32:
    //   [ 31:  0] opcode    (only [7:0] used)
    //   [ 63: 32] dst_addr
    //   [ 95: 64] dst_pitch (only [15:0] used)
    //   [127: 96] width     (only [15:0] used)
    //   [159:128] height    (only [15:0] used)
    //   [191:160] color                          (SOLID_FILL only)
    //                                             (BLIT_COPY_KEY: colorkey value)
    //                                             (BLIT_BLEND: [7:0] alpha modulation)
    //                                             (BLEND_FILL: constant RGBA source)
    //   [223:192] src_addr                       (BLIT_COPY/BLIT_COPY_KEY only)
    //                                             (LOAD_SDRAM: DDR3 source addr)
    //                                             (BLEND_FILL: explicit mode flags)
    //   [255:224] src_pitch (only [15:0] used)    (BLIT_COPY/BLIT_COPY_KEY only)
    // LOAD_SDRAM (SDR-003) repurposes dst_addr as the SDRAM destination
    // byte address (must be page-aligned, see sdram_loader.sv's header)
    // and color as the 32-bit byte length to copy; dst_pitch/width/height
    // are unused.
    localparam logic [7:0] OP_SOLID_FILL    = 8'h01;
    localparam logic [7:0] OP_BLIT_COPY     = 8'h02;
    localparam logic [7:0] OP_BLIT_COPY_KEY = 8'h03;
    localparam logic [7:0] OP_PRESENT       = 8'h04;
    localparam logic [7:0] OP_SPRITE_BATCH  = 8'h05;
    localparam logic [7:0] OP_LOAD_SDRAM    = 8'h06;
    localparam logic [7:0] OP_BLIT_BLEND    = 8'h07;
    localparam logic [7:0] OP_BLEND_FILL    = 8'h08;
    localparam logic [31:0] DESCRIPTOR_BASE = 32'h3002_2000;
    localparam logic [31:0] DESCRIPTOR_END  = 32'h3004_2000;

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

    typedef enum logic [2:0] {ENGINE_BLIT, ENGINE_COPY, ENGINE_PRESENT, ENGINE_BATCH, ENGINE_LOAD,
                              ENGINE_BLEND} engine_t;
    engine_t active_engine;
    logic engine_done_seen;
    wire engine_busy = (active_engine == ENGINE_COPY)    ? copy_busy :
                        (active_engine == ENGINE_PRESENT) ? present_busy :
                        (active_engine == ENGINE_BATCH) ? batch_busy :
                        (active_engine == ENGINE_LOAD) ? loader_busy :
                        (active_engine == ENGINE_BLEND) ? blend_busy : blit_busy;
    wire engine_done = (active_engine == ENGINE_COPY)    ? copy_done :
                        (active_engine == ENGINE_PRESENT) ? present_done :
                        (active_engine == ENGINE_BATCH) ? batch_done :
                        (active_engine == ENGINE_LOAD) ? loader_done :
                        (active_engine == ENGINE_BLEND) ? blend_done : blit_done;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state          <= IDLE;
            active_engine  <= ENGINE_BLIT;
            engine_done_seen<= 1'b0;
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
            copy_key_enable<= 1'b0;
            copy_key_value <= '0;
            blend_start    <= 1'b0;
            blend_mod      <= '0;
            blend_solid    <= 1'b0;
            blend_solid_color <= '0;
            blend_mode_en  <= 1'b0;
            blend_mode     <= '0;
            batch_start    <= 1'b0;
            batch_base     <= '0;
            batch_count    <= '0;
            present_start  <= 1'b0;
            loader_start    <= 1'b0;
            loader_src_addr <= '0;
            loader_dst_addr <= '0;
            loader_length   <= '0;
        end else begin
            blit_start    <= 1'b0;
            copy_start    <= 1'b0;
            blend_start   <= 1'b0;
            present_start <= 1'b0;
            batch_start    <= 1'b0;
            loader_start   <= 1'b0;

            unique case (state)
                IDLE: begin
                    // Unknown opcodes are accepted and dropped.
                    if (cmd_valid && !blit_busy && !copy_busy && !present_busy && !blend_busy) begin
                        if (op == OP_SOLID_FILL) begin
                            blit_dst_addr  <= c_dst_addr;
                            blit_dst_pitch <= c_dst_pitch;
                            blit_width     <= c_width;
                            blit_height    <= c_height;
                            blit_color     <= c_color;
                            blit_start     <= 1'b1;
                            active_engine  <= ENGINE_BLIT;
                            state          <= WAIT_DONE;
                        end else if (op == OP_BLIT_COPY || op == OP_BLIT_COPY_KEY) begin
                            copy_dst_addr  <= c_dst_addr;
                            copy_dst_pitch <= c_dst_pitch;
                            copy_width     <= c_width;
                            copy_height    <= c_height;
                            copy_src_addr  <= c_src_addr;
                            copy_src_pitch <= c_src_pitch;
                            copy_key_enable<= (op == OP_BLIT_COPY_KEY);
                            copy_key_value <= c_color;
                            copy_start     <= 1'b1;
                            active_engine  <= ENGINE_COPY;
                            state          <= WAIT_DONE;
                        end else if (op == OP_BLIT_BLEND) begin
                            copy_dst_addr  <= c_dst_addr;
                            copy_dst_pitch <= c_dst_pitch;
                            copy_width     <= c_width;
                            copy_height    <= c_height;
                            copy_src_addr  <= c_src_addr;
                            copy_src_pitch <= c_src_pitch;
                            blend_mod      <= c_color[7:0];
                            blend_solid    <= 1'b0;
                            blend_mode_en  <= 1'b0;
                            blend_start    <= 1'b1;
                            active_engine  <= ENGINE_BLEND;
                            state          <= WAIT_DONE;
                        end else if (op == OP_BLEND_FILL) begin
                            copy_dst_addr  <= c_dst_addr;
                            copy_dst_pitch <= c_dst_pitch;
                            copy_width     <= c_width;
                            copy_height    <= c_height;
                            blend_mod      <= 8'hff;
                            blend_solid_color <= c_color;
                            blend_solid    <= 1'b1;
                            blend_mode_en  <= 1'b1;
                            blend_mode     <= c_src_addr[31:8];
                            blend_start    <= 1'b1;
                            active_engine  <= ENGINE_BLEND;
                            state          <= WAIT_DONE;
                        end else if (op == OP_PRESENT) begin
                            present_start <= 1'b1;
                            active_engine <= ENGINE_PRESENT;
                            state         <= WAIT_DONE;
                        end else if (op == OP_SPRITE_BATCH && c_width != 0 && c_width <= 64 &&
                                     c_dst_addr >= DESCRIPTOR_BASE &&
                                     c_dst_addr < DESCRIPTOR_END &&
                                     c_dst_addr[10:0] == 11'd0) begin
                            // Protocol 1.5 selects one aligned 2 KiB table
                            // from the bounded 64-table descriptor pool.
                            batch_base <= c_dst_addr;
                            batch_count <= c_width;
                            batch_start <= 1'b1;
                            active_engine <= ENGINE_BATCH;
                            state <= WAIT_DONE;
                        end else if (op == OP_LOAD_SDRAM) begin
                            loader_src_addr <= c_src_addr;
                            loader_dst_addr <= c_dst_addr;
                            loader_length   <= c_color;
                            loader_start    <= 1'b1;
                            active_engine   <= ENGINE_LOAD;
                            state           <= WAIT_DONE;
                        end
                    end
                end

                WAIT_DONE: begin
                    if (engine_done) engine_done_seen <= 1'b1;
                    if ((engine_done || engine_done_seen) && memory_idle) begin
                        state <= IDLE;
                        engine_done_seen <= 1'b0;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    assign cmd_ready = (state == IDLE) && !engine_busy;

endmodule
