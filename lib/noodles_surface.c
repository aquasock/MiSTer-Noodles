#define _POSIX_C_SOURCE 200809L
#include "noodles_link_internal.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define SURFACE_ALIGNMENT 4096u
#define PITCH_ALIGNMENT 64u
#define NOODLES_OP_SOLID_FILL 1u
#define NOODLES_OP_BLIT_COPY 2u
#define NOODLES_OP_BLIT_BLEND 7u

struct texture_slot {
    uint64_t key, age;
    uint32_t last_fence;
    int valid, used;
};

struct noodles_texture_cache {
    noodles_link_t *link;
    noodles_surface_t *atlas;
    void *atlas_map;
    size_t atlas_map_span;
    struct texture_slot *slots;
    uint32_t cell_width, cell_height, columns, rows, capacity;
    uint64_t age;
};

static int fail(int error) {
    errno = error;
    return -1;
}

static int active_surface(const noodles_surface_t *surface) {
    return surface && surface->link && !surface->retired;
}

static int initialize_allocator(noodles_link_t *link) {
    if (link->surface_allocator_initialized) return 0;
    struct noodles_extent *extent = malloc(sizeof(*extent));
    if (!extent) return -1;
    *extent = (struct noodles_extent){
        NOODLES_SURFACE_ARENA_ADDR, NOODLES_SURFACE_ARENA_BYTES, NULL
    };
    link->surface_free = extent;
    link->surface_allocator_initialized = 1;
    return 0;
}

static int insert_extent(noodles_link_t *link, uint32_t address, uint32_t size) {
    struct noodles_extent **cursor = &link->surface_free;
    while (*cursor && (*cursor)->address < address) cursor = &(*cursor)->next;

    struct noodles_extent *previous = NULL;
    for (struct noodles_extent *item = link->surface_free; item && item != *cursor;
         item = item->next)
        previous = item;

    if (previous && (uint64_t)previous->address + previous->size == address) {
        previous->size += size;
        if (*cursor && (uint64_t)previous->address + previous->size == (*cursor)->address) {
            struct noodles_extent *next = *cursor;
            previous->size += next->size;
            previous->next = next->next;
            free(next);
        }
        return 0;
    }
    if (*cursor && (uint64_t)address + size == (*cursor)->address) {
        (*cursor)->address = address;
        (*cursor)->size += size;
        return 0;
    }

    struct noodles_extent *extent = malloc(sizeof(*extent));
    if (!extent) return -1;
    *extent = (struct noodles_extent){address, size, *cursor};
    if (previous) previous->next = extent;
    else link->surface_free = extent;
    return 0;
}

int noodles_surface_collect(noodles_link_t *link, size_t *count) {
    if (!link || !count) return fail(EINVAL);
    if (noodles_link_check(link) != 0) return -1;
    *count = 0;
    struct noodles_surface **cursor = &link->retired_surfaces;
    while (*cursor) {
        noodles_surface_t *surface = *cursor;
        int complete = !surface->used;
        if (!complete && noodles_link_poll(link, surface->last_fence, &complete) != 0) return -1;
        if (!complete) {
            cursor = &surface->next;
            continue;
        }
        if (insert_extent(link, surface->address, surface->size) != 0) return -1;
        *cursor = surface->next;
        free(surface);
        ++*count;
    }
    return 0;
}

static int allocate_extent(noodles_link_t *link, uint32_t size, uint32_t *address) {
    struct noodles_extent **cursor = &link->surface_free;
    while (*cursor && (*cursor)->size < size) cursor = &(*cursor)->next;
    if (!*cursor) return fail(ENOMEM);
    struct noodles_extent *extent = *cursor;
    *address = extent->address;
    extent->address += size;
    extent->size -= size;
    if (!extent->size) {
        *cursor = extent->next;
        free(extent);
    }
    return 0;
}

