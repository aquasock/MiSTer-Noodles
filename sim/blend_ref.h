/* BLIT-007/BLIT-008 reference model: RGBA modulation followed by either a
 * plain store or straight-alpha source-over, using SDL 2.32.10's generic
 * arithmetic (truncating division by 255 at every stage). Pixels and the
 * modulation word are R, G, B, A at increasing byte addresses, i.e. R in
 * bits 7:0 and A in bits 31:24. Shared by the RTL testbenches and the
 * hardware readback tool. */
#ifndef NOODLES_BLEND_REF_H
#define NOODLES_BLEND_REF_H

#include <stdint.h>

static inline uint32_t noodles_blend_div255(uint32_t x) {
    return x / 255u;
}

/* One flagged draw pixel (BLIT-008): modulation, then store or blend. */
static inline uint32_t noodles_draw_ref(uint32_t src, uint32_t dst, uint32_t mod, int blend) {
    const uint32_t a = noodles_blend_div255((src >> 24) * (mod >> 24));
    const uint32_t inv = 255u - a;
    uint32_t out = (blend ? a + noodles_blend_div255(inv * (dst >> 24)) : a) << 24;
    for (unsigned shift = 0; shift < 24; shift += 8) {
        const uint32_t c = noodles_blend_div255(((src >> shift) & 0xffu) * ((mod >> shift) & 0xffu));
        const uint32_t d = (dst >> shift) & 0xffu;
        out |= (blend ? noodles_blend_div255(c * a) + noodles_blend_div255(inv * d) : c) << shift;
    }
    return out;
}

/* BLIT_BLEND (BLIT-007): alpha modulation only. */
static inline uint32_t noodles_blend_ref(uint32_t src, uint32_t dst, uint32_t mod) {
    return noodles_draw_ref(src, dst, 0x00ffffffu | ((mod & 0xffu) << 24), 1);
}

#endif
