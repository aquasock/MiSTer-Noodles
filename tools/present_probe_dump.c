// Temporary diagnostic (see ai/core-log.md, present-stage stutter
// investigation): reads rtl/dbg_present_probe.sv's two published words
// directly from shared DDR3 and reports the widened per-retirement
// measurements -- see that module's header comment for the exact field
// layout. Companion to tools/mem_scan.c and tools/link_slot_dump.c, same
// direct /dev/mem approach, no LINK/CMDQ involvement.
//
// A retirement sample can straddle the two-word publish (word 0 then word
// 1, not written atomically as a pair -- see dbg_present_probe.sv's header
// comment), so this tool always re-reads both words and only reports a
// sample once two consecutive reads agree on word 1's seq field, ruling
// out a read caught mid-publish.
//
// Usage, as root on the MiSTer:
//   ./present-probe-dump [sample_count] [poll_interval_ms]
// Defaults: sample_count=20 (0 = run until interrupted), poll_interval_ms=5

#define _POSIX_C_SOURCE 199309L
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define DBG_ADDR 0x30030000u
#define MAP_SPAN 0x8u

static void sleep_ms(long ms) {
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

int main(int argc, char **argv) {
    long sample_count = (argc > 1) ? strtol(argv[1], NULL, 10) : 20;
    long poll_ms = (argc > 2) ? strtol(argv[2], NULL, 10) : 5;

    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem (are you root?)");
        return 1;
    }

    void *map = mmap(NULL, MAP_SPAN, PROT_READ, MAP_SHARED, fd, DBG_ADDR);
    if (map == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    const volatile uint32_t *words = (const volatile uint32_t *)map;

    printf("polling dbg_present_probe at phys 0x%08x/0x%08x\n", DBG_ADDR, DBG_ADDR + 4);

    int last_seq_valid = 0;
    uint8_t last_seq = 0;
    long reported = 0;

    while (sample_count == 0 || reported < sample_count) {
        uint32_t w0a = words[0];
        uint32_t w1a = words[1];
        sleep_ms(poll_ms);
        uint32_t w0b = words[0];
        uint32_t w1b = words[1];

        uint8_t seq_a = (uint8_t)((w1a >> 20) & 0xFFu);
        uint8_t seq_b = (uint8_t)((w1b >> 20) & 0xFFu);
        if (w0a != w0b || seq_a != seq_b) {
            // Caught mid-publish (word 0/1 pair not yet consistent) -- skip
            // this poll and try again next interval rather than report a
            // torn sample.
            continue;
        }
        if (last_seq_valid && seq_b == last_seq) {
            // No new sample since the last report; nothing to print.
            continue;
        }

        uint32_t retire_wait_cyc = w0b;
        uint16_t missed_boundaries = (uint16_t)(w1b & 0xFFFFu);
        uint8_t read_outstanding_pk = (uint8_t)((w1b >> 16) & 0xFu);

        printf("seq=%3u  retire_wait_cyc=%10u  missed_boundaries=%5u  read_outstanding_pk=%u\n",
               seq_b, retire_wait_cyc, missed_boundaries, read_outstanding_pk);

        last_seq = seq_b;
        last_seq_valid = 1;
        ++reported;
    }

    munmap((void *)map, MAP_SPAN);
    close(fd);
    return 0;
}