int noodles_surface_create(noodles_link_t *link, uint32_t width, uint32_t height,
                           noodles_surface_t **out) {
    if (!link || !out) return fail(EINVAL);
    *out = NULL;
    if (noodles_link_check(link) != 0) return -1;
    uint64_t row = (uint64_t)width * 4;
    uint64_t pitch = (row + PITCH_ALIGNMENT - 1) & ~(uint64_t)(PITCH_ALIGNMENT - 1);
    uint64_t bytes = pitch * height;
    uint64_t allocated = (bytes + SURFACE_ALIGNMENT - 1) & ~(uint64_t)(SURFACE_ALIGNMENT - 1);
    if (!width || !height || width > 65535 || height > 65535 || pitch > 65535 ||
        !allocated || allocated > NOODLES_SURFACE_ARENA_BYTES)
        return fail(EINVAL);
    if (initialize_allocator(link) != 0) return -1;
    size_t collected;
    if (noodles_surface_collect(link, &collected) != 0) return -1;

    noodles_surface_t *surface = calloc(1, sizeof(*surface));
    if (!surface) return -1;
    if (allocate_extent(link, (uint32_t)allocated, &surface->address) != 0) {
        free(surface);
        return -1;
    }
    surface->link = link;
    surface->size = (uint32_t)allocated;
    surface->width = width;
    surface->height = height;
    surface->pitch = (uint32_t)pitch;
    surface->next = link->surfaces;
    link->surfaces = surface;
    *out = surface;
    return 0;
}

int noodles_surface_destroy(noodles_surface_t *surface) {
    if (!active_surface(surface)) return fail(EINVAL);
    noodles_link_t *link = surface->link;
    struct noodles_surface **cursor = &link->surfaces;
    while (*cursor && *cursor != surface) cursor = &(*cursor)->next;
    if (!*cursor) return fail(EINVAL);
    *cursor = surface->next;
    surface->retired = 1;
    surface->next = link->retired_surfaces;
    link->retired_surfaces = surface;
    return 0;
}

uint32_t noodles_surface_width(const noodles_surface_t *surface) {
    return active_surface(surface) ? surface->width : 0;
}

uint32_t noodles_surface_height(const noodles_surface_t *surface) {
    return active_surface(surface) ? surface->height : 0;
}

uint32_t noodles_surface_pitch(const noodles_surface_t *surface) {
    return active_surface(surface) ? surface->pitch : 0;
}

static int validate_transfer(const noodles_surface_t *surface, const noodles_rect_t *rect,
                             size_t host_pitch) {
    if (!active_surface(surface) || !rect || rect->x < 0 || rect->y < 0 ||
        !rect->width || !rect->height)
        return 0;
    uint64_t right = (uint64_t)(uint32_t)rect->x + rect->width;
    uint64_t bottom = (uint64_t)(uint32_t)rect->y + rect->height;
    return right <= surface->width && bottom <= surface->height &&
        host_pitch >= (uint64_t)rect->width * 4;
}

static int wait_for_cpu(noodles_surface_t *surface, uint32_t timeout_ms) {
    if (noodles_link_check(surface->link) != 0) return -1;
    if (!surface->used) return 0;
    if (noodles_link_wait(surface->link, surface->last_fence, timeout_ms) != 0) return -1;
    surface->used = 0;
    return 0;
}

static int transfer(noodles_surface_t *surface, const noodles_rect_t *rect, void *pixels,
                    size_t host_pitch, uint32_t timeout_ms, int write) {
    if (!pixels || !validate_transfer(surface, rect, host_pitch)) return fail(EINVAL);
    if (surface->link->present_pending) return fail(EAGAIN);
    if (wait_for_cpu(surface, timeout_ms) != 0) return -1;

    uint64_t address64 = (uint64_t)surface->address + (uint32_t)rect->y * surface->pitch +
        (uint32_t)rect->x * 4;
    size_t row_bytes = (size_t)rect->width * 4;
    size_t span = (size_t)(rect->height - 1) * surface->pitch + row_bytes;
    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0 || (page & (page - 1))) return fail(EIO);
    uint32_t address = (uint32_t)address64;
    uint32_t aligned = address & ~(uint32_t)(page - 1);
    size_t offset = address - aligned;
    size_t map_span = offset + span;
    map_span = (map_span + (size_t)page - 1) & ~((size_t)page - 1);
    int protection = write ? PROT_WRITE : PROT_READ;
    void *map = mmap(NULL, map_span, protection, MAP_SHARED, surface->link->fd, aligned);
    if (map == MAP_FAILED) return -1;

    for (uint32_t y = 0; y < rect->height; ++y) {
        void *device_row = (char *)map + offset + (size_t)y * surface->pitch;
        void *host_row = (char *)pixels + y * host_pitch;
        if (write) memcpy(device_row, host_row, row_bytes);
        else memcpy(host_row, device_row, row_bytes);
    }
    __sync_synchronize();
    return munmap(map, map_span);
}

