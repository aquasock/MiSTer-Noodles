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
//   ./stress-demo [sprite.bmp] [count] [seconds] [mode] [batches] [sprite_px]
// mode is "sprites" (default), "sprites-batch", "blit-bench", "fixed", "overlap", "plain", "key-never", "key-all", "key-checker", "clear",
// "present", or "static". The latter
// modes isolate framebuffer clearing and PRESENT/scanout from compositing.
// batches (sprites-batch/blit-bench only, default 1, max 8) issues that many
// independent 64-descriptor CMDQ batches per frame -- purely to multiply
// compositing load for harder stress testing once 64 sprites alone no
// longer lowers fps enough to be useful.
// blit-bench issues no PRESENT at all, so unlike every other mode it is not
// capped by the 60Hz vblank-synced flip and reports the engine's real
// throughput (batches/s, sprites/s, Mpixel/s).
// sprite_px forces an exact per-side sprite size (scaling the source up or
// down on the host, since there is no scaling hardware), overriding the
// automatic coverage-based sizing -- use it to vary per-sprite blit size.

#define _POSIX_C_SOURCE 199309L
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "sdk_helpers.h"
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
        if (errno != EAGAIN) { perror("fill submission"); return 1; }
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
        if (errno != EAGAIN) { perror("copy submission"); return 1; }
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
        if (errno != EAGAIN) { perror("keyed copy submission"); return 1; }
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
        if (errno != EAGAIN) {
            perror("sprite batch submission");
            return 1;
        }
        nanosleep(&delay, NULL);
    }
    fprintf(stderr, "sprite batch submission timed out (ring full or descriptors busy)\n");
    return 1;
}

// Only EAGAIN is safe to retry; timeout does not cancel a submitted flip.
static int present_retry(noodles_link_t *link) {
    struct timespec delay = {.tv_sec = 0, .tv_nsec = PUSH_RETRY_DELAY_NS};
    for (int i = 0; i < PUSH_RETRY_ITERS; ++i) {
        int rc = noodles_present_and_wait(link);
        if (rc == 0) return 0;
        if (errno == EAGAIN) {
            nanosleep(&delay, NULL);
            continue;
        }
        perror("present");
        return 1;
    }
    return 1;
}

// Used by blit-bench to count completed work, not to protect descriptors:
// the library now owns that exclusion.
static int wait_for_fence(noodles_link_t *link, uint32_t target) {
    if (noodles_link_wait(link, target, NOODLES_DEFAULT_TIMEOUT_MS) == 0) return 0;
    perror("GPU completion");
    return -1;
}

