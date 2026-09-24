// Simulation-only wiring of link_ring + the real DDRAM adapter, exposing
// DDRAM_* so the testbench can act as the "host": writing commands and
// write_ptr directly into a behavioral memory model, exactly as an ARM
// process would via /dev/mem. RING_SLOTS is small (4, not the real 64) so
// a wraparound is cheap to exercise.

module link_ring_dut (
    input  logic clk,
    input  logic reset,
    input  logic enable,
    output logic initialized,

    input  logic          cmd_ready,
    output logic [255:0] cmd_data,
    output logic          cmd_valid,

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

    logic [31:0] rd_addr, rd_data, wr_addr, wr_data;
    logic        rd_en, rd_active, rd_ready, rd_valid, wr_en, wr_ready;

    link_ring #(.RING_SLOTS(4)) link_ring_i (
        .clk      (clk),
        .reset    (reset),
        .enable   (enable),
        .initialized(initialized),
        .rd_addr  (rd_addr),
        .rd_en    (rd_en),
        .rd_active(rd_active),
        .rd_ready (rd_ready),
        .rd_data  (rd_data),
        .rd_valid (rd_valid),
        .wr_addr  (wr_addr),
        .wr_data  (wr_data),
        .wr_en    (wr_en),
        .wr_ready (wr_ready),
        .cmd_data (cmd_data),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready)
    );

    ddram_adapter adapter_i (
        .clk             (clk),
        .reset           (reset),
        .wr_addr         (wr_addr),
        .wr_data         (wr_data),
        .wr_en           (wr_en),
        .wr_ready        (wr_ready),
        .wr64_addr       (32'd0),
        .wr64_data       (64'd0),
        .wr64_en         (1'b0),
        .wr64_ready      (),
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
