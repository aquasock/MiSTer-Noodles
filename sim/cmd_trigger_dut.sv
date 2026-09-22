// Simulation-only wiring of cmd_test_trigger + CMDQ + BLIT: the full
// trigger-to-pixel path Noodles.sv now uses for its "Draw Test" OSD button,
// exercised end to end before trusting it on hardware again.

// Default COMMAND matches Noodles.sv's real "Draw Test" command exactly
// (CMDQ-002): opcode=1 (SOLID_FILL), dst_addr=0x30000000 (SURF-004),
// dst_pitch=256, width=64, height=64, color=0x00FF00FF.
module cmd_trigger_dut #(
    parameter logic [255:0] COMMAND = {
        32'd0, 32'd0, 32'h00FF00FF, 32'd64, 32'd64, 32'd256, 32'h30000000, 32'd1
    }
) (
    input  logic clk,
    input  logic reset,

    input  logic trigger,
    output logic busy,
    output logic done,

    output logic [31:0] wr_addr,
    output logic [31:0] wr_data,
    output logic        wr_en,
    input  logic        wr_ready
);

    logic         cmd_valid, cmd_ready;
    logic [255:0] cmd_data;

    logic        blit_start, blit_busy, blit_done;
    logic [31:0] blit_dst_addr, blit_color;
    logic [15:0] blit_dst_pitch, blit_width, blit_height;

    cmd_test_trigger #(.COMMAND(COMMAND)) trigger_i (
        .clk      (clk),
        .reset    (reset),
        .trigger  (trigger),
        .busy     (busy),
        .done     (done),
        .cmd_data (cmd_data),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready)
    );

    cmdq cmdq_i (
        .clk            (clk),
        .reset          (reset),
        .cmd_valid      (cmd_valid),
        .cmd_data       (cmd_data),
        .cmd_ready      (cmd_ready),
        .blit_start     (blit_start),
        .blit_dst_addr  (blit_dst_addr),
        .blit_dst_pitch (blit_dst_pitch),
        .blit_width     (blit_width),
        .blit_height    (blit_height),
        .blit_color     (blit_color),
        .blit_busy      (blit_busy),
        .blit_done      (blit_done),
        /* verilator lint_off PINCONNECTEMPTY */
        .copy_start     (),
        .copy_dst_addr  (),
        .copy_dst_pitch (),
        .copy_src_addr  (),
        .copy_src_pitch (),
        .copy_width     (),
        .copy_height    (),
        /* verilator lint_on PINCONNECTEMPTY */
        .copy_busy      (1'b0),
        .copy_done      (1'b0)
    );

    blit blit_i (
        .clk      (clk),
        .reset    (reset),
        .start    (blit_start),
        .dst_addr (blit_dst_addr),
        .dst_pitch(blit_dst_pitch),
        .width    (blit_width),
        .height   (blit_height),
        .color    (blit_color),
        .busy     (blit_busy),
        .done     (blit_done),
        .wr_addr  (wr_addr),
        .wr_data  (wr_data),
        .wr_en    (wr_en),
        .wr_ready (wr_ready)
    );

endmodule