int noodles_surface_update(noodles_surface_t *surface, const noodles_rect_t *rect,
                           const void *pixels, size_t source_pitch, uint32_t timeout_ms) {
    return transfer(surface, rect, (void *)pixels, source_pitch, timeout_ms, 1);
}

int noodles_surface_read(noodles_surface_t *surface, const noodles_rect_t *rect,
                         void *pixels, size_t destination_pitch, uint32_t timeout_ms) {
    return transfer(surface, rect, pixels, destination_pitch, timeout_ms, 0);
}

static int clip_rect(const noodles_surface_t *surface, const noodles_rect_t *requested,
                     int32_t *x, int32_t *y, uint32_t *width, uint32_t *height) {
    if (!active_surface(surface) || !requested || !requested->width || !requested->height)
        return fail(EINVAL);
    int64_t left = requested->x;
    int64_t top = requested->y;
    int64_t right = left + requested->width;
    int64_t bottom = top + requested->height;
    if (right <= 0 || bottom <= 0 || left >= surface->width || top >= surface->height)
        return 0;
    if (left < 0) left = 0;
    if (top < 0) top = 0;
    if (right > surface->width) right = surface->width;
    if (bottom > surface->height) bottom = surface->height;
    *x = (int32_t)left;
    *y = (int32_t)top;
    *width = (uint32_t)(right - left);
    *height = (uint32_t)(bottom - top);
    return 1;
}

static void mark_used(noodles_surface_t *surface) {
    surface->last_fence = noodles_link_last_fence(surface->link);
    surface->used = 1;
}

int noodles_surface_fill(noodles_surface_t *destination, const noodles_rect_t *rect,
                         uint32_t color) {
    int32_t x, y;
    uint32_t width, height;
    int clipped = clip_rect(destination, rect, &x, &y, &width, &height);
    if (clipped <= 0) return clipped;
    uint32_t command[8] = {
        NOODLES_OP_SOLID_FILL,
        destination->address + (uint32_t)y * destination->pitch + (uint32_t)x * 4,
        destination->pitch, width, height, color, 0, 0
    };
    if (noodles_link_push_command_managed(destination->link, command) != 0) return -1;
    mark_used(destination);
    return 0;
}

static int clipped_blit(const noodles_surface_t *destination, uint32_t destination_address,
                        uint32_t destination_width, uint32_t destination_height,
                        int32_t dst_x, int32_t dst_y, const noodles_surface_t *source,
                        const noodles_rect_t *requested, noodles_sprite_descriptor_t *out) {
    if (!active_surface(source) || !requested || !requested->width || !requested->height)
        return fail(EINVAL);
    if (destination && (!active_surface(destination) || destination->link != source->link))
        return fail(EINVAL);
    int64_t sx = requested->x, sy = requested->y;
    int64_t dx = dst_x, dy = dst_y;
    int64_t width = requested->width, height = requested->height;
    if (sx < 0) { width += sx; dx -= sx; sx = 0; }
    if (sy < 0) { height += sy; dy -= sy; sy = 0; }
    if (sx + width > source->width) width = source->width - sx;
    if (sy + height > source->height) height = source->height - sy;
    if (dx < 0) { width += dx; sx -= dx; dx = 0; }
    if (dy < 0) { height += dy; sy -= dy; dy = 0; }
    if (dx + width > destination_width) width = destination_width - dx;
    if (dy + height > destination_height) height = destination_height - dy;
    if (width <= 0 || height <= 0) return 0;
    *out = (noodles_sprite_descriptor_t){
        destination_address + (uint32_t)dy *
            (destination ? destination->pitch : NOODLES_BUFFER_PITCH) + (uint32_t)dx * 4,
        destination ? destination->pitch : NOODLES_BUFFER_PITCH,
        (uint32_t)width, (uint32_t)height, 0,
        source->address + (uint32_t)sy * source->pitch + (uint32_t)sx * 4,
        source->pitch, 0
    };
    return 1;
}

static int push_descriptor(noodles_link_t *link, uint32_t op, uint32_t word5,
                           const noodles_sprite_descriptor_t *d) {
    uint32_t command[8] = {
        op, d->dst_addr, d->dst_pitch, d->width, d->height, word5, d->src_addr, d->src_pitch
    };
    return noodles_link_push_command_managed(link, command);
}

