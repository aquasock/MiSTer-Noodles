// Proves BLIT_COPY_KEY (opcode 3, BLIT-006) over the real LINK path:
// colorkey transparency, the mechanism sprite compositing needs.
//
// Builds a minimal "sprite" purely out of SOLID_FILLs -- a 64x64 source
// region filled entirely with a colorkey color, then a smaller solid
// square filled in its center -- and BLIT_COPY_KEYs that whole region onto
// the visible surface (itself pre-filled with a DIFFERENT background
// color). If colorkeying works, the visible surface ends up showing its
// own background everywhere except the inner square: the colorkey border
// never overwrote it, while the square copied normally.
//
// Usage, as root on the MiSTer:
//   ./blit_copy_key_push
// Colors are fixed (background=blue, colorkey=magenta, sprite=red) so a
// screenshot is self-explanatory without needing to know what was pushed.

#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <time.h>

#include "../lib/noodles_link.h"

#define VISIBLE_ADDR 0x30000000u
#define SOURCE_ADDR 0x30010000u  // arbitrary safe address, out of the visible surface
#define PITCH 256                // 64px * 4B
#define SIZE 64
#define SPRITE_SIZE 24
#define SPRITE_OFFSET ((SIZE - SPRITE_SIZE) / 2)

static int wait_for_fence(noodles_link_t *link, uint32_t done_before, const char *what) {
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 1000000};  // 1ms
    for (int i = 0; i < 200; ++i) {
        uint32_t done_now = noodles_link_done_count(link);
        if (done_now > done_before) return 0;
        nanosleep(&delay, NULL);
    }
    fprintf(stderr, "%s: fence never advanced past %u after 200ms\n", what, done_before);
    return 1;
}

static int push_and_wait_fill(noodles_link_t *link, uint32_t addr, uint16_t w, uint16_t h,
                               uint32_t color, const char *what) {
    uint32_t before = noodles_link_done_count(link);
    if (noodles_push_solid_fill(link, addr, PITCH, w, h, color) != 0) {
        fprintf(stderr, "ring full pushing %s\n", what);
        return 1;
    }
    return wait_for_fence(link, before, what);
}

int main(void) {
    noodles_link_t link;
    if (noodles_link_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        return 1;
    }

    uint32_t background = noodles_rgb(0x00, 0x40, 0xFF);  // blue
    uint32_t colorkey = noodles_rgb(0xFF, 0x00, 0xFF);    // magenta -- the "transparent" color
    uint32_t sprite = noodles_rgb(0xFF, 0x00, 0x00);      // red

    if (push_and_wait_fill(&link, VISIBLE_ADDR, SIZE, SIZE, background, "background fill")) {
        noodles_link_close(&link);
        return 1;
    }
    if (push_and_wait_fill(&link, SOURCE_ADDR, SIZE, SIZE, colorkey, "source colorkey fill")) {
        noodles_link_close(&link);
        return 1;
    }
    if (push_and_wait_fill(&link, SOURCE_ADDR + SPRITE_OFFSET * PITCH + SPRITE_OFFSET * 4,
                            SPRITE_SIZE, SPRITE_SIZE, sprite, "sprite square fill")) {
        noodles_link_close(&link);
        return 1;
    }

    uint32_t done_before = noodles_link_done_count(&link);
    if (noodles_push_blit_copy_key(&link, VISIBLE_ADDR, PITCH, SOURCE_ADDR, PITCH, SIZE, SIZE,
                                    colorkey) != 0) {
        fprintf(stderr, "ring full pushing blit copy key\n");
        noodles_link_close(&link);
        return 1;
    }
    if (wait_for_fence(&link, done_before, "blit copy key")) {
        noodles_link_close(&link);
        return 1;
    }

    noodles_link_close(&link);
    printf("done -- visible surface should now be blue with a centered %dx%d red square;\n"
           "the magenta colorkey border around the sprite should NOT have overwritten the blue.\n",
           SPRITE_SIZE, SPRITE_SIZE);
    return 0;
}
