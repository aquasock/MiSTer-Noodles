// BLIT-007/BLIT-008 single-pixel datapath, fixed 5-cycle latency, no stalls.
//
// RGBA modulation then either a plain store or straight-alpha source-over,
// bit-exact to SDL 2.32.10's generic path (see sim/blend_ref.h):
//   c    = D(srcC * modC)                          for R, G, B
//   a    = D(srcA * modA)
//   blend:    outC = D(c * a) + D((255 - a) * dstC),  outA = a + D((255 - a) * dstA)
//   no blend: outC = c,                               outA = a
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
    input  logic [31:0] mod,
    input  logic        blend,
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
    logic [31:0] s1_src, s1_dst, s1_mod;
    logic        s1_blend;
    // Stage 2: modulation products.
    logic [15:0] s2_cmul [0:3];   // [3] is alpha
    logic [31:0] s2_dst;
    logic        s2_blend;
    // Stage 3: modulated colour and effective alpha.
    logic [7:0]  s3_c [0:3];
    logic [7:0]  s3_inv;
    logic [31:0] s3_dst;
    logic        s3_blend;
    // Stage 4: blend products.
    logic [15:0] s4_sc [0:2];
    logic [15:0] s4_id [0:3];
    logic [7:0]  s4_c [0:3];
    logic        s4_blend;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) valid <= '0;
        else valid <= {valid[3:0], in_valid};
    end

    always_ff @(posedge clk) begin
        s1_src <= src;
        s1_dst <= dst;
        s1_mod <= mod;
        s1_blend <= blend;

        for (int c = 0; c < 4; c++)
            s2_cmul[c] <= s1_src[8*c +: 8] * s1_mod[8*c +: 8];
        s2_dst <= s1_dst;
        s2_blend <= s1_blend;

        for (int c = 0; c < 4; c++)
            s3_c[c] <= div255(s2_cmul[c]);
        s3_inv <= 8'd255 - div255(s2_cmul[3]);
        s3_dst <= s2_dst;
        s3_blend <= s2_blend;

        for (int c = 0; c < 3; c++)
            s4_sc[c] <= s3_c[c] * s3_c[3];
        for (int c = 0; c < 4; c++)
            s4_id[c] <= s3_dst[8*c +: 8] * s3_inv;
        s4_c <= s3_c;
        s4_blend <= s3_blend;

        for (int c = 0; c < 3; c++)
            out[8*c +: 8] <= s4_blend ? div255(s4_sc[c]) + div255(s4_id[c]) : s4_c[c];
        out[31:24] <= s4_blend ? s4_c[3] + div255(s4_id[3]) : s4_c[3];
    end

    assign out_valid = valid[4];

endmodule
