/* Reads rtl/ddram_perf_probe.sv's passive snapshot after isolated full-screen
 * fill, copy and blend commands. Diagnostic image only. */
#define _POSIX_C_SOURCE 200809L
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "sdk_helpers.h"

#define SNAP_ADDR 0x30050000u
#define SNAP_BYTES 48u
#define SNAP_MAGIC 0x4e445046u
#define SRC_ADDR 0x31400000u
#define DST_ADDR NOODLES_BUFFER_A_ADDR
#define PITCH NOODLES_BUFFER_PITCH
#define WIDTH NOODLES_BUFFER_WIDTH
#define HEIGHT NOODLES_BUFFER_HEIGHT
#define PIXELS ((double)WIDTH * (double)HEIGHT)
#define CORE_HZ 120000000.0

typedef struct {
    uint32_t tag, cycles, command_cycles, stalled_cycles, busy_cycles;
    uint32_t idle_cycles, read_commands, read_words, read_responses;
    uint32_t write_beats, max_read_burst;
} snapshot;

static noodles_link_t *noodles;
static volatile uint32_t *words;

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec * 1e-6;
}

static int wait_snapshot(uint32_t old_tag, unsigned expected_kind, snapshot *out)
{
    const struct timespec pause = {0, 100000};
    const double deadline = now_ms() + 2000.0;
    while (now_ms() < deadline) {
        uint32_t tag_a = words[1];
        if (words[0] == SNAP_MAGIC && tag_a != old_tag &&
            (tag_a & 0xffu) == expected_kind) {
            snapshot s = {
                .tag = tag_a,
                .cycles = words[2],
                .command_cycles = words[3],
                .stalled_cycles = words[4],
                .busy_cycles = words[5],
                .idle_cycles = words[6],
                .read_commands = words[7],
                .read_words = words[8],
                .read_responses = words[9],
                .write_beats = words[10],
                .max_read_burst = words[11],
            };
            __sync_synchronize();
            if (words[1] == tag_a) {
                *out = s;
                return 0;
            }
        }
        nanosleep(&pause, NULL);
    }
    fprintf(stderr, "timed out waiting for probe snapshot kind %u\n", expected_kind);
    return -1;
}

static int finish(uint32_t old_tag, unsigned kind, snapshot *out)
{
    noodles_fence_t fence = noodles_link_last_fence(noodles);
    if (noodles_link_wait(noodles, fence, NOODLES_DEFAULT_TIMEOUT_MS) != 0) {
        perror("command wait");
        return -1;
    }
    return wait_snapshot(old_tag, kind, out);
}

static int fill(uint32_t address, uint32_t color, snapshot *out)
{
    uint32_t old_tag = words[1];
    if (noodles_push_solid_fill(noodles, address, PITCH, WIDTH, HEIGHT, color) != 0) {
        perror("fill submit");
        return -1;
    }
    return finish(old_tag, 1, out);
}

static int copy(snapshot *out)
{
    uint32_t old_tag = words[1];
    if (noodles_push_blit_copy(noodles, DST_ADDR, PITCH, SRC_ADDR, PITCH,
                               WIDTH, HEIGHT) != 0) {
        perror("copy submit");
        return -1;
    }
    return finish(old_tag, 2, out);
}

static int blend_fill(snapshot *out)
{
    uint32_t old_tag = words[1];
    if (noodles_push_blend_fill(noodles, DST_ADDR, PITCH, WIDTH, HEIGHT,
                                0x80406080u, NOODLES_DRAW_MODE_BLEND) != 0) {
        perror("blend fill submit");
        return -1;
    }
    return finish(old_tag, 3, out);
}

static int blend_copy(snapshot *out)
{
    uint32_t old_tag = words[1];
    if (noodles_push_blit_blend(noodles, DST_ADDR, PITCH, SRC_ADDR, PITCH,
                                WIDTH, HEIGHT, 255) != 0) {
        perror("blend copy submit");
        return -1;
    }
    return finish(old_tag, 3, out);
}

static void report(const char *name, const snapshot *s)
{
    double ms = (double)s->cycles / CORE_HZ * 1e3;
    double mpix = PIXELS * CORE_HZ / (double)s->cycles / 1e6;
    double avg_burst = s->read_commands ?
        (double)s->read_words / (double)s->read_commands : 0.0;
    printf("%-14s cycles=%-9u %7.3f ms %6.1f Mpix/s\n", name, s->cycles, ms, mpix);
    printf("  command=%u stall=%u (%.1f%%) idle=%u busy-any=%u\n",
           s->command_cycles, s->stalled_cycles,
           s->command_cycles ? 100.0 * s->stalled_cycles / s->command_cycles : 0.0,
           s->idle_cycles, s->busy_cycles);
    printf("  read-cmd=%u words=%u responses=%u avg-burst=%.2f max=%u write-beats=%u\n",
           s->read_commands, s->read_words, s->read_responses, avg_burst,
           s->max_read_burst, s->write_beats);
}

int main(void)
{
    int fd = -1;
    void *map = MAP_FAILED;
    snapshot s;
    int rc = EXIT_FAILURE;

    if (tool_open(&noodles) != 0) {
        perror("noodles_link_open");
        return EXIT_FAILURE;
    }
    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        goto out;
    }
    map = mmap(NULL, SNAP_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, SNAP_ADDR);
    if (map == MAP_FAILED) {
        perror("mmap probe snapshot");
        goto out;
    }
    words = (volatile uint32_t *)map;
    words[0] = 0;
    words[1] = 0;
    __sync_synchronize();

    // Seed both surfaces and consume those setup snapshots before measuring.
    if (fill(SRC_ADDR, 0x804080c0u, &s) != 0 ||
        fill(DST_ADDR, 0xff000000u, &s) != 0)
        goto out;

    if (fill(DST_ADDR, 0xff203040u, &s) != 0) goto out;
    report("solid fill", &s);
    if (copy(&s) != 0) goto out;
    report("blit copy", &s);
    if (blend_fill(&s) != 0) goto out;
    report("blend fill", &s);
    if (blend_copy(&s) != 0) goto out;
    report("blend copy", &s);

    rc = EXIT_SUCCESS;
out:
    if (map != MAP_FAILED) munmap(map, SNAP_BYTES);
    if (fd >= 0) close(fd);
    tool_close(noodles);
    return rc;
}
