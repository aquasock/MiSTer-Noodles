// Simulation-only exposure of present's ports, for tb_present.cpp.

module present_dut #(
    parameter integer RETIRE_VBLANKS = 1
) (
    input  logic clk,
    input  logic reset,

    input  logic fb_vbl,
    input  logic fb_retired,

    input  logic       start,
    input  logic       queued,
    input  logic [1:0] target,
    output logic busy,
    output logic done,
    output logic retired,

    output logic [1:0] front_idx
);

    present #(.RETIRE_VBLANKS(RETIRE_VBLANKS)) present_i (
        .clk      (clk),
        .reset    (reset),
        .fb_vbl   (fb_vbl),
        .fb_retired(fb_retired),
        .start    (start),
        .queued   (queued),
        .target   (target),
        .busy     (busy),
        .done     (done),
        .retired  (retired),
        .front_idx(front_idx)
    );

endmodule
