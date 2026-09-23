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
//   ./stress-demo [sprite.bmp] [count] [seconds] [mode] [batches]
// mode is "sprites" (default), "sprites-batch", "fixed", "overlap", "plain", "key-never", "key-all", "key-checker", "clear",
// "present", or "static". The latter
// modes isolate framebuffer clearing and PRESENT/scanout from compositing.
// batches (sprites-batch mode only, default 1, max 8) issues that many
// independent 64-descriptor CMDQ batches per frame -- purely to multiply
// compositing load for harder stress testing once 64 sprites alone no
// longer lowers fps enough to be useful.

#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "../lib/noodles_link.h"
#include "bmp_loader.h"

// Integer sqrt (Newton's method), just enough precision for the sprite
// downsample sizing below -- no need to pull in <math.h>/libm for one call.
static uint32_t isqrt32(uint64_t v) {
    if (v == 0) return 0;
    uint64_t x = v, y = (x + 1) / 2;
    while (y < x) { x = y; y = (x + v / x) / 2; }
    return (uint32_t)x;
}

// Nearest-neighbor downsample: sprite_batch's copy engines have no scaling
// hardware, so shrinking a sprite for a high-count stress run has to happen
// on the host, once, before upload -- not per-frame.
static uint32_t *downsample_nearest(const uint32_t *src, uint32_t src_w, uint32_t src_h,
                                     uint32_t dst_w, uint32_t dst_h) {
    uint32_t *dst = malloc((size_t)dst_w * dst_h * sizeof(uint32_t));
    if (!dst) return NULL;
    for (uint32_t y = 0; y < dst_h; ++y) {
        uint32_t sy = (y * src_h) / dst_h;
        for (uint32_t x = 0; x < dst_w; ++x) {
            uint32_t sx = (x * src_w) / dst_w;
            dst[(size_t)y * dst_w + x] = src[(size_t)sy * src_w + sx];
        }
    }
    return dst;
}

#define SPRITE_SRC_ADDR 0x31400000u
// SDR-004 (step 5b): sprites-batch mode's sprite pixel data is loaded into
// SDRAM (via OP_LOAD_SDRAM) and read from there by sprite_batch's
// blit_copy64 engine (see rtl/sdram_adapter.sv) -- a separate, FPGA-only
// 128MB address space from DDR3, not to be confused with SPRITE_SRC_ADDR
// above (still used as the DDR3 staging address noodles_link_upload()
// writes the decoded bitmap to before the FPGA-side copy runs). Page 0,
// already page-aligned as sdram_loader.sv's dst_addr requires.
#define SDRAM_SPRITE_ADDR 0x00000000u
#define MAX_SPRITES 64
// sprites-batch can issue more than one 64-descriptor CMDQ batch per frame
// (BATCHES > 1) purely to multiply compositing load for stress testing --
// SPRITE_BATCH's hardware descriptor buffer itself is still capped at 64
// per push (RTL enforces count<=64), so this just repeats the push.
#define MAX_BATCHES 8
#define MAX_BATCH_SPRITES (MAX_SPRITES * MAX_BATCHES)
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

static int push_batch_retry(noodles_link_t *link,
                            const noodles_sprite_descriptor_t *descriptors,
                            uint16_t count) {
    struct timespec delay = {.tv_sec = 0, .tv_nsec = PUSH_RETRY_DELAY_NS};
    for (int i = 0; i < PUSH_RETRY_ITERS; ++i) {
        if (noodles_push_sprite_batch(link, descriptors, count) == 0) return 0;
        nanosleep(&delay, NULL);
    }
    return 1;
}

