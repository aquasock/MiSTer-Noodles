// BLIT-007 single-pixel blend datapath, fixed 5-cycle latency, no stalls.
//
// Straight-alpha source-over with 8-bit alpha modulation, bit-exact to
// SDL 2.32.10's generic SDL_COPY_BLEND path (see sim/blend_ref.h):
//   a    = D(srcA * mod)
//   outC = D(srcC * a) + D((255 - a) * dstC)     for R, G, B
//   outA = a + D((255 - a) * dstA)
// where D(x) = floor(x / 255). For every product of two bytes (x <= 65025)
// that equals (x + 1 + (x >> 8)) >> 8, which needs only an adder.
// Every stage is registered so the multiplies map onto DSP input/output
// registers at clk_sys. Callers carry their own sideband alongside
// in_valid/out_valid with the same 5-cycle latency.

module blend_px (
    input  logic        clk,
    input  logic        reset,
    input  logic        in_valid,
    input  logic [31:0] src,
    input  logic [31:0] dst,
    input  logic [7:0]  mod,
    output logic        out_valid,
    output logic [31:0] out
);

    // x <= 65025, so the sum never reaches bit 16.
    function automatic logic [7:0] div255(input logic [15:0] x);
        /* verilator lint_off UNUSEDSIGNAL */
        logic [16:0] sum;
        /* verilator lint_on UNUSEDSIGNAL */
        sum = {1'b0, x} + 17'd1 + {9'd0, x[15:8]};
        return sum[15:8];
    endfunction

    logic [4:0]  valid;

    // Stage 1: input capture.
    logic [31:0] s1_src, s1_dst;
    logic [7:0]  s1_mod;
    // Stage 2: modulation product.
    logic [15:0] s2_amul;
    logic [31:0] s2_src, s2_dst;
    // Stage 3: effective alpha.
    logic [7:0]  s3_a, s3_inv;
    logic [31:0] s3_src, s3_dst;
    // Stage 4: channel products.
    logic [15:0] s4_sc [0:2];
    logic [15:0] s4_id [0:3];
    logic [7:0]  s4_a;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) valid <= '0;
        else valid <= {valid[3:0], in_valid};
    end

    always_ff @(posedge clk) begin
        s1_src <= src;
        s1_dst <= dst;
        s1_mod <= mod;

        s2_amul <= s1_src[31:24] * s1_mod;
        s2_src <= s1_src;
        s2_dst <= s1_dst;

        s3_a <= div255(s2_amul);
        s3_inv <= 8'd255 - div255(s2_amul);
        s3_src <= s2_src;
        s3_dst <= s2_dst;

        for (int c = 0; c < 3; c++)
            s4_sc[c] <= s3_src[8*c +: 8] * s3_a;
        for (int c = 0; c < 4; c++)
            s4_id[c] <= s3_dst[8*c +: 8] * s3_inv;
        s4_a <= s3_a;

        for (int c = 0; c < 3; c++)
            out[8*c +: 8] <= div255(s4_sc[c]) + div255(s4_id[c]);
        out[31:24] <= s4_a + div255(s4_id[3]);
    end

    assign out_valid = valid[4];

endmodule
