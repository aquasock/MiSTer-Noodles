// BLIT-007/008/009 single-pixel datapath, fixed 7-cycle latency, no stalls.
//
// RGBA modulation, then a blend mode: per channel a source factor Fs and a
// destination factor Fd, an operation and optional single rounding (see
// sim/blend_ref.h and core-reference BLIT-009):
//   c = D(srcC * modC) (R, G, B), a = D(srcA * modA)
//   per channel, S = c (or a for alpha), V = destination value:
//   Ps = S * Fs, Pd = V * Fd
//   ADD:          min(255, D(Ps) + D(Pd))     single rounding: D(Ps + Pd)
//   SUBTRACT:     max(0, D(Ps) - D(Pd))       REV_SUBTRACT: max(0, D(Pd) - D(Ps))
//   MINIMUM/MAXIMUM: min/max(S, V)
// where D(x) = floor(x / 255). For x <= 65025 that is (x + 1 + (x >> 8)) >> 8.
// For single rounding, with remainders r = Ps - 255 D(Ps) (the low byte of
// Ps + D(Ps)), D(Ps + Pd) = D(Ps) + D(Pd) + (rs + rd >= 255): no divider.
// `mode` is descriptor flags bits 31:8: [0] single rounding, [5:2] colour
// source factor, [9:6] colour destination factor, [12:10] colour operation,
// [16:13] alpha source factor, [20:17] alpha destination factor, [23:21]
// alpha operation, in SDL_BlendFactor/SDL_BlendOperation numbering.
// Every stage is registered so the multiplies map onto DSP input/output
// registers at clk_sys. Callers carry their own sideband alongside
// in_valid/out_valid with the same 7-cycle latency.

