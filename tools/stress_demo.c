// Stress test: N independently-bouncing copies of a single loaded sprite
// asset, all composited into the same frame, continuously. sprite_demo.c
// proved one sprite driven as a real game loop; this multiplies the
// per-frame command count (background clear + N colorkey blits + present)
// to find out whether the ring buffer, the completion fence, and present's
// vblank sync hold up under sustained multi-sprite load, not just a single
// sprite.
//
// The sprite art itself is real decoded pixel data (LINK-006), loaded once
// via noodles_bmp_load()/noodles_link_upload() -- not built from SOLID_FILLs
// like sprite_demo.c's sprite was. Default asset is assets/sprite.bmp (a
// 48x48 magenta-colorkeyed smiley), overridable via argv.
//
// Commands are PIPELINED, not fence-waited one at a time: LINK-003's
// dispatch already processes the ring strictly in FIFO order, so there is
// no correctness reason to wait for a blit to finish before pushing the
// next one -- only LINK-002's 63-outstanding-command ring capacity forces
// a wait, and only once the ring is actually full. An earlier version
// fence-waited after every single push (1 + count + 1 waits per frame);
// at count=64 that serialized 66 host-side round trips per frame and
// measured 10fps, stable but far below what the hardware itself can do.
// Pushing without waiting and only blocking on an actual ring-full is
// the fix -- see core-log.md for the before/after numbers.
//
// Usage, as root on the MiSTer:
//   ./stress-demo [sprite.bmp] [count] [seconds] [mode]
// mode is "sprites" (default), "plain", "key-never", "key-all", "key-checker", "clear",
// "present", or "static". The latter
// modes isolate framebuffer clearing and PRESENT/scanout from compositing.

#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

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

// Retries a push until the ring has room (returns 0) or 2s pass with no
// progress (returns 1, meaning something is actually stuck, not just busy).
#define PUSH_RETRY_ITERS 20000
#define PUSH_RETRY_DELAY_NS 100000  // 0.1ms

static int push_fill_retry(noodles_link_t *link, uint32_t dst, uint16_t pitch, uint16_t w,
                            uint16_t h, uint32_t color) {
    struct timespec delay = {.tv_sec = 0, .tv_nsec = PUSH_RETRY_DELAY_NS};
    for (int i = 0; i < PUSH_RETRY_ITERS; ++i) {
        if (noodles_push_solid_fill(link, dst, pitch, w, h, color) == 0) return 0;
        nanosleep(&delay, NULL);
    }
    return 1;
}

static int push_copy_retry(noodles_link_t *link, uint32_t dst, uint16_t dst_pitch, uint32_t src,
                           uint16_t src_pitch, uint16_t w, uint16_t h) {
    struct timespec delay = {.tv_sec = 0, .tv_nsec = PUSH_RETRY_DELAY_NS};
    for (int i = 0; i < PUSH_RETRY_ITERS; ++i) {
        if (noodles_push_blit_copy(link, dst, dst_pitch, src, src_pitch, w, h) == 0)
            return 0;
        nanosleep(&delay, NULL);
    }
    return 1;
}

static int push_key_retry(noodles_link_t *link, uint32_t dst, uint16_t dst_pitch, uint32_t src,
                           uint16_t src_pitch, uint16_t w, uint16_t h, uint32_t colorkey) {
    struct timespec delay = {.tv_sec = 0, .tv_nsec = PUSH_RETRY_DELAY_NS};
    for (int i = 0; i < PUSH_RETRY_ITERS; ++i) {
        if (noodles_push_blit_copy_key(link, dst, dst_pitch, src, src_pitch, w, h, colorkey) == 0)
            return 0;
        nanosleep(&delay, NULL);
    }
    return 1;
}

// noodles_present_and_wait() returns -1 on ring-full (LINK-004's documented,
// non-retrying contract) -- with this file's own commands pipelined ahead
// of it, the ring can genuinely still be full of undrained draws at the
// moment PRESENT is pushed, so -1 here means "try again shortly", not
// failure. A 1 return (pushed fine, fence never caught up) is a real
// problem and stays fatal.
static int present_retry(noodles_link_t *link) {
    struct timespec delay = {.tv_sec = 0, .tv_nsec = PUSH_RETRY_DELAY_NS};
    for (int i = 0; i < PUSH_RETRY_ITERS; ++i) {
        int rc = noodles_present_and_wait(link);
        if (rc == 0) return 0;
        if (rc == -1) {
            nanosleep(&delay, NULL);
            continue;
        }
        return 1;
    }
    return 1;
}

