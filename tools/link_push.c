// Pushes one command into LINK's ring buffer (LINK-002/LINK-003) via
// lib/noodles_link.h -- the same real host-driven path this project has
// used since LINK-001's first hardware proof, now going through the actual
// library instead of hand-rolled mmap code (LINK-004).
//
// Fills the current back buffer (OUT-004) with cyan and presents it, so
// success is visually unambiguous and the result actually shows up --
// with double buffering, a fill alone never appears on screen until it's
// been presented.
//
// Usage, as root on the MiSTer:
//   ./link_push

#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <time.h>

#include "sdk_helpers.h"

int main(void) {
    noodles_link_t *link = NULL;
    if (tool_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        return 1;
    }

    uint32_t back = noodles_link_back_buffer(link);
    uint32_t color = noodles_rgb(0x00, 0xFF, 0xFF);  // cyan

    if (noodles_push_solid_fill(link, back, NOODLES_BUFFER_PITCH, NOODLES_BUFFER_WIDTH,
                                 NOODLES_BUFFER_HEIGHT, color) != 0) {
        perror("command submission");
        tool_close(link);
        return 1;
    }

    if (tool_wait(link, "fill completion") != 0) {
        fprintf(stderr, "fill never completed\n");
        tool_close(link);
        return 1;
    }

    int rc = noodles_present_and_wait(link);
    if (rc != 0) {
        fprintf(stderr, "present failed (rc=%d)\n", rc);
        tool_close(link);
        return 1;
    }

    printf("filled back buffer 0x%08x with cyan and presented it\n", back);
    tool_close(link);
    return 0;
}
