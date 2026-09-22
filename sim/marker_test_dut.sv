// Simulation-only exposure of ddram_marker_test's generic write port, for
// tb_marker_test.cpp.

module marker_test_dut (
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

    ddram_marker_test marker_i (
        .clk     (clk),
        .reset   (reset),
        .trigger (trigger),
        .busy    (busy),
        .done    (done),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .wr_en   (wr_en),
        .wr_ready(wr_ready)
    );

endmodule
