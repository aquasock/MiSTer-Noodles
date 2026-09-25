/* Bounded BLIT_COPY completion diagnostic for the real LINK and DDRAM path.
 *
 * Each command is waited independently so a failure reports the exact
 * rectangle, repetition, submitted fence and last completed fence. The
 * sequence starts with the smallest operation that exposed the 120MHz
 * unowned-read defect, then reaches the full 800x600 throughput workload.
 */

#define _POSIX_C_SOURCE 199309L
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "sdk_helpers.h"

#define DST_ADDR NOODLES_BUFFER_A_ADDR
#define SRC_ADDR 0x31400000u
#define PITCH NOODLES_BUFFER_PITCH

typedef struct {
    uint16_t width, height;
    uint32_t src_offset, dst_offset;
    unsigned repetitions;
} copy_case;

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec * 1e-6;
}

static int run_case(noodles_link_t *link, const copy_case *test)
{
    const double start = now_ms();

    for (unsigned i = 0; i < test->repetitions; ++i) {
        if (noodles_push_blit_copy(link, DST_ADDR + test->dst_offset, PITCH,
                                   SRC_ADDR + test->src_offset, PITCH,
                                   test->width, test->height) != 0) {
            fprintf(stderr,
                    "FAIL submit %ux%u src+%u dst+%u repetition %u/%u: "
                    "last=%u done=%u: ",
                    test->width, test->height, test->src_offset,
                    test->dst_offset, i + 1, test->repetitions,
                    noodles_link_last_fence(link),
                    noodles_link_done_count(link));
            perror("BLIT_COPY");
            return -1;
        }

        const noodles_fence_t fence = noodles_link_last_fence(link);
        if (noodles_link_wait(link, fence, NOODLES_DEFAULT_TIMEOUT_MS) != 0) {
            fprintf(stderr,
                    "FAIL wait %ux%u src+%u dst+%u repetition %u/%u: "
                    "fence=%u done=%u: ",
                    test->width, test->height, test->src_offset,
                    test->dst_offset, i + 1, test->repetitions, fence,
                    noodles_link_done_count(link));
            perror("BLIT_COPY");
            return -1;
        }
    }

    const double elapsed = now_ms() - start;
    printf("PASS %3ux%-3u src+%-2u dst+%-2u x%-3u fence=%u done=%u %.3f ms/op\n",
           test->width, test->height, test->src_offset, test->dst_offset,
           test->repetitions, noodles_link_last_fence(link),
           noodles_link_done_count(link), elapsed / test->repetitions);
    return 0;
}

int main(void)
{
    static const copy_case cases[] = {
        {1,   1,   0, 0, 32},
        {8,   8,   0, 0, 32},
        {8,   8,   4, 4, 32},
        {32,  32,  0, 0, 16},
        {64,  64,  0, 0, 8},
        {320, 240, 0, 0, 4},
        {800, 600, 0, 0, 3},
    };
    noodles_link_t *link = NULL;

    if (tool_open(&link) != 0) {
        perror("noodles_link_open");
        return EXIT_FAILURE;
    }

    if (noodles_push_solid_fill(link, SRC_ADDR, PITCH,
                                NOODLES_BUFFER_WIDTH, NOODLES_BUFFER_HEIGHT,
                                noodles_rgb(0x41, 0x82, 0xc3)) != 0 ||
        tool_wait(link, "source initialization") != 0) {
        tool_close(link);
        return EXIT_FAILURE;
    }

    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        if (run_case(link, &cases[i]) != 0) {
            (void)noodles_link_close(link, NOODLES_DEFAULT_TIMEOUT_MS);
            return EXIT_FAILURE;
        }
    }

    tool_close(link);
    return EXIT_SUCCESS;
}
