// Proves BLIT_COPY (opcode 2, BLIT-003) over LINK-001's real ring-buffer
// path -- until now it had only ever been exercised via the (now-retired,
// CMDQ-003) OSD "Blit Copy Test" button and simulation, never actually
// pushed through link_ring on real hardware.
//
// Two commands, in order: SOLID_FILL an out-of-view source rect with a
// distinct color via link_push, then BLIT_COPY that exact region into the
// visible 64x64 surface. If the destination ends up matching the source
// color, BLIT_COPY genuinely read what SOLID_FILL wrote and copied it --
// not just "accepted a command and did something".
//
// Usage, as root on the MiSTer:
//   ./blit_copy_push [r_hex] [g_hex] [b_hex]
// Color defaults to orange (ff 80 00). A caller re-running this repeatedly
// to eyeball the result on screen should pass a different color each time,
// so a stale leftover frame can never be mistaken for a fresh success.

#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "../lib/noodles_link.h"

#define VISIBLE_ADDR 0x30000000u
#define SOURCE_ADDR 0x30010000u  // arbitrary safe address, out of the visible surface
#define PITCH 256                // 64px * 4B
#define SIZE 64

static int wait_for_fence(noodles_link_t *link, uint32_t done_before, const char *what) {
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 1000000};  // 1ms
    for (int i = 0; i < 200; ++i) {
        uint32_t done_now = noodles_link_done_count(link);
        if (done_now > done_before) {
            printf("%s: fence %u -> %u\n", what, done_before, done_now);
            return 0;
        }
        nanosleep(&delay, NULL);
    }
    fprintf(stderr, "%s: fence never advanced past %u after 200ms\n", what, done_before);
    return 1;
}

int main(int argc, char **argv) {
    uint8_t r = (argc > 1) ? (uint8_t)strtoul(argv[1], NULL, 16) : 0xFF;
    uint8_t g = (argc > 2) ? (uint8_t)strtoul(argv[2], NULL, 16) : 0x80;
    uint8_t b = (argc > 3) ? (uint8_t)strtoul(argv[3], NULL, 16) : 0x00;

    noodles_link_t link;
    if (noodles_link_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        return 1;
    }

    uint32_t color = noodles_rgb(r, g, b);

    uint32_t done_before = noodles_link_done_count(&link);
    if (noodles_push_solid_fill(&link, SOURCE_ADDR, PITCH, SIZE, SIZE, color) != 0) {
        fprintf(stderr, "ring full pushing source fill\n");
        noodles_link_close(&link);
        return 1;
    }
    if (wait_for_fence(&link, done_before, "source fill")) {
        noodles_link_close(&link);
        return 1;
    }

    done_before = noodles_link_done_count(&link);
    if (noodles_push_blit_copy(&link, VISIBLE_ADDR, PITCH, SOURCE_ADDR, PITCH, SIZE, SIZE) != 0) {
        fprintf(stderr, "ring full pushing blit copy\n");
        noodles_link_close(&link);
        return 1;
    }
    if (wait_for_fence(&link, done_before, "blit copy")) {
        noodles_link_close(&link);
        return 1;
    }

    noodles_link_close(&link);
    printf("done -- visible surface at 0x%08x should now be solid r=%02x g=%02x b=%02x (0x%08x),\n"
           "copied from source at 0x%08x by BLIT_COPY, not written there directly.\n",
           VISIBLE_ADDR, r, g, b, color, SOURCE_ADDR);
    return 0;
}
