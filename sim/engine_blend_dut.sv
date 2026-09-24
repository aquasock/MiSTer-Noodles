// Simulation-only wiring of blit_blend (BLIT-007) plus the real DDRAM
// adapter, exposing the DDRAM_* signal names so the testbench can drive a
// behavioral Avalon-MM memory model that honors DDRAM_BURSTCNT. Command
// fields are driven straight from the testbench; CMDQ decode is covered
// separately.

module engine_blend_dut (
    input  logic          clk,
    input  logic          reset,

    input  logic          start,
    input  logic [31:0]   dst_addr,
    input  logic [15:0]   dst_pitch,
    input  logic [31:0]   src_addr,
    input  logic [15:0]   src_pitch,
    input  logic [15:0]   width,
    input  logic [15:0]   height,
    input  logic [31:0]   mod,
    input  logic          blend,
    input  logic          solid,
    input  logic [31:0]   solid_color,
    input  logic          mirror_x,
    input  logic          mirror_y,
    input  logic          mode_en,
    input  logic [23:0]   mode,
    input  logic          key_enable,
    input  logic [31:0]   key_value,
    output logic          busy,
    output logic          done,
    output logic          adapter_idle,

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

    logic [31:0] rd64_addr;
    logic        rd64_en, rd64_ready, rd64_valid;
    logic [7:0]  rd64_len;
    logic [63:0] rd64_data;
    logic [31:0] wr_addr, wr_data;
    logic        wr_en, wr_ready;
    logic [31:0] wr64_addr;
    logic [63:0] wr64_data;
    logic        wr64_en, wr64_ready;

    blit_blend blend_i (
        .clk        (clk), .reset(reset),
        .start      (start),
        .dst_addr   (dst_addr), .dst_pitch(dst_pitch),
        .src_addr   (src_addr), .src_pitch(src_pitch),
        .width      (width), .height(height),
        .mod        (mod), .blend(blend),
        .solid      (solid), .solid_color(solid_color),
        .mirror_x   (mirror_x), .mirror_y(mirror_y),
        .mode_en    (mode_en), .mode(mode),
        .key_enable (key_enable), .key_value(key_value),
        .busy       (busy), .done(done),
        .rd64_addr  (rd64_addr), .rd64_en(rd64_en),
        .rd64_len   (rd64_len),
        .rd64_ready (rd64_ready), .rd64_data(rd64_data), .rd64_valid(rd64_valid),
        .wr_addr    (wr_addr), .wr_data(wr_data),
        .wr_en      (wr_en), .wr_ready(wr_ready),
        .wr64_addr  (wr64_addr), .wr64_data(wr64_data),
        .wr64_en    (wr64_en), .wr64_ready(wr64_ready)
    );

    ddram_adapter adapter_i (
        .clk             (clk),
        .reset           (reset),
        .wr_addr         (wr_addr),
        .wr_data         (wr_data),
        .wr_en           (wr_en),
        .wr_ready        (wr_ready),
        .wr64_addr       (wr64_addr),
        .wr64_data       (wr64_data),
        .wr64_en         (wr64_en),
        .wr64_ready      (wr64_ready),
        .rd_addr         (32'd0),
        .rd_en           (1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .rd_ready        (),
        .rd_data         (),
        .rd_valid        (),
        /* verilator lint_on PINCONNECTEMPTY */
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
