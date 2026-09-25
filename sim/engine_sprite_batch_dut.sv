// Simulation-only wiring of sprite_batch (the descriptor sequencer CMDQ's
// SPRITE_BATCH opcode dispatches to) plus the real DDRAM adapter
// (DDR-003/DDR-007), mirroring Noodles.sv's own read-port mux between
// sprite_batch's single-word descriptor-fetch port and its rd64 pass-through
// to blit_copy64 -- this is the first simulation coverage of sprite_batch's
// own multi-descriptor DESC_REQ/DESC_WAIT/LAUNCH/COPY loop end to end;
// previously only CMDQ's opcode decode (stubbing batch_busy/batch_done
// directly) and blit_copy64 in isolation (driven straight from a
// testbench, bypassing descriptor fetch) had coverage.
// BLIT-008 flagged descriptors run on the external blit_blend engine, so
// this wrapper also carries it with Noodles.sv's arbitration: the blend
// engine owns the memory ports while busy, and every write client's ready
// comes from the adapter's queue space and that client's own requests.
module engine_sprite_batch_dut (
    input  logic          clk,
    input  logic          reset,

    input  logic          start,
    input  logic [31:0]   descriptor_base,
    input  logic [15:0]   count,
    output logic          busy,
    output logic          done,

    output logic         DDRAM_CLK,
    input  logic         DDRAM_BUSY,
    output logic [7:0]   DDRAM_BURSTCNT,
    output logic [28:0]  DDRAM_ADDR,
    input  logic [63:0]  DDRAM_DOUT,
    input  logic          DDRAM_DOUT_READY,
    output logic [63:0]  DDRAM_DIN,
    output logic [7:0]   DDRAM_BE,
    output logic         DDRAM_WE,
    output logic         DDRAM_RD
);

    logic [31:0] batch_rd_addr, batch_rd_data;
    logic        batch_rd_en, batch_rd_ready, batch_rd_valid, batch_rd_active;
    logic [31:0] batch_rd64_addr;
    logic [63:0] batch_rd64_data;
    logic        batch_rd64_en, batch_rd64_ready, batch_rd64_valid;
    logic [7:0]  batch_rd64_len;
    logic [31:0] batch_wr_addr, batch_wr_data;
    logic        batch_wr_en, batch_wr_ready;
    logic [31:0] batch_wr64_addr;
    logic [63:0] batch_wr64_data;
    logic        batch_wr64_en, batch_wr64_ready;
    logic        adapter_idle, adapter_wr_space;

    logic        blend_start, blend_busy, blend_done;
    logic [31:0] blend_dst_addr, blend_src_addr, blend_mod;
    logic [15:0] blend_dst_pitch, blend_src_pitch, blend_width, blend_height;
    logic        blend_enable, blend_mirror_x, blend_mirror_y, blend_key_enable;
    logic [31:0] blend_key_value;
    logic        blend_mode_en;
    logic [23:0] blend_mode;
    logic [31:0] blend_rd64_addr, blend_wr_addr, blend_wr_data, blend_wr64_addr;
    logic [63:0] blend_wr64_data;
    logic [7:0]  blend_rd64_len;
    logic        blend_rd64_en, blend_wr_en, blend_wr64_en;
    logic        blend_wr_ready, blend_wr64_ready, blend_rd64_ready, blend_rd64_valid;
    logic        rd64_ready, rd64_valid;
    logic [63:0] rd64_data;

    sprite_batch sprite_batch_i (
        .clk(clk), .reset(reset), .start(start), .descriptor_base(descriptor_base),
        .count(count),
        .busy(busy), .done(done),
        .rd_addr(batch_rd_addr), .rd_en(batch_rd_en), .rd_active(batch_rd_active),
        .rd_ready(batch_rd_ready), .rd_data(batch_rd_data), .rd_valid(batch_rd_valid),
        .rd64_addr(batch_rd64_addr), .rd64_en(batch_rd64_en),
        .rd64_len(batch_rd64_len),
        .rd64_ready(batch_rd64_ready), .rd64_data(batch_rd64_data), .rd64_valid(batch_rd64_valid),
        .wr_addr(batch_wr_addr), .wr_data(batch_wr_data), .wr_en(batch_wr_en),
        .wr_ready(batch_wr_ready),
        .wr64_addr(batch_wr64_addr), .wr64_data(batch_wr64_data),
        .wr64_en(batch_wr64_en), .wr64_ready(batch_wr64_ready),
        .memory_idle(adapter_idle),
        .blend_start(blend_start),
        .blend_dst_addr(blend_dst_addr), .blend_dst_pitch(blend_dst_pitch),
        .blend_src_addr(blend_src_addr), .blend_src_pitch(blend_src_pitch),
        .blend_width(blend_width), .blend_height(blend_height), .blend_mod(blend_mod),
        .blend_enable(blend_enable), .blend_mirror_x(blend_mirror_x),
        .blend_mirror_y(blend_mirror_y), .blend_key_enable(blend_key_enable),
        .blend_key_value(blend_key_value), .blend_mode_en(blend_mode_en),
        .blend_mode(blend_mode), .blend_done(blend_done)
    );

    blit_blend blend_i (
        .clk(clk), .reset(reset), .start(blend_start),
        .dst_addr(blend_dst_addr), .dst_pitch(blend_dst_pitch),
        .src_addr(blend_src_addr), .src_pitch(blend_src_pitch),
        .width(blend_width), .height(blend_height), .mod(blend_mod),
        .blend(blend_enable), .mirror_x(blend_mirror_x), .mirror_y(blend_mirror_y),
        .solid(1'b0), .solid_color(32'd0),
        .key_enable(blend_key_enable), .key_value(blend_key_value),
        .mode_en(blend_mode_en), .mode(blend_mode),
        .busy(blend_busy), .done(blend_done),
        .rd64_addr(blend_rd64_addr), .rd64_en(blend_rd64_en), .rd64_len(blend_rd64_len),
        .rd64_ready(blend_rd64_ready), .rd64_data(rd64_data), .rd64_valid(blend_rd64_valid),
        .wr_addr(blend_wr_addr), .wr_data(blend_wr_data), .wr_en(blend_wr_en),
        .wr_ready(blend_wr_ready),
        .wr64_addr(blend_wr64_addr), .wr64_data(blend_wr64_data),
        .wr64_en(blend_wr64_en), .wr64_ready(blend_wr64_ready)
    );

    // Mirrors Noodles.sv: blend first while busy, otherwise sprite_batch.
    wire sel_blend = blend_busy;
    wire [31:0] wr_addr = sel_blend ? blend_wr_addr : batch_wr_addr;
    wire [31:0] wr_data = sel_blend ? blend_wr_data : batch_wr_data;
    wire        wr_en = sel_blend ? blend_wr_en : batch_wr_en;
    wire [31:0] wr64_addr = sel_blend ? blend_wr64_addr : batch_wr64_addr;
    wire [63:0] wr64_data = sel_blend ? blend_wr64_data : batch_wr64_data;
    wire        wr64_en = sel_blend ? blend_wr64_en : batch_wr64_en;
    assign      blend_wr_ready = sel_blend && adapter_wr_space && !blend_wr64_en;
    assign      blend_wr64_ready = sel_blend && adapter_wr_space;
    assign batch_wr_ready = !sel_blend && adapter_wr_space && !batch_wr64_en;
    assign batch_wr64_ready = !sel_blend && adapter_wr_space;
    // Mirrors Noodles.sv's registered read owner: a client is granted the
    // read port one cycle after it becomes active, batch before blend.
    logic rd_owner_batch, rd_owner_blend;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            rd_owner_batch <= 1'b0;
            rd_owner_blend <= 1'b0;
        end else begin
            rd_owner_batch <= batch_rd_active;
            rd_owner_blend <= !batch_rd_active && blend_busy;
        end
    end
    wire rd_sel_batch64 = rd_owner_batch && batch_rd64_en;
    wire rd_sel_blend64 = rd_owner_blend && blend_rd64_en;
    wire [31:0] rd64_addr = rd_sel_batch64 ? batch_rd64_addr :
                            rd_sel_blend64 ? blend_rd64_addr : 32'b0;
    wire [7:0]  rd64_len = rd_sel_batch64 ? batch_rd64_len :
                           rd_sel_blend64 ? blend_rd64_len : 8'd1;
    wire        rd64_en = rd_sel_batch64 || rd_sel_blend64;
    assign blend_rd64_ready = rd_sel_blend64 ? rd64_ready : 1'b0;
    assign batch_rd64_ready = rd_sel_batch64 ? rd64_ready : 1'b0;
    assign batch_rd64_data = rd64_data;
    assign batch_rd64_valid = rd_owner_batch && rd64_valid;
    assign blend_rd64_valid = rd_owner_blend && rd64_valid;

    ddram_adapter adapter_i (
        .clk             (clk),
        .reset           (reset),
        .wr_addr         (wr_addr),
        .wr_data         (wr_data),
        .wr_en           (wr_en),
        /* verilator lint_off PINCONNECTEMPTY */
        .wr_ready        (),
        .wr64_ready      (),
        /* verilator lint_on PINCONNECTEMPTY */
        .wr64_addr       (wr64_addr),
        .wr64_data       (wr64_data),
        .wr64_en         (wr64_en),
        .wr_space        (adapter_wr_space),
        .rd_addr         (batch_rd_addr),
        .rd_en           (batch_rd_en),
        .rd_ready        (batch_rd_ready),
        .rd_data         (batch_rd_data),
        .rd_valid        (batch_rd_valid),
        .rd64_addr       (rd64_addr),
        .rd64_en         (rd64_en),
        .rd64_len        (rd64_len),
        .rd64_ready      (rd64_ready),
        .rd64_data       (rd64_data),
        .rd64_valid      (rd64_valid),
        .ddram_clk       (DDRAM_CLK),
        .ddram_busy      (DDRAM_BUSY),
        .ddram_burstcnt  (DDRAM_BURSTCNT),
        .ddram_addr      (DDRAM_ADDR),
        .ddram_dout      (DDRAM_DOUT),
        .ddram_dout_ready(DDRAM_DOUT_READY),
        .ddram_din       (DDRAM_DIN),
        .ddram_be        (DDRAM_BE),
        .ddram_we        (DDRAM_WE),
        .ddram_rd        (DDRAM_RD),
        .idle            (adapter_idle)
    );

endmodule
