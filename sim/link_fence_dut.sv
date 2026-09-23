// Simulation-only exposure of link_fence's generic write port, for
// tb_link_fence.cpp.

module link_fence_dut (
    input  logic clk,
    input  logic reset,

    input  logic done_pulse,
    input  logic front_sel,

    output logic [31:0] wr_addr,
    output logic [31:0] wr_data,
    output logic         wr_en,
    input  logic         wr_ready
);

    link_fence fence_i (
        .clk       (clk),
        .reset     (reset),
        .done_pulse(done_pulse),
        .front_sel (front_sel),
        .wr_addr   (wr_addr),
        .wr_data   (wr_data),
        .wr_en     (wr_en),
        .wr_ready  (wr_ready)
    );

endmodule