static int surface_to_surface(noodles_surface_t *destination, int32_t dst_x, int32_t dst_y,
                              const noodles_surface_t *source, const noodles_rect_t *source_rect,
                              uint32_t op, uint32_t word5) {
    if (!active_surface(destination) || destination == source) return fail(EINVAL);
    noodles_sprite_descriptor_t descriptor;
    int clipped = clipped_blit(destination, destination->address, destination->width,
                               destination->height, dst_x, dst_y, source, source_rect, &descriptor);
    if (clipped <= 0) return clipped;
    if (push_descriptor(destination->link, op, word5, &descriptor) != 0) return -1;
    mark_used((noodles_surface_t *)source);
    mark_used(destination);
    return 0;
}

static int surface_to_back_buffer(noodles_link_t *link, int32_t dst_x, int32_t dst_y,
                                  const noodles_surface_t *source,
                                  const noodles_rect_t *source_rect, uint32_t op, uint32_t word5) {
    if (!link || !active_surface(source) || source->link != link) return fail(EINVAL);
    noodles_sprite_descriptor_t descriptor;
    int clipped = clipped_blit(NULL, noodles_link_back_buffer(link), NOODLES_BUFFER_WIDTH,
                               NOODLES_BUFFER_HEIGHT, dst_x, dst_y, source, source_rect,
                               &descriptor);
    if (clipped <= 0) return clipped;
    if (push_descriptor(link, op, word5, &descriptor) != 0) return -1;
    mark_used((noodles_surface_t *)source);
    return 0;
}

int noodles_surface_blit(noodles_surface_t *destination, int32_t dst_x, int32_t dst_y,
                         const noodles_surface_t *source, const noodles_rect_t *source_rect) {
    return surface_to_surface(destination, dst_x, dst_y, source, source_rect,
                              NOODLES_OP_BLIT_COPY, 0);
}

int noodles_surface_blit_to_back_buffer(noodles_link_t *link, int32_t dst_x, int32_t dst_y,
                                        const noodles_surface_t *source,
                                        const noodles_rect_t *source_rect) {
    return surface_to_back_buffer(link, dst_x, dst_y, source, source_rect,
                                  NOODLES_OP_BLIT_COPY, 0);
}

int noodles_surface_blend(noodles_surface_t *destination, int32_t dst_x, int32_t dst_y,
                          const noodles_surface_t *source, const noodles_rect_t *source_rect,
                          uint8_t alpha_mod) {
    return surface_to_surface(destination, dst_x, dst_y, source, source_rect,
                              NOODLES_OP_BLIT_BLEND, alpha_mod);
}

int noodles_surface_blend_to_back_buffer(noodles_link_t *link, int32_t dst_x, int32_t dst_y,
                                         const noodles_surface_t *source,
                                         const noodles_rect_t *source_rect, uint8_t alpha_mod) {
    return surface_to_back_buffer(link, dst_x, dst_y, source, source_rect,
                                  NOODLES_OP_BLIT_BLEND, alpha_mod);
}

int noodles_surface_batch_to_back_buffer(noodles_link_t *link,
                                         const noodles_surface_blit_t *blits,
                                         size_t count) {
    if (!link || !blits || !count || count > NOODLES_SPRITE_DESCRIPTOR_MAX)
        return fail(EINVAL);
    noodles_sprite_descriptor_t descriptors[NOODLES_SPRITE_DESCRIPTOR_MAX];
    noodles_surface_t *used[NOODLES_SPRITE_DESCRIPTOR_MAX];
    size_t descriptor_count = 0;
    for (size_t i = 0; i < count; ++i) {
        const noodles_surface_t *source = blits[i].source;
        if (!active_surface(source) || source->link != link) return fail(EINVAL);
        int clipped = clipped_blit(NULL, noodles_link_back_buffer(link), NOODLES_BUFFER_WIDTH,
                                   NOODLES_BUFFER_HEIGHT, blits[i].dst_x, blits[i].dst_y,
                                   source, &blits[i].source_rect,
                                   &descriptors[descriptor_count]);
        if (clipped < 0) return -1;
        if (clipped) used[descriptor_count++] = (noodles_surface_t *)source;
    }
    if (!descriptor_count) return 0;
    if (noodles_link_push_sprite_descriptors_managed(
            link, descriptors, (uint16_t)descriptor_count) != 0)
        return -1;
    for (size_t i = 0; i < descriptor_count; ++i) mark_used(used[i]);
    return 0;
}