int main(int argc, char **argv) {
    const char *path = (argc > 1) ? argv[1] : "assets/sprite.bmp";
    int count = (argc > 2) ? atoi(argv[2]) : 10;
    double run_seconds = (argc > 3) ? atof(argv[3]) : 15.0;
    const char *mode = (argc > 4) ? argv[4] : "sprites";
    int do_sprites = strcmp(mode, "sprites") == 0;
    int do_plain = strcmp(mode, "plain") == 0;
    int do_key_never = strcmp(mode, "key-never") == 0;
    int do_key_all = strcmp(mode, "key-all") == 0;
    int do_key_checker = strcmp(mode, "key-checker") == 0;
    int do_clear = do_sprites || do_plain || strcmp(mode, "clear") == 0;
    int do_present_only = strcmp(mode, "present") == 0;
    int do_static = strcmp(mode, "static") == 0;

    if ((!do_sprites && !do_plain && !do_key_never && !do_key_all && !do_key_checker && !do_clear &&
         !do_present_only && !do_static) ||
        ((do_sprites || do_plain || do_key_never || do_key_all || do_key_checker) &&
         (count < 1 || count > MAX_SPRITES))) {
        fprintf(stderr, "mode must be sprites, plain, key-never, key-all, key-checker, clear, present, or static; count 1-%d\n",
                MAX_SPRITES);
        return 1;
    }

    uint32_t sprite_w, sprite_h;
    uint32_t *converted = noodles_bmp_load(path, &sprite_w, &sprite_h);
    if (!converted) return 1;
    if (do_key_all) {
        uint32_t key_pixel = noodles_rgb(COLORKEY_R, COLORKEY_G, COLORKEY_B);
        for (size_t i = 0; i < (size_t)sprite_w * sprite_h; ++i)
            converted[i] = key_pixel;
    } else if (do_key_checker) {
        uint32_t key_pixel = noodles_rgb(COLORKEY_R, COLORKEY_G, COLORKEY_B);
        uint32_t draw_pixel = noodles_rgb(0xFF, 0xA0, 0x20);
        for (uint32_t y = 0; y < sprite_h; ++y) {
            for (uint32_t x = 0; x < sprite_w; ++x) {
                converted[(size_t)y * sprite_w + x] =
                    ((x ^ y) & 1u) ? key_pixel : draw_pixel;
            }
        }
    }

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

    printf("mode=%s, %s for %.1fs...\n", mode,
           do_sprites ? "bouncing sprites" : do_plain ? "plain copies" :
                        do_key_never ? "key copies (never match)" :
                        do_key_all ? "key copies (always match)" :
                        do_key_checker ? "key copies (checkerboard)" :
                        do_clear ? "clearing back buffer" :
                        do_static ? "one PRESENT then idle" : "presenting prefilled buffers",
           run_seconds);

    if (do_present_only || do_static) {
        // Populate both surfaces while output is still blank, then establish
        // a known initial front/back relationship before presenting only.
        if (push_fill_retry(&link, NOODLES_BUFFER_A_ADDR, NOODLES_BUFFER_PITCH,
                            NOODLES_BUFFER_WIDTH, NOODLES_BUFFER_HEIGHT, background) ||
            push_fill_retry(&link, NOODLES_BUFFER_B_ADDR, NOODLES_BUFFER_PITCH,
                            NOODLES_BUFFER_WIDTH, NOODLES_BUFFER_HEIGHT,
                            noodles_rgb(0x30, 0x20, 0x10)) ||
            present_retry(&link)) {
            fprintf(stderr, "present-only initialization failed\n");
            noodles_link_close(&link);
            return 1;
        }
        if (do_static) {
            if (sleep((unsigned int)run_seconds) != 0) {
                fprintf(stderr, "static observation interrupted\n");
                noodles_link_close(&link);
                return 1;
            }
            printf("done -- static frame held for %.1fs\n", run_seconds);
            noodles_link_close(&link);
            return 0;
        }
    }

    double t_start = now_s();
    long frame = 0;
    int failed = 0;
    while (now_s() - t_start < run_seconds) {
        uint32_t back = noodles_link_back_buffer(&link);

        if (do_clear && push_fill_retry(&link, back, NOODLES_BUFFER_PITCH, NOODLES_BUFFER_WIDTH,
                             NOODLES_BUFFER_HEIGHT, background)) {
            fprintf(stderr, "frame %ld: ring stuck clearing background\n", frame);
            failed = 1;
            break;
        }

        for (int i = 0; (do_sprites || do_plain || do_key_never || do_key_all ||
                         do_key_checker) && i < count; ++i) {
            uint32_t dst = back + (uint32_t)sprites[i].y * NOODLES_BUFFER_PITCH +
                            (uint32_t)sprites[i].x * 4;
            uint32_t frame_key = do_key_never ? 0xFFFFFFFFu : colorkey;
            int copy_failed = do_plain
                ? push_copy_retry(&link, dst, NOODLES_BUFFER_PITCH, SPRITE_SRC_ADDR, sprite_pitch,
                                  (uint16_t)sprite_w, (uint16_t)sprite_h)
                : push_key_retry(&link, dst, NOODLES_BUFFER_PITCH, SPRITE_SRC_ADDR, sprite_pitch,
                                 (uint16_t)sprite_w, (uint16_t)sprite_h, frame_key);
            if (copy_failed) {
                fprintf(stderr, "frame %ld: ring stuck compositing sprite %d\n", frame, i);
                failed = 1;
                break;
            }
        }
        if (failed) break;

        if (present_retry(&link)) {
            fprintf(stderr, "frame %ld: present failed\n", frame);
            failed = 1;
            break;
        }

        for (int i = 0; (do_sprites || do_plain || do_key_never || do_key_all ||
                         do_key_checker) && i < count; ++i) {
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
