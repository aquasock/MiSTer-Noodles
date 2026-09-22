// Benchmarks the real LINK-001 command path: pushes a batch of identical
// commands back to back, times from the first push to LINK-005's fence
// confirming the last one actually finished, and reports commands/sec and
// pixels/sec. This is the end-to-end number a real host program would see
// -- ring dispatch, FPGA execution, and fence publish all included, not an
// idealized FPGA-only figure.
//
// A small size isolates roughly-fixed per-command overhead (link_ring's
// poll/fetch/dispatch cycle, 8 sequential DDR3 reads per command per
// LINK-003); a large size is dominated by per-pixel engine cost. Copy and
// colorkeyed-copy use a colorkey that never matches, so every pixel is
// written -- the worst-case, fairest comparison against SOLID_FILL and
// plain BLIT_COPY.
//
// Usage, as root on the MiSTer:
//   ./bench

#define _POSIX_C_SOURCE 199309L
#include <stdint.h>
#include <stdio.h>
#include <time.h>

#include "../lib/noodles_link.h"

#define VISIBLE_ADDR 0x30000000u
#define SRC_ADDR 0x30010000u
#define PITCH 256

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static int wait_fence_at_least(noodles_link_t *link, uint32_t target) {
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 200000};  // 0.2ms
    for (int i = 0; i < 50000; ++i) {
        if (noodles_link_done_count(link) >= target) return 0;
        nanosleep(&delay, NULL);
    }
    return 1;
}

typedef enum { OP_FILL, OP_COPY, OP_COPY_KEY } op_t;

static void run_bench(noodles_link_t *link, const char *label, op_t op, uint16_t w, uint16_t h,
                       int n) {
    uint32_t color = noodles_rgb(0x11, 0x22, 0x33);
    uint32_t colorkey = 0xFFFFFFFFu;  // never matches source content below

    uint32_t start_done = noodles_link_done_count(link);
    double t0 = now_s();

    for (int i = 0; i < n; ++i) {
        int rc;
        do {
            switch (op) {
                case OP_FILL:
                    rc = noodles_push_solid_fill(link, VISIBLE_ADDR, PITCH, w, h, color);
                    break;
                case OP_COPY:
                    rc = noodles_push_blit_copy(link, VISIBLE_ADDR, PITCH, SRC_ADDR, PITCH, w, h);
                    break;
                default:
                    rc = noodles_push_blit_copy_key(link, VISIBLE_ADDR, PITCH, SRC_ADDR, PITCH, w,
                                                     h, colorkey);
                    break;
            }
        } while (rc != 0);  // ring full -- retry once the FPGA has drained a slot
    }

    if (wait_fence_at_least(link, start_done + (uint32_t)n)) {
        printf("%-28s FAILED (fence never caught up)\n", label);
        return;
    }
    double elapsed = now_s() - t0;

    double cmds_per_sec = (double)n / elapsed;
    double pixels_per_sec = (double)n * w * h / elapsed;
    double us_per_cmd = elapsed * 1e6 / n;

    printf("%-28s n=%-4d %4ux%-4u  %8.1f us/cmd  %10.0f cmd/s  %12.0f px/s\n", label, n, w, h,
           us_per_cmd, cmds_per_sec, pixels_per_sec);
}

int main(void) {
    noodles_link_t link;
    if (noodles_link_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        return 1;
    }

    // Give BLIT_COPY/BLIT_COPY_KEY a valid, fully-written source region
    // before timing anything against it.
    uint32_t before = noodles_link_done_count(&link);
    while (noodles_push_solid_fill(&link, SRC_ADDR, PITCH, 64, 64,
                                    noodles_rgb(0x44, 0x55, 0x66)) != 0) {
    }
    wait_fence_at_least(&link, before + 1);

    printf("%-28s %-9s %-11s %-12s %-12s %-12s\n", "test", "count", "size", "latency",
           "throughput", "pixel rate");

    run_bench(&link, "SOLID_FILL (fixed cost)", OP_FILL, 1, 1, 500);
    run_bench(&link, "SOLID_FILL", OP_FILL, 8, 8, 300);
    run_bench(&link, "SOLID_FILL", OP_FILL, 32, 32, 100);
    run_bench(&link, "SOLID_FILL", OP_FILL, 64, 64, 50);

    run_bench(&link, "BLIT_COPY", OP_COPY, 8, 8, 300);
    run_bench(&link, "BLIT_COPY", OP_COPY, 32, 32, 100);
    run_bench(&link, "BLIT_COPY", OP_COPY, 64, 64, 50);

    run_bench(&link, "BLIT_COPY_KEY (no skips)", OP_COPY_KEY, 32, 32, 100);
    run_bench(&link, "BLIT_COPY_KEY (no skips)", OP_COPY_KEY, 64, 64, 50);

    noodles_link_close(&link);
    return 0;
}
