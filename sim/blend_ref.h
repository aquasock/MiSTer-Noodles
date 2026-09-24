/* BLIT-007/008/009 reference model. A drawn pixel is the source modulated
 * by an RGBA word (SDL 2.32.10's generic colour and alpha modulation), then
 * combined with the destination by a blend mode: per channel a source and a
 * destination factor, an operation and optional single rounding (BLIT-009).
 * Every division is truncating division by 255. Pixels and the modulation
 * word are R, G, B, A at increasing byte addresses, i.e. R in bits 7:0 and
 * A in bits 31:24. Shared by the RTL testbenches and the hardware readback
 * tool. */
#ifndef NOODLES_BLEND_REF_H
#define NOODLES_BLEND_REF_H

#include <stdint.h>

/* SDL_BlendFactor and SDL_BlendOperation numbering. */
enum {
    NOODLES_REF_ZERO = 1, NOODLES_REF_ONE, NOODLES_REF_SRC_COLOR, NOODLES_REF_ONE_MINUS_SRC_COLOR,
    NOODLES_REF_SRC_ALPHA, NOODLES_REF_ONE_MINUS_SRC_ALPHA, NOODLES_REF_DST_COLOR,
    NOODLES_REF_ONE_MINUS_DST_COLOR, NOODLES_REF_DST_ALPHA, NOODLES_REF_ONE_MINUS_DST_ALPHA
};
enum { NOODLES_REF_ADD = 1, NOODLES_REF_SUBTRACT, NOODLES_REF_REV_SUBTRACT,
       NOODLES_REF_MINIMUM, NOODLES_REF_MAXIMUM };

/* Descriptor flag bits 31:4 for an explicit mode (BLIT-009). */
static inline uint32_t noodles_ref_mode(uint32_t csf, uint32_t cdf, uint32_t cop, uint32_t asf,
                                        uint32_t adf, uint32_t aop, int single_rounding) {
    return 0x10u | (single_rounding ? 0x100u : 0u) | csf << 10 | cdf << 14 | cop << 18 |
           asf << 21 | adf << 25 | aop << 29;
}

/* SDL's software modes as explicit modes. */
#define NOODLES_REF_MODE_BLEND                                                            \
    noodles_ref_mode(NOODLES_REF_SRC_ALPHA, NOODLES_REF_ONE_MINUS_SRC_ALPHA, NOODLES_REF_ADD, \
                     NOODLES_REF_ONE, NOODLES_REF_ONE_MINUS_SRC_ALPHA, NOODLES_REF_ADD, 0)
#define NOODLES_REF_MODE_NONE                                                             \
    noodles_ref_mode(NOODLES_REF_ONE, NOODLES_REF_ZERO, NOODLES_REF_ADD, NOODLES_REF_ONE,    \
                     NOODLES_REF_ZERO, NOODLES_REF_ADD, 0)

static inline uint32_t noodles_blend_div255(uint32_t x) {
    return x / 255u;
}

static inline uint32_t noodles_ref_factor(uint32_t factor, uint32_t s, uint32_t a, uint32_t v,
                                          uint32_t va) {
    switch (factor) {
    case NOODLES_REF_ZERO: return 0;
    case NOODLES_REF_ONE: return 255;
    case NOODLES_REF_SRC_COLOR: return s;
    case NOODLES_REF_ONE_MINUS_SRC_COLOR: return 255 - s;
    case NOODLES_REF_SRC_ALPHA: return a;
    case NOODLES_REF_ONE_MINUS_SRC_ALPHA: return 255 - a;
    case NOODLES_REF_DST_COLOR: return v;
    case NOODLES_REF_ONE_MINUS_DST_COLOR: return 255 - v;
    case NOODLES_REF_DST_ALPHA: return va;
    case NOODLES_REF_ONE_MINUS_DST_ALPHA: return 255 - va;
    default: return 0;          /* undefined codes behave as ZERO */
    }
}

/* One channel: s/v are source and destination values, a/va the pixel alphas. */
static inline uint32_t noodles_ref_channel(uint32_t s, uint32_t a, uint32_t v, uint32_t va,
                                           uint32_t sf, uint32_t df, uint32_t op, int single) {
    const uint32_t ps = s * noodles_ref_factor(sf, s, a, v, va);
    const uint32_t pd = v * noodles_ref_factor(df, s, a, v, va);
    const int32_t ts = (int32_t)noodles_blend_div255(ps), td = (int32_t)noodles_blend_div255(pd);
    int32_t out;
    switch (op) {
    case NOODLES_REF_ADD: out = single ? (int32_t)noodles_blend_div255(ps + pd) : ts + td; break;
    case NOODLES_REF_SUBTRACT: out = ts - td; break;
    case NOODLES_REF_REV_SUBTRACT: out = td - ts; break;
    case NOODLES_REF_MINIMUM: out = (int32_t)(s < v ? s : v); break;
    default: out = (int32_t)(s > v ? s : v); break;   /* MAXIMUM */
    }
    return out < 0 ? 0u : out > 255 ? 255u : (uint32_t)out;
}

/* One flagged draw pixel: flags are the descriptor flags word. Bit 4 selects
 * the explicit mode in bits 31:8; otherwise bit 1 selects BLEND and its
 * absence a plain store (BLIT-008). */
static inline uint32_t noodles_mode_ref(uint32_t src, uint32_t dst, uint32_t mod, uint32_t flags) {
    const uint32_t mode = (flags & 0x10u) ? flags
                        : (flags & 0x2u) ? NOODLES_REF_MODE_BLEND : NOODLES_REF_MODE_NONE;
    const uint32_t csf = mode >> 10 & 0xf, cdf = mode >> 14 & 0xf, cop = mode >> 18 & 0x7;
    const uint32_t asf = mode >> 21 & 0xf, adf = mode >> 25 & 0xf, aop = mode >> 29 & 0x7;
    const int single = (mode & 0x100u) != 0;
    const uint32_t a = noodles_blend_div255((src >> 24) * (mod >> 24));
    const uint32_t va = dst >> 24;
    uint32_t out = noodles_ref_channel(a, a, va, va, asf, adf, aop, single) << 24;
    for (unsigned shift = 0; shift < 24; shift += 8) {
        const uint32_t c = noodles_blend_div255(((src >> shift) & 0xffu) * ((mod >> shift) & 0xffu));
        const uint32_t v = (dst >> shift) & 0xffu;
        out |= noodles_ref_channel(c, a, v, va, csf, cdf, cop, single) << shift;
    }
    return out;
}

/* BLIT-008 draw pixel: modulation, then store or blend. */
static inline uint32_t noodles_draw_ref(uint32_t src, uint32_t dst, uint32_t mod, int blend) {
    return noodles_mode_ref(src, dst, mod, blend ? 0x2u : 0u);
}

/* BLIT_BLEND (BLIT-007): alpha modulation only. */
static inline uint32_t noodles_blend_ref(uint32_t src, uint32_t dst, uint32_t mod) {
    return noodles_draw_ref(src, dst, 0x00ffffffu | ((mod & 0xffu) << 24), 1);
}

#endif
