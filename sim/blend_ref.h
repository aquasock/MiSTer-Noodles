/* BLIT-007 reference model: straight-alpha source-over with 8-bit alpha
 * modulation, using SDL 2.32.10's generic SDL_COPY_BLEND arithmetic
 * (truncating division by 255 at every stage). Pixels are R, G, B, A at
 * increasing byte addresses, i.e. R in bits 7:0 and A in bits 31:24.
 * Shared by the RTL testbenches and the hardware readback tool. */
#ifndef NOODLES_BLEND_REF_H
#define NOODLES_BLEND_REF_H

#include <stdint.h>

static inline uint32_t noodles_blend_div255(uint32_t x) {
    return x / 255u;
}

static inline uint32_t noodles_blend_ref(uint32_t src, uint32_t dst, uint32_t mod) {
    const uint32_t a = noodles_blend_div255((src >> 24) * (mod & 0xffu));
    const uint32_t inv = 255u - a;
    uint32_t out = (a + noodles_blend_div255(inv * (dst >> 24))) << 24;
    for (unsigned shift = 0; shift < 24; shift += 8) {
        const uint32_t s = (src >> shift) & 0xffu;
        const uint32_t d = (dst >> shift) & 0xffu;
        out |= (noodles_blend_div255(s * a) + noodles_blend_div255(inv * d)) << shift;
    }
    return out;
}

#endif