module blend_px (
    input  logic        clk,
    input  logic        reset,
    input  logic        in_valid,
    input  logic [31:0] src,
    input  logic [31:0] dst,
    input  logic [31:0] mod,
    input  logic [23:0] mode,
    output logic        out_valid,
    output logic [31:0] out
);

    localparam logic [2:0] OP_ADD = 3'd1, OP_SUB = 3'd2, OP_REV_SUB = 3'd3, OP_MIN = 3'd4;

    // x <= 65025, so the sum never reaches bit 16.
    function automatic logic [7:0] div255(input logic [15:0] x);
        /* verilator lint_off UNUSEDSIGNAL */
        logic [16:0] sum;
        /* verilator lint_on UNUSEDSIGNAL */
        sum = {1'b0, x} + 17'd1 + {9'd0, x[15:8]};
        return sum[15:8];
    endfunction

    // SDL_BlendFactor value for one channel.
    function automatic logic [7:0] factor(input logic [3:0] code, input logic [7:0] s,
                                          input logic [7:0] a, input logic [7:0] v,
                                          input logic [7:0] va);
        unique case (code)
            4'd2: return 8'd255;
            4'd3: return s;
            4'd4: return ~s;
            4'd5: return a;
            4'd6: return ~a;
            4'd7: return v;
            4'd8: return ~v;
            4'd9: return va;
            4'd10: return ~va;
            default: return 8'd0;   // ZERO and undefined codes
        endcase
    endfunction

    logic [6:0]  valid;

    // Stage 1: input capture.
    logic [31:0] s1_src, s1_dst, s1_mod;
    logic [23:0] s1_mode;
    // Stage 2: modulation products.
    logic [15:0] s2_cmul [0:3];   // [3] is alpha
    logic [31:0] s2_dst;
    logic [23:0] s2_mode;
    // Stage 3: modulated source.
    logic [7:0]  s3_c [0:3];
    logic [31:0] s3_dst;
    logic [23:0] s3_mode;
    // Stage 4: per-channel operands and factors.
    logic [7:0]  s4_s [0:3], s4_v [0:3], s4_fs [0:3], s4_fd [0:3];
    logic [2:0]  s4_op [0:3];
    logic        s4_single;
    // Stage 5: products.
    logic [15:0] s5_ps [0:3], s5_pd [0:3];
    logic [7:0]  s5_s [0:3], s5_v [0:3];
    logic [2:0]  s5_op [0:3];
    logic        s5_single;
    // Stage 6: quotients and remainders.
    logic [7:0]  s6_qs [0:3], s6_qd [0:3], s6_rs [0:3], s6_rd [0:3];
    logic [7:0]  s6_s [0:3], s6_v [0:3];
    logic [2:0]  s6_op [0:3];
    logic        s6_single;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) valid <= '0;
        else valid <= {valid[5:0], in_valid};
    end

    always_ff @(posedge clk) begin
        s1_src <= src;
        s1_dst <= dst;
        s1_mod <= mod;
        s1_mode <= mode;

        for (int c = 0; c < 4; c++)
            s2_cmul[c] <= s1_src[8*c +: 8] * s1_mod[8*c +: 8];
        s2_dst <= s1_dst;
        s2_mode <= s1_mode;

        for (int c = 0; c < 4; c++)
            s3_c[c] <= div255(s2_cmul[c]);
        s3_dst <= s2_dst;
        s3_mode <= s2_mode;

        for (int c = 0; c < 4; c++) begin
            // Alpha uses the alpha factors and operation, colour the colour ones.
            automatic logic [3:0] sf = (c == 3) ? s3_mode[16:13] : s3_mode[5:2];
            automatic logic [3:0] df = (c == 3) ? s3_mode[20:17] : s3_mode[9:6];
            s4_s[c] <= s3_c[c];
            s4_v[c] <= s3_dst[8*c +: 8];
            s4_fs[c] <= factor(sf, s3_c[c], s3_c[3], s3_dst[8*c +: 8], s3_dst[31:24]);
            s4_fd[c] <= factor(df, s3_c[c], s3_c[3], s3_dst[8*c +: 8], s3_dst[31:24]);
            s4_op[c] <= (c == 3) ? s3_mode[23:21] : s3_mode[12:10];
        end
        s4_single <= s3_mode[0];

        for (int c = 0; c < 4; c++) begin
            s5_ps[c] <= s4_s[c] * s4_fs[c];
            s5_pd[c] <= s4_v[c] * s4_fd[c];
        end
        s5_s <= s4_s;
        s5_v <= s4_v;
        s5_op <= s4_op;
        s5_single <= s4_single;

        for (int c = 0; c < 4; c++) begin
            automatic logic [7:0] qs = div255(s5_ps[c]);
            automatic logic [7:0] qd = div255(s5_pd[c]);
            s6_qs[c] <= qs;
            s6_qd[c] <= qd;
            s6_rs[c] <= s5_ps[c][7:0] + qs;
            s6_rd[c] <= s5_pd[c][7:0] + qd;
        end
        s6_s <= s5_s;
        s6_v <= s5_v;
        s6_op <= s5_op;
        s6_single <= s5_single;

        for (int c = 0; c < 4; c++) begin
            automatic logic [8:0] rsum = {1'b0, s6_rs[c]} + {1'b0, s6_rd[c]};
            automatic logic [9:0] sum = {2'b00, s6_qs[c]} + {2'b00, s6_qd[c]} +
                                        {9'd0, s6_single && rsum >= 9'd255};
            automatic logic [8:0] diff = {1'b0, s6_qs[c]} - {1'b0, s6_qd[c]};
            automatic logic [8:0] rdiff = {1'b0, s6_qd[c]} - {1'b0, s6_qs[c]};
            unique case (s6_op[c])
                OP_ADD:     out[8*c +: 8] <= (sum > 10'd255) ? 8'd255 : sum[7:0];
                OP_SUB:     out[8*c +: 8] <= diff[8] ? 8'd0 : diff[7:0];
                OP_REV_SUB: out[8*c +: 8] <= rdiff[8] ? 8'd0 : rdiff[7:0];
                OP_MIN:     out[8*c +: 8] <= (s6_s[c] < s6_v[c]) ? s6_s[c] : s6_v[c];
                default:    out[8*c +: 8] <= (s6_s[c] > s6_v[c]) ? s6_s[c] : s6_v[c];
            endcase
        end
    end

    assign out_valid = valid[6];

endmodule
