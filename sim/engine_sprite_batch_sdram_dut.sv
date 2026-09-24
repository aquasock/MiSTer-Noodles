// Optional SDRAM sprite-source integration coverage on one clock.
// Production Noodles.sv still routes sprite reads to DDR3; this harness
// keeps the SDRAM burst path exercised with a refresh-aware controller mock.
module engine_sprite_batch_sdram_dut (
    input  logic          clk,
    input  logic          reset,

    input  logic          start,
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
    output logic         DDRAM_RD,

    // Drives sdram_adapter_dut's mock sdram model's busy window, so the
    // testbench can reproduce sdram.sv's periodic auto-refresh cadence
    // (or a copy-port-sized busy window right before the run starts, like
    // the real sdram_loader's flush immediately preceding sprite_batch's
    // first read) exactly like on real hardware.
    input  logic          mock_busy,
    input  logic [7:0]    mock_delay
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
    logic        adapter_idle;

    sprite_batch sprite_batch_i (
        .clk(clk), .reset(reset), .start(start), .count(count),
        .busy(busy), .done(done),
        .rd_addr(batch_rd_addr), .rd_en(batch_rd_en), .rd_active(batch_rd_active),
        .rd_ready(batch_rd_ready), .rd_data(batch_rd_data), .rd_valid(batch_rd_valid),
        .rd64_addr(batch_rd64_addr), .rd64_en(batch_rd64_en),
        .rd64_len(batch_rd64_len),
        .rd64_ready(batch_rd64_ready), .rd64_data(batch_rd64_data), .rd64_valid(batch_rd64_valid),
        .wr_addr(batch_wr_addr), .wr_data(batch_wr_data), .wr_en(batch_wr_en),
        .wr_ready(batch_wr_ready),
        .wr64_addr(batch_wr64_addr), .wr64_data(batch_wr64_data),
        .wr64_en(batch_wr64_en), .wr64_ready(batch_wr64_ready)
    );

    // Descriptor fetch + destination write: unchanged from Noodles.sv,
    // still DDR3/ddram_adapter.
    ddram_adapter adapter_i (
        .clk             (clk),
        .reset           (reset),
        .wr_addr         (batch_wr_addr),
        .wr_data         (batch_wr_data),
        .wr_en           (batch_wr_en),
        .wr_ready        (batch_wr_ready),
        .wr64_addr       (batch_wr64_addr),
        .wr64_data       (batch_wr64_data),
        .wr64_en         (batch_wr64_en),
        .wr64_ready      (batch_wr64_ready),
        .rd_addr         (batch_rd_addr),
        .rd_en           (batch_rd_en),
        .rd_ready        (batch_rd_ready),
        .rd_data         (batch_rd_data),
        .rd_valid        (batch_rd_valid),
        .rd64_addr       (32'b0),
        .rd64_en         (1'b0),
        .rd64_len        (8'd1),
        .rd64_ready      (),
        .rd64_data       (),
        .rd64_valid      (),
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

    // Pixel-data reads: real sdram_adapter
    // backed by sdram_adapter_dut's mock sdram.sv model.
    logic [25:0] sd_addr_probe;
    logic        sd_accept_probe;

    sdram_adapter_dut sdram_i (
        .clk       (clk),
        .reset     (reset),
        .rd64_addr (batch_rd64_addr),
        .rd64_en   (batch_rd64_en),
        .rd64_len  (batch_rd64_len),
        .rd64_ready(batch_rd64_ready),
        .rd64_data (batch_rd64_data),
        .rd64_valid(batch_rd64_valid),

        .mock_delay(mock_delay),
        .mock_busy (mock_busy),

        .sd_addr_probe  (sd_addr_probe),
        .sd_accept_probe(sd_accept_probe)
    );

endmodule
