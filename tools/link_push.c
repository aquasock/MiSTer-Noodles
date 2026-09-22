// Pushes one command into LINK's ring buffer (LINK-002/LINK-003) via
// lib/noodles_link.h -- the same real host-driven path this project has
// used since LINK-001's first hardware proof, now going through the actual
// library instead of hand-rolled mmap code (LINK-004).
//
// Default command is SOLID_FILL of the same visible 64x64 surface
// (0x30000000, pitch 256) the OSD "Draw Test" button fills, but a
// different color (cyan, not magenta) -- so success is visually
// unambiguous: cyan means the FPGA picked this up via the ring, not the
// leftover OSD path.
//
// Usage, as root on the MiSTer:
//   ./link_push

#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <time.h>

#include "../lib/noodles_link.h"

int main(void) {
    noodles_link_t link;
    if (noodles_link_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        return 1;
    }

    uint32_t write_ptr_before = link.write_ptr;
    uint32_t done_before = noodles_link_done_count(&link);
    uint32_t color = noodles_rgb(0x00, 0xFF, 0xFF);  // cyan

    if (noodles_push_solid_fill(&link, 0x30000000u, 256, 64, 64, color) != 0) {
        fprintf(stderr, "ring full (write_ptr=%u) -- refusing to push\n", write_ptr_before);
        noodles_link_close(&link);
        return 1;
    }

    printf("pushed SOLID_FILL (cyan) into slot %u; write_ptr %u -> %u (fence was %u)\n",
           write_ptr_before, write_ptr_before, link.write_ptr, done_before);

    // Poll LINK-005's fence briefly to show the FPGA actually finishing the
    // command, not just accepting it -- a real fill completes in
    // microseconds, so this loop is expected to succeed almost immediately.
    //
    // This deliberately checks done_count > done_before, NOT
    // noodles_link_submitted_count() -- this program opens a fresh handle
    // on every invocation, so its own submitted count always starts at 1
    // regardless of how many commands earlier invocations pushed this same
    // FPGA session. Comparing a per-handle submitted count against the
    // FPGA's session-lifetime done_count is only valid within ONE long-lived
    // handle (the intended use, e.g. a game process open for its whole
    // run) -- across separate short-lived processes like this one, only
    // "did the fence move past what it already was" is a meaningful check.
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 1000000};  // 1ms
    for (int i = 0; i < 100; ++i) {
        uint32_t done_now = noodles_link_done_count(&link);
        if (done_now > done_before) {
            printf("fence confirms completion: done_count %u -> %u\n", done_before, done_now);
            noodles_link_close(&link);
            return 0;
        }
        nanosleep(&delay, NULL);
    }

    fprintf(stderr, "fence never advanced past %u after 100ms\n", done_before);
    noodles_link_close(&link);
    return 1;
}
