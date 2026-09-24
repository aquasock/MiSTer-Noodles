// The actual target this engine's rendering capability was scoped for
// (BLIT-006/OUT-004): a sprite character animated and composited over a
// background, continuously, the way a real "SDL game loop" would drive it
// -- not the isolated one-shot static demos every other tool here is.
// Every previous demo pushed a handful of commands and stopped; this one
// runs the full per-frame cycle (clear background, colorkey-blit the
// sprite at a new position, present, wait) hundreds of times in a row,
// which is the first real soak test of the ring buffer under sustained
// load, the fence under continuous polling, and present's vblank sync
// over many consecutive flips.
//
// The sprite itself is built once, purely from SOLID_FILLs (a colorkey
// background rect, then a "body" rect and a smaller offset "head" rect on
// top of it -- a crude but genuine two-part silhouette, not just a single
// square) -- then bounced around the screen off the buffer edges,
// re-fetching noodles_link_back_buffer() each frame the way any real game
// loop would.
//
// Usage, as root on the MiSTer:
//   ./sprite_demo [seconds] [batch]

#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "sdk_helpers.h"

// Own 2MB-aligned scratch slot for the sprite's source art, clear of both
// double-buffer surfaces and of LINK-002's ring -- same convention as
// blit_copy_push.c/blit_copy_key_push.c's SOURCE_ADDR.
#define SPRITE_SRC_ADDR 0x31400000u
#define SPRITE_W 64u
#define SPRITE_H 48u

#define BODY_X 8u
#define BODY_Y 16u
#define BODY_W 48u
#define BODY_H 32u

#define HEAD_X 0u
#define HEAD_Y 0u
#define HEAD_W 20u
#define HEAD_H 20u

#define STEP_PX 8
#define BG_COLOR_R 0x30
#define BG_COLOR_G 0x60
#define BG_COLOR_B 0xA0

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static int build_sprite(noodles_link_t *link) {
    uint32_t colorkey = noodles_rgb(0xFF, 0x00, 0xFF);          // magenta
    uint32_t body = noodles_rgb(0xC0, 0x70, 0x20);              // brown/orange
    uint32_t head = noodles_rgb(0xE0, 0xB0, 0x80);              // lighter tan

    if (noodles_push_solid_fill(link, SPRITE_SRC_ADDR, NOODLES_BUFFER_PITCH, SPRITE_W, SPRITE_H,
                                 colorkey) != 0) {
        perror("sprite colorkey background submission");
        return 1;
    }
    if (tool_wait(link, "sprite colorkey background")) return 1;

    if (noodles_push_solid_fill(link, SPRITE_SRC_ADDR + BODY_Y * NOODLES_BUFFER_PITCH + BODY_X * 4,
                                 NOODLES_BUFFER_PITCH, BODY_W, BODY_H, body) != 0) {
        perror("sprite body submission");
        return 1;
    }
    if (tool_wait(link, "sprite body")) return 1;

    if (noodles_push_solid_fill(link, SPRITE_SRC_ADDR + HEAD_Y * NOODLES_BUFFER_PITCH + HEAD_X * 4,
                                 NOODLES_BUFFER_PITCH, HEAD_W, HEAD_H, head) != 0) {
        perror("sprite head submission");
        return 1;
    }
    if (tool_wait(link, "sprite head")) return 1;

    return 0;
}

int main(int argc, char **argv) {
    double run_seconds = (argc > 1) ? atof(argv[1]) : 15.0;
    int use_batch = (argc > 2 && strcmp(argv[2], "batch") == 0);

    noodles_link_t *link = NULL;
    if (tool_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        return 1;
    }

    printf("building sprite at 0x%08x (%ux%u, colorkey magenta)...\n", SPRITE_SRC_ADDR, SPRITE_W,
           SPRITE_H);
    if (build_sprite(link)) {
        fprintf(stderr, "failed to build sprite\n");
        tool_close(link);
        return 1;
    }

    uint32_t colorkey = noodles_rgb(0xFF, 0x00, 0xFF);
    uint32_t background = noodles_rgb(BG_COLOR_R, BG_COLOR_G, BG_COLOR_B);

    int x = 0, y = 0;
    int dx = STEP_PX, dy = STEP_PX;
    const int max_x = (int)NOODLES_BUFFER_WIDTH - (int)SPRITE_W;
    const int max_y = (int)NOODLES_BUFFER_HEIGHT - (int)SPRITE_H;

    printf("bouncing sprite around %ux%u for %.1fs...\n", NOODLES_BUFFER_WIDTH,
           NOODLES_BUFFER_HEIGHT, run_seconds);

    double t_start = now_s();
    long frame = 0;
    int failed = 0;
    while (now_s() - t_start < run_seconds) {
        uint32_t back = noodles_link_back_buffer(link);

        if (noodles_push_solid_fill(link, back, NOODLES_BUFFER_PITCH, NOODLES_BUFFER_WIDTH,
                                     NOODLES_BUFFER_HEIGHT, background) != 0) {
            perror("background clear submission");
            failed = 1;
            break;
        }
        if (tool_wait(link, "background clear")) { failed = 1; break; }

        int queued;
        if (use_batch) {
            noodles_sprite_descriptor_t descriptor = {
                back + (uint32_t)y * NOODLES_BUFFER_PITCH + (uint32_t)x * 4,
                NOODLES_BUFFER_PITCH, SPRITE_W, SPRITE_H, colorkey, SPRITE_SRC_ADDR,
                NOODLES_BUFFER_PITCH, 1u};
            queued = noodles_push_sprite_batch(link, &descriptor, 1);
        } else {
            queued = noodles_push_blit_copy_key(link,
                back + (uint32_t)y * NOODLES_BUFFER_PITCH + (uint32_t)x * 4,
                NOODLES_BUFFER_PITCH, SPRITE_SRC_ADDR, NOODLES_BUFFER_PITCH,
                SPRITE_W, SPRITE_H, colorkey);
        }
        if (queued != 0) {
            fprintf(stderr, "frame %ld: sprite submission failed\n", frame);
            perror("sprite submission");
            failed = 1;
            break;
        }
        if (tool_wait(link, "sprite composite")) { failed = 1; break; }

        if (noodles_present_and_wait(link) != 0) {
            perror("present");
            failed = 1;
            break;
        }

        x += dx;
        y += dy;
        if (x <= 0 || x >= max_x) {
            dx = -dx;
            x += dx;
        }
        if (y <= 0 || y >= max_y) {
            dy = -dy;
            y += dy;
        }

        ++frame;
        if (frame % 30 == 0) {
            double elapsed = now_s() - t_start;
            printf("frame %ld, pos=(%d,%d), %.1f fps so far\n", frame, x, y, frame / elapsed);
        }
    }

    double elapsed = now_s() - t_start;
    printf("done -- %ld frames in %.1fs (%.1f fps average)%s\n", frame, elapsed,
           frame / (elapsed > 0 ? elapsed : 1), failed ? " -- STOPPED EARLY" : "");

    tool_close(link);
    return failed;
}
