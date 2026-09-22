// Pushes one SOLID_FILL (opcode 1, BLIT-002) anywhere, any size/color, over
// the real LINK path -- a general-purpose complement to link_push.c (which
// only ever fills the full 64x64 visible surface with a fixed cyan) and
// blit_copy_push.c (which needs a source region to copy from). Useful for
// filling a sub-rect of the visible surface, e.g. a colored square in one
// corner without touching the rest of it.
//
// Usage, as root on the MiSTer:
//   ./solid_fill_push <dst_addr_hex> <pitch_dec> <width_dec> <height_dec> <r_hex> <g_hex> <b_hex>
// dst_pitch should normally match the target surface's own stride (256 for
// the visible 64x64 surface), not the fill's own width, so each row lands
// in the right place within that surface -- see BLIT-002.

#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "../lib/noodles_link.h"

int main(int argc, char **argv) {
    if (argc != 8) {
        fprintf(stderr,
                "usage: %s <dst_addr_hex> <pitch_dec> <width_dec> <height_dec> <r_hex> <g_hex> "
                "<b_hex>\n",
                argv[0]);
        return 1;
    }
    uint32_t dst_addr = (uint32_t)strtoul(argv[1], NULL, 16);
    uint16_t pitch = (uint16_t)strtoul(argv[2], NULL, 10);
    uint16_t width = (uint16_t)strtoul(argv[3], NULL, 10);
    uint16_t height = (uint16_t)strtoul(argv[4], NULL, 10);
    uint8_t r = (uint8_t)strtoul(argv[5], NULL, 16);
    uint8_t g = (uint8_t)strtoul(argv[6], NULL, 16);
    uint8_t b = (uint8_t)strtoul(argv[7], NULL, 16);

    noodles_link_t link;
    if (noodles_link_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        return 1;
    }

    uint32_t color = noodles_rgb(r, g, b);
    uint32_t done_before = noodles_link_done_count(&link);

    if (noodles_push_solid_fill(&link, dst_addr, pitch, width, height, color) != 0) {
        fprintf(stderr, "ring full\n");
        noodles_link_close(&link);
        return 1;
    }

    struct timespec delay = {.tv_sec = 0, .tv_nsec = 1000000};  // 1ms
    for (int i = 0; i < 200; ++i) {
        uint32_t done_now = noodles_link_done_count(&link);
        if (done_now > done_before) {
            printf("filled %ux%u at 0x%08x with r=%02x g=%02x b=%02x (fence %u -> %u)\n", width,
                   height, dst_addr, r, g, b, done_before, done_now);
            noodles_link_close(&link);
            return 0;
        }
        nanosleep(&delay, NULL);
    }

    fprintf(stderr, "fence never advanced past %u after 200ms\n", done_before);
    noodles_link_close(&link);
    return 1;
}
