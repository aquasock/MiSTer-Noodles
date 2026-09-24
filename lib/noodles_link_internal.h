#ifndef NOODLES_LINK_INTERNAL_H
#define NOODLES_LINK_INTERNAL_H

#include "noodles_link.h"

struct noodles_link {
    int fd, lock_fd;
    void *map;
    size_t map_span;
    volatile uint32_t *header, *slots;
    uint32_t write_ptr, submitted, presents_completed, done_baseline;
    uint32_t batch_fence, present_fence;
    uint32_t token_lo, token_hi, ping_seq;
    int batch_pending, present_pending, ping_pending, verified, fault;
};

/* Internal wrap-safe comparison, also exercised by transport regressions. */
int noodles_link_fence_reached(const noodles_link_t *link, uint32_t target);
#endif
