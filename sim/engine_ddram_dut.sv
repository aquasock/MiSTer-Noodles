// Simulation-only wiring of CMDQ + BLIT + the DDRAM adapter's write side
// (DDR-001), exposing the real DDRAM_* signal names so the testbench can
// drive a behavioral Avalon-MM memory model against exactly what Noodles.sv
// connects to the framework's DDRAM_* pins. Read side unused here -- see
// sim/cmd_copy_trigger_dut.sv for the read path (DDR-003).

module engine_ddram_dut (
    input  logic         clk,
    input  logic         reset,

    input  logic         cmd_valid,
    input  logic [255:0] cmd_data,
    output logic         cmd_ready,

    output logic         DDRAM_CLK,
    input  logic         DDRAM_BUSY,
    output logic [7:0]   DDRAM_BURSTCNT,
    output logic [28:0]  DDRAM_ADDR,
    output logic [63:0]  DDRAM_DIN,
    output logic [7:0]   DDRAM_BE,
    output logic         DDRAM_WE,
    output logic         DDRAM_RD
);

    logic        blit_start, blit_busy, blit_done;
    logic [31:0] blit_dst_addr, blit_color;
    logic [15:0] blit_dst_pitch, blit_width, blit_height;

    logic [31:0] wr_addr, wr_data;
    logic        wr_en, wr_ready;

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
        .copy_done      (1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .present_start  (),
        /* verilator lint_on PINCONNECTEMPTY */
        .present_busy   (1'b0),
        .present_done   (1'b0)
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

    ddram_adapter adapter_i (
        .clk             (clk),
        .wr_addr         (wr_addr),
        .wr_data         (wr_data),
        .wr_en           (wr_en),
        .wr_ready        (wr_ready),
        .rd_addr         (32'd0),
        .rd_en           (1'b0),
        /* verilator lint_off PINCONNECTEMPTY */
        .rd_ready        (),
        .rd_data         (),
        .rd_valid        (),
        /* verilator lint_on PINCONNECTEMPTY */
        .ddram_clk       (DDRAM_CLK),
        .ddram_busy      (DDRAM_BUSY),
        .ddram_burstcnt  (DDRAM_BURSTCNT),
        .ddram_addr      (DDRAM_ADDR),
        .ddram_dout      (64'd0),
        .ddram_dout_ready(1'b0),
        .ddram_din       (DDRAM_DIN),
        .ddram_be        (DDRAM_BE),
        .ddram_we        (DDRAM_WE),
        .ddram_rd        (DDRAM_RD)
    );

endmodule
