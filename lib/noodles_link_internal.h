#ifndef NOODLES_LINK_INTERNAL_H
#define NOODLES_LINK_INTERNAL_H

#include "noodles_link.h"
#include "noodles_surface.h"

struct noodles_extent {
    uint32_t address, size;
    struct noodles_extent *next;
};

struct noodles_surface {
    struct noodles_link *link;
    uint32_t address, size, width, height, pitch, last_fence;
    int used, retired;
    struct noodles_surface *next;
};

struct noodles_link {
    int fd, lock_fd;
    void *map;
    size_t map_span;
    volatile uint32_t *header, *slots;
    uint32_t write_ptr, submitted, presents_completed, done_baseline, confirmed_done;
    uint32_t batch_fence, present_fence;
    uint32_t token_lo, token_hi, ping_seq;
    int batch_pending, present_pending, ping_pending, verified, fault;
    int surface_allocator_initialized;
    struct noodles_extent *surface_free;
    struct noodles_surface *surfaces, *retired_surfaces;
};

/* Internal wrap-safe comparison, also exercised by transport regressions. */
int noodles_link_fence_reached(const noodles_link_t *link, uint32_t target);
int noodles_link_check(noodles_link_t *link);
int noodles_link_push_command_managed(noodles_link_t *link, const uint32_t command[8]);
int noodles_link_push_sprite_descriptors_managed(
    noodles_link_t *link, const noodles_sprite_descriptor_t *descriptors, uint16_t count);
void noodles_surface_link_cleanup(noodles_link_t *link);
#endif