void noodles_surface_link_cleanup(noodles_link_t *link) {
    noodles_surface_t *surface = link->surfaces;
    while (surface) {
        noodles_surface_t *next = surface->next;
        free(surface);
        surface = next;
    }
    surface = link->retired_surfaces;
    while (surface) {
        noodles_surface_t *next = surface->next;
        free(surface);
        surface = next;
    }
    struct noodles_extent *extent = link->surface_free;
    while (extent) {
        struct noodles_extent *next = extent->next;
        free(extent);
        extent = next;
    }
}

static int cache_slot_view(noodles_texture_cache_t *cache, uint32_t index,
                           noodles_surface_t *view) {
    if (!cache || index >= cache->capacity) return fail(EINVAL);
    uint32_t x = (index % cache->columns) * cache->cell_width;
    uint32_t y = (index / cache->columns) * cache->cell_height;
    *view = (noodles_surface_t){
        cache->link,
        cache->atlas->address + y * cache->atlas->pitch + x * 4,
        0,
        cache->cell_width,
        cache->cell_height,
        cache->atlas->pitch,
        cache->slots[index].last_fence,
        cache->slots[index].used,
        0,
        NULL
    };
    return 0;
}

int noodles_texture_cache_create(noodles_link_t *link, uint32_t cell_width,
                                 uint32_t cell_height, uint32_t columns, uint32_t rows,
                                 noodles_texture_cache_t **out) {
    if (!link || !out || !cell_width || !cell_height || !columns || !rows)
        return fail(EINVAL);
    *out = NULL;
    uint64_t width = (uint64_t)cell_width * columns;
    uint64_t height = (uint64_t)cell_height * rows;
    uint64_t capacity = (uint64_t)columns * rows;
    if (width > 65535 || height > 65535 || capacity > UINT32_MAX) return fail(EINVAL);
    noodles_texture_cache_t *cache = calloc(1, sizeof(*cache));
    if (!cache) return -1;
    cache->slots = calloc((size_t)capacity, sizeof(*cache->slots));
    if (!cache->slots) {
        free(cache);
        return -1;
    }
    if (noodles_surface_create(link, (uint32_t)width, (uint32_t)height, &cache->atlas) != 0) {
        free(cache->slots);
        free(cache);
        return -1;
    }
    cache->link = link;
    cache->cell_width = cell_width;
    cache->cell_height = cell_height;
    cache->columns = columns;
    cache->rows = rows;
    cache->capacity = (uint32_t)capacity;
    cache->atlas_map_span = cache->atlas->size;
    cache->atlas_map = mmap(NULL, cache->atlas_map_span, PROT_WRITE, MAP_SHARED,
                            link->fd, cache->atlas->address);
    if (cache->atlas_map == MAP_FAILED) {
        int saved = errno;
        (void)noodles_surface_destroy(cache->atlas);
        free(cache->slots);
        free(cache);
        return fail(saved);
    }
    *out = cache;
    return 0;
}

static int find_key(const noodles_texture_cache_t *cache, uint64_t key) {
    for (uint32_t i = 0; i < cache->capacity; ++i)
        if (cache->slots[i].valid && cache->slots[i].key == key) return (int)i;
    return -1;
}

int noodles_texture_cache_contains(const noodles_texture_cache_t *cache, uint64_t key) {
    if (!cache) return 0;
    return find_key(cache, key) >= 0;
}

static int choose_slot(noodles_texture_cache_t *cache) {
    uint32_t oldest = 0;
    for (uint32_t i = 0; i < cache->capacity; ++i) {
        if (!cache->slots[i].valid) return (int)i;
        if (cache->slots[i].age < cache->slots[oldest].age) oldest = i;
    }
    return (int)oldest;
}

