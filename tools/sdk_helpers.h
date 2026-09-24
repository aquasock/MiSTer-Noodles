#ifndef NOODLES_SDK_HELPERS_H
#define NOODLES_SDK_HELPERS_H

#include <noodles_link.h>
#include <stdio.h>
#include <stdlib.h>

static inline int tool_open(noodles_link_t **link) {
    return noodles_link_open(link);
}

static inline void tool_close(noodles_link_t *link) {
    if (noodles_link_close(link, NOODLES_DEFAULT_TIMEOUT_MS) != 0) {
        perror("Noodles shutdown failed; reload the core before acknowledging recovery");
        exit(EXIT_FAILURE);
    }
}

static inline int tool_wait(noodles_link_t *link, const char *operation) {
    if (noodles_link_drain(link, NOODLES_DEFAULT_TIMEOUT_MS) == 0) return 0;
    perror(operation);
    return -1;
}
#endif