// Diagnostic only: observes the unverified done counter so blit-bench can
// separate engine execution from SDK wait latency. Completion is still
// established by wait_for_fence afterwards.
static int trace_raw_fence(noodles_link_t *link, uint32_t target) {
    const struct timespec delay = {.tv_sec = 0, .tv_nsec = 20000};
    const double deadline = now_s() + 2.0;
    while (((noodles_link_done_count(link) - target) & 0x7fffffffu) >= 0x40000000u) {
        if (now_s() > deadline) return -1;
        nanosleep(&delay, NULL);
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *path = (argc > 1) ? argv[1] : "assets/sprite.bmp";
    int count = (argc > 2) ? atoi(argv[2]) : 10;
    double run_seconds = (argc > 3) ? atof(argv[3]) : 15.0;
    const char *mode = (argc > 4) ? argv[4] : "sprites";
    int batches = (argc > 5) ? atoi(argv[5]) : 1;
    int sprite_px = (argc > 6) ? atoi(argv[6]) : 0;  // 0 = automatic sizing
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
    // blit-bench measures raw blit throughput with no PRESENT at all.
    // Every other sprite mode issues a PRESENT per frame, and present.sv
    // synchronizes the flip to vblank, so those modes cannot report more
    // than the display's 60Hz no matter how fast the engine actually is
    // (SDR-007 measured exactly 60.375fps, i.e. pinned to the refresh).
    // This mode pushes the same descriptor batches and waits only on the
    // LINK-005 fence for the batches themselves to retire, so the number
    // it reports is the engine's real completion rate.
    int do_blit_bench = strcmp(mode, "blit-bench") == 0;
    if (do_blit_bench) {
        if (batches < 1 || batches > MAX_BATCHES) {
            fprintf(stderr, "batches must be 1-%d\n", MAX_BATCHES);
            return 1;
        }
        count = MAX_SPRITES * batches;
    }
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
    // Must leave a non-negative bounce range in both axes (max_x/max_y
    // below), which caps the sprite at the smaller buffer dimension.
    if (sprite_px != 0) {
        const int limit = (NOODLES_BUFFER_WIDTH < NOODLES_BUFFER_HEIGHT)
                              ? (int)NOODLES_BUFFER_WIDTH : (int)NOODLES_BUFFER_HEIGHT;
        if (sprite_px < 4 || sprite_px > limit) {
            fprintf(stderr, "sprite size must be 4-%d\n", limit);
            return 1;
        }
    }

    if ((!do_sprites && !do_sprites_batch && !do_fixed && !do_overlap && !do_plain && !do_key_never && !do_key_all && !do_key_checker && !do_clear &&
         !do_present_only && !do_static && !do_blit_bench) ||
        ((do_sprites || do_fixed || do_overlap || do_plain || do_key_never || do_key_all || do_key_checker) &&
         (count < 1 || count > MAX_SPRITES))) {
        fprintf(stderr, "mode must be sprites, sprites-batch, blit-bench, fixed, overlap, plain, key-never, key-all, key-checker, clear, present, or static; count 1-%d\n",
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
    // framebuffer holds, so most would occlude each other and only a
    // fraction would ever be visible at once, making "N independently
    // bouncing sprites" misleading for high counts. Downsample once on the
    // host, before upload, to keep total coverage under half the buffer.
    if ((do_sprites_batch || do_blit_bench) && batches > 1 && sprite_px == 0) {
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

    // Explicit sprite-size override (argv[6]), mainly for blit-bench: scales
    // the source to exactly this many pixels per side, UP or down. The
    // nearest-neighbor resampler handles both directions, and since
    // sprite_batch has no scaling hardware this is the only way to vary
    // per-sprite blit size. Overrides the automatic coverage-based
    // downsample above so the workload is exactly what was asked for.
    if (sprite_px > 0 && ((uint32_t)sprite_px != sprite_w || (uint32_t)sprite_px != sprite_h)) {
        uint32_t *resized = downsample_nearest(converted, sprite_w, sprite_h,
                                               (uint32_t)sprite_px, (uint32_t)sprite_px);
        if (!resized) { free(converted); return 1; }
        free(converted);
        converted = resized;
        printf("resampled sprite to %dx%d (explicit size override)\n", sprite_px, sprite_px);
        sprite_w = (uint32_t)sprite_px;
        sprite_h = (uint32_t)sprite_px;
    }

    noodles_link_t *link = NULL;
    if (tool_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        free(converted);
        return 1;
    }
    printf("startup fence=0x%08x, front parity=%u, back=0x%08x\n",
           noodles_link_done_count(link),
           noodles_link_back_buffer(link) == NOODLES_BUFFER_A_ADDR,
           noodles_link_back_buffer(link));

    uint32_t sprite_pitch = sprite_w * 4;
    size_t sprite_bytes = (size_t)sprite_h * sprite_pitch;
    if (noodles_link_upload(link, SPRITE_SRC_ADDR, converted, sprite_bytes) != 0) {
        perror("noodles_link_upload");
        free(converted);
        tool_close(link);
        return 1;
    }
    free(converted);
    printf("uploaded sprite %ux%u (%zu bytes) from %s to 0x%08x\n", sprite_w, sprite_h,
           sprite_bytes, path, SPRITE_SRC_ADDR);

    // SDR-007: sprites-batch reads its sprite source pixels back through
    // ddram_adapter/DDR3 again, so descriptors point straight at
    // SPRITE_SRC_ADDR and no DDR3->SDRAM preload is required. The
    // OP_LOAD_SDRAM opcode and sdram_loader remain implemented and
    // available; this path simply no longer needs them.

    if (sprite_w >= NOODLES_BUFFER_WIDTH || sprite_h >= NOODLES_BUFFER_HEIGHT) {
        fprintf(stderr, "sprite too large to bounce within the buffer\n");
        tool_close(link);
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
           do_blit_bench ? "raw blit throughput (no PRESENT, not vsync-capped)" :
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
        if (push_fill_retry(link, NOODLES_BUFFER_A_ADDR, NOODLES_BUFFER_PITCH,
                            NOODLES_BUFFER_WIDTH, NOODLES_BUFFER_HEIGHT, background) ||
            push_fill_retry(link, NOODLES_BUFFER_B_ADDR, NOODLES_BUFFER_PITCH,
                            NOODLES_BUFFER_WIDTH, NOODLES_BUFFER_HEIGHT,
                            noodles_rgb(0x30, 0x20, 0x10)) ||
            present_retry(link)) {
            fprintf(stderr, "present-only initialization failed\n");
            tool_close(link);
            return 1;
        }
        if (do_static) {
            if (sleep((unsigned int)run_seconds) != 0) {
                fprintf(stderr, "static observation interrupted\n");
                tool_close(link);
                return 1;
            }
            printf("done -- static frame held for %.1fs\n", run_seconds);
            tool_close(link);
            return 0;
        }
    }

    if (do_blit_bench) {
        // Pure engine throughput: no PRESENT, so nothing here is gated on
        // vblank. Draw into the back buffer only; it is never flipped to,
        // so the displayed image simply stays as-is while this runs.
        //
        // Descriptors are static across iterations (no per-frame sprite
        // motion) so that the measured rate reflects blitting alone rather
        // than host-side bookkeeping. Only ONE batch is in flight at a time,
        // waited to completion via the fence so each measured iteration is
        // a full, completed batch. The library independently protects the
        // shared descriptor table against early reuse.
        // Must be the live back buffer, not a hardcoded constant: which of
        // A/B is currently back depends on the parity the FPGA came up with.
        const uint32_t back = noodles_link_back_buffer(link);
        noodles_sprite_descriptor_t descriptors[MAX_SPRITES];
        for (int j = 0; j < MAX_SPRITES; ++j) {
            descriptors[j].dst_addr = back + (uint32_t)sprites[j].y * NOODLES_BUFFER_PITCH +
                                      (uint32_t)sprites[j].x * 4;
            descriptors[j].dst_pitch = NOODLES_BUFFER_PITCH;
            descriptors[j].width = sprite_w;
            descriptors[j].height = sprite_h;
            descriptors[j].colorkey = colorkey;
            descriptors[j].src_addr = SPRITE_SRC_ADDR;
            descriptors[j].src_pitch = sprite_pitch;
            descriptors[j].flags = 1;
        }

        // NOODLES_BENCH_TRACE=1 splits each iteration into submission,
        // engine execution (raw fence observed by a 20us poll) and the
        // remaining SDK verified wait. The trace poll itself shortens the
        // raw-fence detection delay, so traced throughput is not comparable
        // with the canonical untraced run; only the split is.
        const char *trace_env = getenv("NOODLES_BENCH_TRACE");
        const int trace = trace_env && strcmp(trace_env, "1") == 0;
        double t_submit = 0.0, t_engine = 0.0, t_verify = 0.0;

        double b_start = now_s();
        long done_batches = 0;
        int bench_failed = 0;
        while (now_s() - b_start < run_seconds) {
            for (int b = 0; b < batches; ++b) {
                const double t0 = trace ? now_s() : 0.0;
                if (push_batch_retry(link, descriptors, MAX_SPRITES)) {
                    fprintf(stderr, "blit-bench: batch submission failed\n");
                    bench_failed = 1;
                    break;
                }
                const uint32_t target = noodles_link_last_fence(link);
                if (trace) {
                    const double t1 = now_s();
                    if (trace_raw_fence(link, target)) {
                        fprintf(stderr, "blit-bench: raw fence trace timed out\n");
                        bench_failed = 1;
                        break;
                    }
                    const double t2 = now_s();
                    t_submit += t1 - t0;
                    t_engine += t2 - t1;
                    t_verify -= t2;
                }
                if (wait_for_fence(link, target)) {
                    fprintf(stderr, "blit-bench: batch never retired "
                            "(submitted=%u target=%u done=%u)\n",
                            noodles_link_submitted_count(link), target,
                            noodles_link_done_count(link));
                    bench_failed = 1;
                    break;
                }
                if (trace) t_verify += now_s();
                ++done_batches;
            }
            if (bench_failed) break;
        }

        double b_elapsed = now_s() - b_start;
        double px = (double)done_batches * MAX_SPRITES * (double)sprite_w * (double)sprite_h;
        printf("done -- %ld batches (%ld sprites, %.0f px) in %.1fs\n",
               done_batches, done_batches * MAX_SPRITES, px, b_elapsed);
        printf("  %.1f batches/s, %.1f sprites/s, %.2f Mpixel/s%s\n",
               done_batches / b_elapsed, (done_batches * (double)MAX_SPRITES) / b_elapsed,
               px / b_elapsed / 1e6, bench_failed ? " -- STOPPED EARLY" : "");
        // Equivalent frame rate at this test's own per-frame sprite count,
        // for direct comparison against the vsync-capped sprites-batch
        // number (which cannot exceed the 60Hz refresh).
        printf("  equivalent %.1f fps at %d sprites/frame\n",
               (done_batches / b_elapsed) / (double)batches, MAX_SPRITES * batches);
        if (trace && done_batches > 0) {
            printf("  trace per batch: submit %.3fms, engine %.3fms, verified wait %.3fms\n",
                   t_submit * 1e3 / done_batches, t_engine * 1e3 / done_batches,
                   t_verify * 1e3 / done_batches);
            printf("  trace engine-only rate %.2f Mpixel/s\n",
                   (double)MAX_SPRITES * sprite_w * sprite_h * done_batches / t_engine / 1e6);
        }
        tool_close(link);
        return bench_failed;
    }

    double t_start = now_s();
    long frame = 0;
    int failed = 0;
    while (now_s() - t_start < run_seconds) {
        uint32_t back = noodles_link_back_buffer(link);

        if (do_clear && push_fill_retry(link, back, NOODLES_BUFFER_PITCH, NOODLES_BUFFER_WIDTH,
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
                    descriptors[j].src_addr = SPRITE_SRC_ADDR;
                    descriptors[j].src_pitch = sprite_pitch;
                    descriptors[j].flags = 1;
                }
                if (push_batch_retry(link, descriptors, MAX_SPRITES)) {
                    fprintf(stderr, "frame %ld: sprite batch %d submission failed\n", frame, b);
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
                ? push_copy_retry(link, dst, NOODLES_BUFFER_PITCH, SPRITE_SRC_ADDR, sprite_pitch,
                                  (uint16_t)sprite_w, (uint16_t)sprite_h)
                : push_key_retry(link, dst, NOODLES_BUFFER_PITCH, SPRITE_SRC_ADDR, sprite_pitch,
                                 (uint16_t)sprite_w, (uint16_t)sprite_h, frame_key);
            if (copy_failed) {
                fprintf(stderr, "frame %ld: ring stuck compositing sprite %d\n", frame, i);
                failed = 1;
                break;
            }
        }
        if (failed) break;

        if (present_retry(link)) {
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

    tool_close(link);
    return failed ? 1 : 0;
}
