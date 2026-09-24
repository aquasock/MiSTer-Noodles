// Simulation-only FILL_BATCH descriptor sequencer, existing fill engine and
// real DDRAM adapter. The testbench supplies one behavioral DDR3 model for
// both descriptor reads and pixel writes.
module engine_fill_batch_dut (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [31:0] descriptor_base,
    input  logic [15:0] count,
    output logic        busy,
    output logic        done,

    output logic        DDRAM_CLK,
    input  logic        DDRAM_BUSY,
    output logic [7:0]  DDRAM_BURSTCNT,
    output logic [28:0] DDRAM_ADDR,
    input  logic [63:0] DDRAM_DOUT,
    input  logic        DDRAM_DOUT_READY,
    output logic [63:0] DDRAM_DIN,
    output logic [7:0]  DDRAM_BE,
    output logic        DDRAM_WE,
    output logic        DDRAM_RD
);
    logic [31:0] rd_addr, rd_data;
    logic rd_en, rd_active, rd_ready, rd_valid;
    logic fill_start, fill_busy, fill_done;
    logic [31:0] fill_dst_addr, fill_color;
    logic [15:0] fill_dst_pitch, fill_width, fill_height;
    logic [31:0] wr_addr, wr_data, wr64_addr;
    logic [63:0] wr64_data;
    logic wr_en, wr_ready, wr64_en, wr64_ready, wr_space;
    logic adapter_idle;

    fill_batch batch_i (
        .clk(clk), .reset(reset), .start(start), .descriptor_base(descriptor_base),
        .count(count), .busy(busy), .done(done),
        .rd_addr(rd_addr), .rd_en(rd_en), .rd_active(rd_active),
        .rd_ready(rd_ready), .rd_data(rd_data), .rd_valid(rd_valid),
        .fill_start(fill_start), .fill_dst_addr(fill_dst_addr),
        .fill_dst_pitch(fill_dst_pitch), .fill_width(fill_width),
        .fill_height(fill_height), .fill_color(fill_color), .fill_done(fill_done)
    );

    blit fill_i (
        .clk(clk), .reset(reset), .start(fill_start), .dst_addr(fill_dst_addr),
        .dst_pitch(fill_dst_pitch), .width(fill_width), .height(fill_height),
        .color(fill_color), .busy(fill_busy), .done(fill_done),
        .wr_addr(wr_addr), .wr_data(wr_data), .wr_en(wr_en), .wr_ready(wr_ready),
        .wr64_addr(wr64_addr), .wr64_data(wr64_data), .wr64_en(wr64_en),
        .wr64_ready(wr64_ready)
    );

    ddram_adapter adapter_i (
        .clk(clk), .reset(reset),
        .wr_addr(wr_addr), .wr_data(wr_data), .wr_en(wr_en), .wr_ready(),
        .wr64_addr(wr64_addr), .wr64_data(wr64_data), .wr64_en(wr64_en), .wr64_ready(),
        .wr_space(wr_space),
        .rd_addr(rd_addr), .rd_en(rd_en), .rd_ready(rd_ready),
        .rd_data(rd_data), .rd_valid(rd_valid),
        .rd64_addr(32'd0), .rd64_en(1'b0), .rd64_len(8'd1),
        .rd64_ready(), .rd64_data(), .rd64_valid(),
        .ddram_clk(DDRAM_CLK), .ddram_busy(DDRAM_BUSY),
        .ddram_burstcnt(DDRAM_BURSTCNT), .ddram_addr(DDRAM_ADDR),
        .ddram_dout(DDRAM_DOUT), .ddram_dout_ready(DDRAM_DOUT_READY),
        .ddram_din(DDRAM_DIN), .ddram_be(DDRAM_BE),
        .ddram_we(DDRAM_WE), .ddram_rd(DDRAM_RD), .idle(adapter_idle)
    );

    assign wr_ready = wr_space && !wr64_en;
    assign wr64_ready = wr_space;

    /* Keep these used in lint builds: the sequencer spans every pending
       descriptor read, and the adapter must drain after batch completion. */
    logic unused;
    always_comb unused = rd_active ^ fill_busy ^ adapter_idle;
endmodule
