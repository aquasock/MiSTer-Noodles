// Stress test: N independently-bouncing copies of a single loaded sprite
// asset, all composited into the same frame, continuously. sprite_demo.c
// proved one sprite driven as a real game loop; this multiplies the
// per-frame command count (background clear + N colorkey blits + present,
// all fence-waited in sequence like every other demo here) to find out
// whether the ring buffer, the completion fence, and present's vblank sync
// hold up under sustained multi-sprite load, not just a single sprite.
//
// The sprite art itself is real decoded pixel data (LINK-006), loaded once
// via noodles_bmp_load()/noodles_link_upload() -- not built from SOLID_FILLs
// like sprite_demo.c's sprite was. Default asset is assets/sprite.bmp (a
// 48x48 magenta-colorkeyed smiley), overridable via argv.
//
// Usage, as root on the MiSTer:
//   ./stress_demo [sprite.bmp] [count] [seconds]

#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "../lib/noodles_link.h"
#include "bmp_loader.h"

#define SPRITE_SRC_ADDR 0x31400000u
#define MAX_SPRITES 64
#define COLORKEY_R 0xFF
#define COLORKEY_G 0x00
#define COLORKEY_B 0xFF
#define BG_COLOR_R 0x20
#define BG_COLOR_G 0x30
#define BG_COLOR_B 0x40

typedef struct {
    int x, y;
    int dx, dy;
} sprite_state_t;

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static int wait_fence(noodles_link_t *link, uint32_t done_before, const char *what) {
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 500000};  // 0.5ms
    for (int i = 0; i < 4000; ++i) {
        if (noodles_link_done_count(link) > done_before) return 0;
        nanosleep(&delay, NULL);
    }
    fprintf(stderr, "%s: fence never caught up\n", what);
    return 1;
}

int main(int argc, char **argv) {
    const char *path = (argc > 1) ? argv[1] : "assets/sprite.bmp";
    int count = (argc > 2) ? atoi(argv[2]) : 10;
    double run_seconds = (argc > 3) ? atof(argv[3]) : 15.0;

    if (count < 1 || count > MAX_SPRITES) {
        fprintf(stderr, "count must be between 1 and %d\n", MAX_SPRITES);
        return 1;
    }

    uint32_t sprite_w, sprite_h;
    uint32_t *converted = noodles_bmp_load(path, &sprite_w, &sprite_h);
    if (!converted) return 1;

    noodles_link_t link;
    if (noodles_link_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        free(converted);
        return 1;
    }

    uint32_t sprite_pitch = sprite_w * 4;
    size_t sprite_bytes = (size_t)sprite_h * sprite_pitch;
    if (noodles_link_upload(&link, SPRITE_SRC_ADDR, converted, sprite_bytes) != 0) {
        perror("noodles_link_upload");
        free(converted);
        noodles_link_close(&link);
        return 1;
    }
    free(converted);
    printf("uploaded sprite %ux%u (%zu bytes) from %s to 0x%08x\n", sprite_w, sprite_h,
           sprite_bytes, path, SPRITE_SRC_ADDR);

    if (sprite_w >= NOODLES_BUFFER_WIDTH || sprite_h >= NOODLES_BUFFER_HEIGHT) {
        fprintf(stderr, "sprite too large to bounce within the buffer\n");
        noodles_link_close(&link);
        return 1;
    }

    const int max_x = (int)NOODLES_BUFFER_WIDTH - (int)sprite_w;
    const int max_y = (int)NOODLES_BUFFER_HEIGHT - (int)sprite_h;

    sprite_state_t sprites[MAX_SPRITES];
    srand((unsigned)time(NULL));
    for (int i = 0; i < count; ++i) {
        sprites[i].x = rand() % (max_x + 1);
        sprites[i].y = rand() % (max_y + 1);
        sprites[i].dx = (4 + rand() % 9) * ((rand() % 2) ? 1 : -1);
        sprites[i].dy = (4 + rand() % 9) * ((rand() % 2) ? 1 : -1);
    }

    uint32_t colorkey = noodles_rgb(COLORKEY_R, COLORKEY_G, COLORKEY_B);
    uint32_t background = noodles_rgb(BG_COLOR_R, BG_COLOR_G, BG_COLOR_B);

    printf("bouncing %d sprites around %ux%u for %.1fs...\n", count, NOODLES_BUFFER_WIDTH,
           NOODLES_BUFFER_HEIGHT, run_seconds);

    double t_start = now_s();
    long frame = 0;
    int failed = 0;
    while (now_s() - t_start < run_seconds) {
        uint32_t back = noodles_link_back_buffer(&link);

        uint32_t done_before = noodles_link_done_count(&link);
        if (noodles_push_solid_fill(&link, back, NOODLES_BUFFER_PITCH, NOODLES_BUFFER_WIDTH,
                                     NOODLES_BUFFER_HEIGHT, background) != 0) {
            fprintf(stderr, "frame %ld: ring full clearing background\n", frame);
            failed = 1;
            break;
        }
        if (wait_fence(&link, done_before, "background clear")) {
            failed = 1;
            break;
        }

        for (int i = 0; i < count; ++i) {
            done_before = noodles_link_done_count(&link);
            uint32_t dst = back + (uint32_t)sprites[i].y * NOODLES_BUFFER_PITCH +
                            (uint32_t)sprites[i].x * 4;
            if (noodles_push_blit_copy_key(&link, dst, NOODLES_BUFFER_PITCH, SPRITE_SRC_ADDR,
                                            sprite_pitch, (uint16_t)sprite_w, (uint16_t)sprite_h,
                                            colorkey) != 0) {
                fprintf(stderr, "frame %ld: ring full compositing sprite %d\n", frame, i);
                failed = 1;
                break;
            }
            if (wait_fence(&link, done_before, "sprite composite")) {
                failed = 1;
                break;
            }
        }
        if (failed) break;

        if (noodles_present_and_wait(&link) != 0) {
            fprintf(stderr, "frame %ld: present failed\n", frame);
            failed = 1;
            break;
        }

        for (int i = 0; i < count; ++i) {
            sprites[i].x += sprites[i].dx;
            sprites[i].y += sprites[i].dy;
            if (sprites[i].x <= 0 || sprites[i].x >= max_x) {
                sprites[i].dx = -sprites[i].dx;
                sprites[i].x += sprites[i].dx;
            }
            if (sprites[i].y <= 0 || sprites[i].y >= max_y) {
                sprites[i].dy = -sprites[i].dy;
                sprites[i].y += sprites[i].dy;
            }
        }

        ++frame;
        if (frame % 30 == 0) {
            double elapsed = now_s() - t_start;
            printf("frame %ld, %.1f fps so far\n", frame, frame / elapsed);
        }
    }

    double elapsed = now_s() - t_start;
    printf("done -- %ld frames in %.1fs (%.1f fps average)%s\n", frame, elapsed,
           frame / (elapsed > 0 ? elapsed : 1), failed ? " -- STOPPED EARLY" : "");

    noodles_link_close(&link);
    return failed ? 1 : 0;
}
