#ifndef NOODLES_SURFACE_H
#define NOODLES_SURFACE_H

#include "noodles_link.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NOODLES_SURFACE_ARENA_ADDR 0x32000000u
#define NOODLES_SURFACE_ARENA_BYTES 0x0e000000u

typedef struct noodles_surface noodles_surface_t;
typedef struct noodles_texture_cache noodles_texture_cache_t;

typedef struct {
    int32_t x, y;
    uint32_t width, height;
} noodles_rect_t;

typedef struct {
    const noodles_surface_t *source;
    noodles_rect_t source_rect;
    int32_t dst_x, dst_y;
} noodles_surface_blit_t;

typedef struct {
    uint64_t key;
    noodles_rect_t source_rect;
    int32_t dst_x, dst_y;
} noodles_texture_blit_t;

/* One batched draw (BLIT-008). flags are NOODLES_DRAW_*; for KEY,
 * modulation is the colour key, otherwise it is the RGBA modulation
 * (0xffffffff = none). Mirroring is applied before clipping, so a mirrored
 * draw hanging off an edge shows the correct part of the source. */
typedef struct {
    const noodles_surface_t *source;
    noodles_rect_t source_rect;
    int32_t dst_x, dst_y;
    uint32_t flags;
    uint32_t modulation;
} noodles_surface_draw_t;

typedef struct {
    uint64_t key;
    noodles_rect_t source_rect;
    int32_t dst_x, dst_y;
    uint32_t flags;
    uint32_t modulation;
} noodles_texture_draw_t;

/* CPU access to the current 800x600 back buffer. Transfers require an
 * entirely in-bounds rectangle, wait for earlier commands with timeout_ms,
 * and refuse access while a PRESENT is pending. Fill clips to the buffer. */
int noodles_back_buffer_update(noodles_link_t *link, const noodles_rect_t *rect,
                               const void *pixels, size_t source_pitch,
                               uint32_t timeout_ms);
int noodles_back_buffer_read(noodles_link_t *link, const noodles_rect_t *rect,
                             void *pixels, size_t destination_pitch,
                             uint32_t timeout_ms);
int noodles_back_buffer_fill(noodles_link_t *link, const noodles_rect_t *rect,
                             uint32_t color);

int noodles_surface_create(noodles_link_t *link, uint32_t width, uint32_t height,
                           noodles_surface_t **out);
int noodles_surface_destroy(noodles_surface_t *surface);
uint32_t noodles_surface_width(const noodles_surface_t *surface);
uint32_t noodles_surface_height(const noodles_surface_t *surface);
uint32_t noodles_surface_pitch(const noodles_surface_t *surface);

int noodles_surface_update(noodles_surface_t *surface, const noodles_rect_t *rect,
                           const void *pixels, size_t source_pitch, uint32_t timeout_ms);
int noodles_surface_read(noodles_surface_t *surface, const noodles_rect_t *rect,
                         void *pixels, size_t destination_pitch, uint32_t timeout_ms);

int noodles_surface_fill(noodles_surface_t *destination, const noodles_rect_t *rect,
                         uint32_t color);
int noodles_surface_blit(noodles_surface_t *destination, int32_t dst_x, int32_t dst_y,
                         const noodles_surface_t *source, const noodles_rect_t *source_rect);
int noodles_surface_blit_to_back_buffer(noodles_link_t *link, int32_t dst_x, int32_t dst_y,
                                        const noodles_surface_t *source,
                                        const noodles_rect_t *source_rect);
/* BLIT_BLEND variants (BLIT-007): source alpha scaled by alpha_mod,
 * source-over onto the destination. ENOTSUP without NOODLES_CAP_BLIT_BLEND. */
int noodles_surface_blend(noodles_surface_t *destination, int32_t dst_x, int32_t dst_y,
                          const noodles_surface_t *source, const noodles_rect_t *source_rect,
                          uint8_t alpha_mod);
int noodles_surface_blend_to_back_buffer(noodles_link_t *link, int32_t dst_x, int32_t dst_y,
                                         const noodles_surface_t *source,
                                         const noodles_rect_t *source_rect, uint8_t alpha_mod);
int noodles_surface_batch_to_back_buffer(noodles_link_t *link,
                                         const noodles_surface_blit_t *blits,
                                         size_t count);

/* Up to 64 clipped draws as one SPRITE_BATCH, into destination or, when it
 * is NULL, the back buffer. Draws run in order and see earlier draws'
 * results. Flagged draws need a protocol 1.2 core (ENOTSUP otherwise). */
int noodles_surface_draw_batch(noodles_link_t *link, noodles_surface_t *destination,
                               const noodles_surface_draw_t *draws, size_t count);

/* Reap completed deferred frees. The count is the number of allocations
 * returned to the arena by this call. */
int noodles_surface_collect(noodles_link_t *link, size_t *count);

/* Fixed-cell atlas with LRU replacement. Keys are application-defined.
 * Replacing an in-flight cell waits only for that cell's final fence. */
int noodles_texture_cache_create(noodles_link_t *link, uint32_t cell_width,
                                 uint32_t cell_height, uint32_t columns, uint32_t rows,
                                 noodles_texture_cache_t **out);
int noodles_texture_cache_upload(noodles_texture_cache_t *cache, uint64_t key,
                                 const void *pixels, size_t source_pitch,
                                 uint32_t timeout_ms);
int noodles_texture_cache_contains(const noodles_texture_cache_t *cache, uint64_t key);
int noodles_texture_cache_batch_to_back_buffer(noodles_texture_cache_t *cache,
                                               const noodles_texture_blit_t *blits,
                                               size_t count);
/* One blended draw per call; batch blending is not yet available. */
int noodles_texture_cache_blend_to_back_buffer(noodles_texture_cache_t *cache,
                                               const noodles_texture_blit_t *blit,
                                               uint8_t alpha_mod);
int noodles_texture_cache_draw_batch_to_back_buffer(noodles_texture_cache_t *cache,
                                                    const noodles_texture_draw_t *draws,
                                                    size_t count);
int noodles_texture_cache_destroy(noodles_texture_cache_t *cache, uint32_t timeout_ms);

#ifdef __cplusplus
}
#endif
#endif