static int push_load_sdram_retry(noodles_link_t *link, uint32_t sdram_dst,
                                  uint32_t ddr3_src, uint32_t length) {
    struct timespec delay = {.tv_sec = 0, .tv_nsec = PUSH_RETRY_DELAY_NS};
    for (int i = 0; i < PUSH_RETRY_ITERS; ++i) {
        if (noodles_push_load_sdram(link, sdram_dst, ddr3_src, length) == 0) return 0;
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

// sprite_batch's descriptor table lives at one fixed DRAM address (RTL:
// "the descriptor address is deliberately fixed in sprite_batch") -- there
// is no per-command base address to point separate batches at separate
// buffers. noodles_push_sprite_batch() uploads there directly and returns
// as soon as the ring accepts the SPRITE_BATCH command, without waiting for
// the hardware to actually finish consuming those descriptors. With more
// than one batch pushed per frame this is a real race: overwriting the
// descriptor table for batch N+1 before batch N's SPRITE_BATCH has
// actually executed silently corrupts batch N's in-flight positions with
// batch N+1's, which is exactly what made 4 batches/frame look like only
// 64 distinct sprites moving (in lockstep groups of ~4) instead of 256
// independent ones. Fence-wait on LINK-005's completion count after each
// batch push, before touching the descriptor table again.
static int wait_for_fence(noodles_link_t *link, uint32_t target) {
    struct timespec delay = {.tv_sec = 0, .tv_nsec = PUSH_RETRY_DELAY_NS};
    for (int i = 0; i < PUSH_RETRY_ITERS; ++i) {
        if ((int32_t)(noodles_link_done_count(link) - target) >= 0) return 0;
        nanosleep(&delay, NULL);
    }
    return 1;
}

int main(int argc, char **argv) {
    const char *path = (argc > 1) ? argv[1] : "assets/sprite.bmp";
    int count = (argc > 2) ? atoi(argv[2]) : 10;
    double run_seconds = (argc > 3) ? atof(argv[3]) : 15.0;
    const char *mode = (argc > 4) ? argv[4] : "sprites";
    int batches = (argc > 5) ? atoi(argv[5]) : 1;
    int do_sprites = strcmp(mode, "sprites") == 0;
    int do_sprites_batch = strcmp(mode, "sprites-batch") == 0;
    int do_fixed = strcmp(mode, "fixed") == 0;
    int do_overlap = strcmp(mode, "overlap") == 0;
    int do_plain = strcmp(mode, "plain") == 0;
    int do_key_never = strcmp(mode, "key-never") == 0;
    int do_key_all = strcmp(mode, "key-all") == 0;
    int do_key_checker = strcmp(mode, "key-checker") == 0;
    int do_clear = do_sprites || do_sprites_batch || do_fixed || do_overlap || do_plain || strcmp(mode, "clear") == 0;
    int do_present_only = strcmp(mode, "present") == 0;
    int do_static = strcmp(mode, "static") == 0;
    // sprites-batch is intentionally the full approved 64-entry workload
    // per batch; its descriptor upload is 2 KiB at the reserved address
    // after the ring. `batches` multiplies how many independent 64-entry
    // pushes happen per frame for harder stress testing.
    if (do_sprites_batch) {
        if (batches < 1 || batches > MAX_BATCHES) {
            fprintf(stderr, "batches must be 1-%d\n", MAX_BATCHES);
            return 1;
        }
        count = MAX_SPRITES * batches;
    }

    if ((!do_sprites && !do_sprites_batch && !do_fixed && !do_overlap && !do_plain && !do_key_never && !do_key_all && !do_key_checker && !do_clear &&
         !do_present_only && !do_static) ||
        ((do_sprites || do_fixed || do_overlap || do_plain || do_key_never || do_key_all || do_key_checker) &&
         (count < 1 || count > MAX_SPRITES))) {
        fprintf(stderr, "mode must be sprites, sprites-batch, fixed, overlap, plain, key-never, key-all, key-checker, clear, present, or static; count 1-%d\n",
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

    // sprite_batch's copy engines have no scaling hardware -- at full 48x48
    // size, count sprites (up to 256 at batches=4) cover more area than the
    // 640x480 buffer holds, so most would occlude each other and only a
    // fraction would ever be visible at once, making "N independently
    // bouncing sprites" misleading for high counts. Downsample once on the
    // host, before upload, to keep total coverage under half the buffer.
    if (do_sprites_batch && batches > 1) {
        const uint64_t buffer_area = (uint64_t)NOODLES_BUFFER_WIDTH * NOODLES_BUFFER_HEIGHT;
        const uint32_t target_side = isqrt32((buffer_area / 2) / (uint64_t)count);
        uint32_t new_w = target_side < sprite_w ? target_side : sprite_w;
        uint32_t new_h = target_side < sprite_h ? target_side : sprite_h;
        if (new_w < 8) new_w = 8;
        if (new_h < 8) new_h = 8;
        if (new_w != sprite_w || new_h != sprite_h) {
            uint32_t *resized = downsample_nearest(converted, sprite_w, sprite_h, new_w, new_h);
            if (!resized) { free(converted); return 1; }
            free(converted);
            converted = resized;
            printf("downsampled sprite from source size to %ux%u so %d sprites fit without heavy overlap\n",
                   new_w, new_h, count);
            sprite_w = new_w;
            sprite_h = new_h;
        }
    }

    noodles_link_t link;
    if (noodles_link_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        free(converted);
        return 1;
    }
    printf("startup fence=0x%08x, front parity=%u, back=0x%08x\n",
           link.header[3], link.presents_completed,
           noodles_link_back_buffer(&link));

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

    // SDR-004 (step 5b): sprites-batch mode reads its sprite source pixels
    // via sdram_adapter now, not ddram_adapter -- so the bitmap must
    // actually be copied into SDRAM before any batch descriptor points at
    // SDRAM_SPRITE_ADDR. length is rounded up to whole 1KB pages
    // internally by sdram_loader.sv; no explicit host-side wait is needed
    // beyond this push succeeding: CMDQ's WAIT_DONE state (cmdq.sv) blocks
    // the ring from dispatching the FOLLOWING sprites-batch command until
    // this load has actually finished, so hardware ordering alone
    // guarantees the copy is complete before any read against it.
    if (do_sprites_batch) {
        if (push_load_sdram_retry(&link, SDRAM_SPRITE_ADDR, SPRITE_SRC_ADDR,
                                   (uint32_t)sprite_bytes)) {
            fprintf(stderr, "ring stuck pushing OP_LOAD_SDRAM\n");
            noodles_link_close(&link);
            return 1;
        }
        printf("queued DDR3->SDRAM load of %zu bytes to SDRAM window 0x%08x\n",
               sprite_bytes, SDRAM_SPRITE_ADDR);
    }

    if (sprite_w >= NOODLES_BUFFER_WIDTH || sprite_h >= NOODLES_BUFFER_HEIGHT) {
        fprintf(stderr, "sprite too large to bounce within the buffer\n");
        noodles_link_close(&link);
        return 1;
    }

    const int max_x = (int)NOODLES_BUFFER_WIDTH - (int)sprite_w;
    const int max_y = (int)NOODLES_BUFFER_HEIGHT - (int)sprite_h;

    sprite_state_t sprites[MAX_BATCH_SPRITES];
    srand((unsigned)time(NULL));
    for (int i = 0; i < count; ++i) {
        sprites[i].x = rand() % (max_x + 1);
        sprites[i].y = rand() % (max_y + 1);
        sprites[i].dx = (4 + rand() % 9) * ((rand() % 2) ? 1 : -1);
        sprites[i].dy = (4 + rand() % 9) * ((rand() % 2) ? 1 : -1);
    }
    if (do_fixed || do_overlap) {
        static const int fixed_x[] = {80, 240, 400, 560, 80, 240, 400, 560};
        static const int fixed_y[] = {80, 80, 80, 80, 320, 320, 320, 320};
        for (int i = 0; i < count; ++i) {
            sprites[i].x = do_overlap ? 280 + (i % 4) * 24 : fixed_x[i % 8];
            sprites[i].y = do_overlap ? 200 + (i / 4) * 24 : fixed_y[i % 8];
            sprites[i].dx = 0;
            sprites[i].dy = 0;
        }
    }

    uint32_t colorkey = noodles_rgb(COLORKEY_R, COLORKEY_G, COLORKEY_B);
    uint32_t background = noodles_rgb(BG_COLOR_R, BG_COLOR_G, BG_COLOR_B);

    printf("mode=%s, %s for %.1fs...\n", mode,
           do_sprites ? "bouncing sprites" : do_sprites_batch ? (batches == 1 ? "64-sprite descriptor batches" : "multi-batch descriptor stress") :
           do_fixed ? "fixed sprites" :
                        do_overlap ? "fixed overlapping sprites" :
                        do_plain ? "plain copies" :
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

        if (do_sprites_batch) {
            noodles_sprite_descriptor_t descriptors[MAX_SPRITES];
            for (int b = 0; b < batches; ++b) {
                for (int j = 0; j < MAX_SPRITES; ++j) {
                    const int i = b * MAX_SPRITES + j;
                    descriptors[j].dst_addr = back + (uint32_t)sprites[i].y * NOODLES_BUFFER_PITCH +
                                              (uint32_t)sprites[i].x * 4;
                    descriptors[j].dst_pitch = NOODLES_BUFFER_PITCH;
                    descriptors[j].width = sprite_w;
                    descriptors[j].height = sprite_h;
                    descriptors[j].colorkey = colorkey;
                    descriptors[j].src_addr = SDRAM_SPRITE_ADDR;
                    descriptors[j].src_pitch = sprite_pitch;
                    descriptors[j].flags = 1;
                }
                if (push_batch_retry(&link, descriptors, MAX_SPRITES)) {
                    fprintf(stderr, "frame %ld: ring stuck uploading sprite batch %d\n", frame, b);
                    failed = 1;
                    break;
                }
                // Must not overwrite the (single, fixed-address) descriptor
                // table with the next batch's positions until this one has
                // actually finished executing -- see wait_for_fence()'s
                // comment for why.
                const uint32_t target = link.done_baseline + link.submitted;
                if (wait_for_fence(&link, target)) {
                    fprintf(stderr, "frame %ld: sprite batch %d never completed\n", frame, b);
                    failed = 1;
                    break;
                }
            }
            if (failed) break;
        }

        for (int i = 0; (!do_sprites_batch && (do_sprites || do_fixed || do_overlap || do_plain || do_key_never || do_key_all ||
                         do_key_checker)) && i < count; ++i) {
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

        for (int i = 0; (do_sprites || do_sprites_batch || do_fixed || do_overlap || do_plain || do_key_never || do_key_all ||
                         do_key_checker) && i < count; ++i) {
            if (do_fixed || do_overlap) continue;
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
