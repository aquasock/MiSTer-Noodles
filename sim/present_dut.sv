// Simulation-only exposure of present's ports, for tb_present.cpp.

module present_dut (
    input  logic clk,
    input  logic reset,

    input  logic fb_vbl,

    input  logic start,
    output logic busy,
    output logic done,

    output logic front_sel
);

    present present_i (
        .clk      (clk),
        .reset    (reset),
        .fb_vbl   (fb_vbl),
        .start    (start),
        .busy     (busy),
        .done     (done),
        .front_sel(front_sel)
    );

endmodule
