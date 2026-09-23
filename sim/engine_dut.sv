// Simulation-only wiring of CMDQ + BLIT for standalone testbenches. Not part
// of the core build (see files.qip) -- exercises the two modules together
// before either is wired into Noodles.sv's real HPS-link and SDRAM ports.

module engine_dut (
    input  logic         clk,
    input  logic         reset,

    input  logic         cmd_valid,
    input  logic [255:0] cmd_data,
    output logic         cmd_ready,

    output logic [31:0]  wr_addr,
    output logic [31:0]  wr_data,
    output logic         wr_en,
    input  logic         wr_ready,
    output logic [31:0]  wr64_addr,
    output logic [63:0]  wr64_data,
    output logic         wr64_en,
    input logic          wr64_ready
);

    logic        blit_start, blit_busy, blit_done;
    logic [31:0] blit_dst_addr, blit_color;
    logic [15:0] blit_dst_pitch, blit_width, blit_height;

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
        .memory_idle    (1'b1),
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
        .copy_done      (1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .present_start  (),
        /* verilator lint_on PINCONNECTEMPTY */
        .present_busy   (1'b0),
        .present_done   (1'b0),
        .loader_start(), .loader_src_addr(), .loader_dst_addr(), .loader_length(),
        .loader_busy(1'b0), .loader_done(1'b0)
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
        .wr_ready (wr_ready),
        .wr64_addr(wr64_addr),
        .wr64_data(wr64_data),
        .wr64_en(wr64_en),
        .wr64_ready(wr64_ready)
    );

endmodule