int noodles_texture_cache_upload(noodles_texture_cache_t *cache, uint64_t key,
                                 const void *pixels, size_t source_pitch,
                                 uint32_t timeout_ms) {
    if (!cache || !pixels || source_pitch < (uint64_t)cache->cell_width * 4)
        return fail(EINVAL);
    int index = find_key(cache, key);
    if (index < 0) index = choose_slot(cache);
    struct texture_slot *slot = &cache->slots[index];
    if (slot->used &&
        noodles_link_wait(cache->link, slot->last_fence, timeout_ms) != 0)
        return -1;

    uint32_t slot_x = ((uint32_t)index % cache->columns) * cache->cell_width;
    uint32_t slot_y = ((uint32_t)index / cache->columns) * cache->cell_height;
    size_t row_bytes = (size_t)cache->cell_width * 4;
    for (uint32_t y = 0; y < cache->cell_height; ++y) {
        void *destination = (char *)cache->atlas_map +
            (size_t)(slot_y + y) * cache->atlas->pitch + (size_t)slot_x * 4;
        const void *source = (const char *)pixels + (size_t)y * source_pitch;
        memcpy(destination, source, row_bytes);
    }
    __sync_synchronize();
    *slot = (struct texture_slot){key, ++cache->age, 0, 1, 0};
    return 0;
}

int noodles_texture_cache_batch_to_back_buffer(noodles_texture_cache_t *cache,
                                               const noodles_texture_blit_t *blits,
                                               size_t count) {
    if (!cache || !blits || !count || count > NOODLES_SPRITE_DESCRIPTOR_MAX)
        return fail(EINVAL);
    noodles_sprite_descriptor_t descriptors[NOODLES_SPRITE_DESCRIPTOR_MAX];
    uint32_t used_slots[NOODLES_SPRITE_DESCRIPTOR_MAX];
    size_t descriptor_count = 0;
    for (size_t i = 0; i < count; ++i) {
        int index = find_key(cache, blits[i].key);
        if (index < 0) return fail(ENOENT);
        noodles_surface_t view;
        cache_slot_view(cache, (uint32_t)index, &view);
        int clipped = clipped_blit(NULL, noodles_link_back_buffer(cache->link),
                                   NOODLES_BUFFER_WIDTH, NOODLES_BUFFER_HEIGHT,
                                   blits[i].dst_x, blits[i].dst_y, &view,
                                   &blits[i].source_rect, &descriptors[descriptor_count]);
        if (clipped < 0) return -1;
        if (clipped) used_slots[descriptor_count++] = (uint32_t)index;
    }
    if (!descriptor_count) return 0;
    if (noodles_link_push_sprite_descriptors_managed(
            cache->link, descriptors, (uint16_t)descriptor_count) != 0)
        return -1;
    uint32_t fence = noodles_link_last_fence(cache->link);
    for (size_t i = 0; i < descriptor_count; ++i) {
        struct texture_slot *slot = &cache->slots[used_slots[i]];
        slot->last_fence = fence;
        slot->used = 1;
        slot->age = ++cache->age;
    }
    return 0;
}

int noodles_texture_cache_blend_to_back_buffer(noodles_texture_cache_t *cache,
                                               const noodles_texture_blit_t *blit,
                                               uint8_t alpha_mod) {
    if (!cache || !blit) return fail(EINVAL);
    int index = find_key(cache, blit->key);
    if (index < 0) return fail(ENOENT);
    noodles_surface_t view;
    cache_slot_view(cache, (uint32_t)index, &view);
    noodles_sprite_descriptor_t descriptor;
    int clipped = clipped_blit(NULL, noodles_link_back_buffer(cache->link),
                               NOODLES_BUFFER_WIDTH, NOODLES_BUFFER_HEIGHT,
                               blit->dst_x, blit->dst_y, &view, &blit->source_rect, &descriptor);
    if (clipped <= 0) return clipped;
    if (push_descriptor(cache->link, NOODLES_OP_BLIT_BLEND, alpha_mod, &descriptor) != 0)
        return -1;
    struct texture_slot *slot = &cache->slots[index];
    slot->last_fence = noodles_link_last_fence(cache->link);
    slot->used = 1;
    slot->age = ++cache->age;
    return 0;
}

int noodles_texture_cache_destroy(noodles_texture_cache_t *cache, uint32_t timeout_ms) {
    if (!cache) return fail(EINVAL);
    for (uint32_t i = 0; i < cache->capacity; ++i) {
        if (cache->slots[i].used &&
            noodles_link_wait(cache->link, cache->slots[i].last_fence, timeout_ms) != 0)
            return -1;
        cache->slots[i].used = 0;
    }
    if (munmap(cache->atlas_map, cache->atlas_map_span) != 0) return -1;
    if (noodles_surface_destroy(cache->atlas) != 0) return -1;
    free(cache->slots);
    free(cache);
    return 0;
}
