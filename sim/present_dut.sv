// Simulation-only exposure of present's ports, for tb_present.cpp.

module present_dut #(
    parameter integer RETIRE_VBLANKS = 1
) (
    input  logic clk,
    input  logic reset,

    input  logic fb_vbl,
    input  logic fb_base_latched,

    input  logic start,
    output logic busy,
    output logic done,

    output logic front_sel
);

    present #(.RETIRE_VBLANKS(RETIRE_VBLANKS)) present_i (
        .clk      (clk),
        .reset    (reset),
        .fb_vbl   (fb_vbl),
        .fb_base_latched(fb_base_latched),
        .start    (start),
        .busy     (busy),
        .done     (done),
        .front_sel(front_sel)
    );

endmodule
