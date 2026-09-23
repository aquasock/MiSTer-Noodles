// Simulation-only wiring of sprite_batch (the descriptor sequencer CMDQ's
// SPRITE_BATCH opcode dispatches to) plus the real DDRAM adapter
// (DDR-003/DDR-007), mirroring Noodles.sv's own read-port mux between
// sprite_batch's single-word descriptor-fetch port and its rd64 pass-through
// to blit_copy64 -- this is the first simulation coverage of sprite_batch's
// own multi-descriptor DESC_REQ/DESC_WAIT/LAUNCH/COPY loop end to end;
// previously only CMDQ's opcode decode (stubbing batch_busy/batch_done
// directly) and blit_copy64 in isolation (driven straight from a
// testbench, bypassing descriptor fetch) had coverage.
module engine_sprite_batch_dut (
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

    // Mirrors Noodles.sv's rd_sel_batch/rd_sel_batch64 muxing, minus the
    // other engines/link_ring which don't exist in this isolated DUT.
    wire rd_sel_batch64 = batch_rd64_en;

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
        .rd64_addr       (batch_rd64_addr),
        .rd64_en         (rd_sel_batch64),
        .rd64_len        (batch_rd64_len),
        .rd64_ready      (batch_rd64_ready),
        .rd64_data       (batch_rd64_data),
        .rd64_valid      (batch_rd64_valid),
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
