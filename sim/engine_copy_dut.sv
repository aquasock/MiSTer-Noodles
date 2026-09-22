// Simulation-only wiring of CMDQ + blit_copy + the real DDRAM adapter (read
// and write sides): the full CMDQ-dispatch-to-pixel path for BLIT_COPY
// (BLIT-003, DDR-003), exposing the real DDRAM_* signal names so the
// testbench can drive one behavioral Avalon-MM memory model that must serve
// both the read and the write side correctly. cmd_valid/cmd_data are driven
// directly by the testbench (same pattern as sim/engine_ddram_dut.sv), not
// through an OSD-style trigger -- there is no trigger left in the real core
// to test now that LINK-001 proves the ring-buffer path end to end.

module engine_copy_dut (
    input  logic          clk,
    input  logic          reset,

    input  logic          cmd_valid,
    input  logic [255:0]  cmd_data,
    output logic          cmd_ready,

    output logic        DDRAM_CLK,
    input  logic        DDRAM_BUSY,
    output logic [7:0]  DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    input  logic [63:0] DDRAM_DOUT,
    input  logic         DDRAM_DOUT_READY,
    output logic [63:0] DDRAM_DIN,
    output logic [7:0]  DDRAM_BE,
    output logic        DDRAM_WE,
    output logic        DDRAM_RD
);

    logic        blit_start, blit_busy, blit_done;
    logic [31:0] blit_dst_addr, blit_color;
    logic [15:0] blit_dst_pitch, blit_width, blit_height;

    logic        copy_start, copy_busy, copy_done;
    logic [31:0] copy_dst_addr, copy_src_addr;
    logic [15:0] copy_dst_pitch, copy_src_pitch, copy_width, copy_height;

    logic [31:0] wr_addr, wr_data;
    logic        wr_en, wr_ready;
    logic [31:0] rd_addr, rd_data;
    logic        rd_en, rd_ready, rd_valid;

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
        .copy_start     (copy_start),
        .copy_dst_addr  (copy_dst_addr),
        .copy_dst_pitch (copy_dst_pitch),
        .copy_src_addr  (copy_src_addr),
        .copy_src_pitch (copy_src_pitch),
        .copy_width     (copy_width),
        .copy_height    (copy_height),
        .copy_busy      (copy_busy),
        .copy_done      (copy_done)
    );

    // FILL's write port is never driven in this DUT (blit_start never fires
    // unless cmd_data's opcode is 1) -- tie it off and give blit_copy's
    // write port sole use of the adapter.
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
        /* verilator lint_off PINCONNECTEMPTY */
        .wr_addr  (),
        .wr_data  (),
        .wr_en    (),
        /* verilator lint_on PINCONNECTEMPTY */
        .wr_ready (1'b0)
    );

    blit_copy copy_i (
        .clk      (clk),
        .reset    (reset),
        .start    (copy_start),
        .dst_addr (copy_dst_addr),
        .dst_pitch(copy_dst_pitch),
        .src_addr (copy_src_addr),
        .src_pitch(copy_src_pitch),
        .width    (copy_width),
        .height   (copy_height),
        .busy     (copy_busy),
        .done     (copy_done),
        .rd_addr  (rd_addr),
        .rd_en    (rd_en),
        .rd_ready (rd_ready),
        .rd_data  (rd_data),
        .rd_valid (rd_valid),
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
        .rd_addr         (rd_addr),
        .rd_en           (rd_en),
        .rd_ready        (rd_ready),
        .rd_data         (rd_data),
        .rd_valid        (rd_valid),
        .ddram_clk       (DDRAM_CLK),
        .ddram_busy      (DDRAM_BUSY),
        .ddram_burstcnt  (DDRAM_BURSTCNT),
        .ddram_addr      (DDRAM_ADDR),
        .ddram_dout      (DDRAM_DOUT),
        .ddram_dout_ready(DDRAM_DOUT_READY),
        .ddram_din       (DDRAM_DIN),
        .ddram_be        (DDRAM_BE),
        .ddram_we        (DDRAM_WE),
        .ddram_rd        (DDRAM_RD)
    );

endmodule
