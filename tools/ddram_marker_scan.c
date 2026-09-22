// Diagnostic companion to ddram_marker_check.c: scans a range of physical
// memory for the marker word, to find out whether rtl/ddram_marker_test.sv's
// write landed somewhere other than expected rather than not happening at
// all. Defaults to SURF-003's 32MB "Core's fb" window
// (0x20000000-0x21FFFFFF); pass a different base/size to scan elsewhere,
// e.g. the kernel's actual reserved region per /proc/cmdline's memmap=.
//
// Usage, as root on the MiSTer, after pressing "Marker Test":
//   ./ddram-marker-scan [base_hex] [size_bytes_hex]

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#define DEFAULT_BASE  0x20000000u
#define DEFAULT_BYTES (32u * 1024u * 1024u)
#define MARKER_VALUE  0xDEADBEEFu

int main(int argc, char **argv) {
    uint32_t base = DEFAULT_BASE;
    uint32_t scan_bytes = DEFAULT_BYTES;
    if (argc > 1) base = (uint32_t)strtoul(argv[1], NULL, 16);
    if (argc > 2) scan_bytes = (uint32_t)strtoul(argv[2], NULL, 16);

    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem (are you root?)");
        return 1;
    }

    void *map = mmap(NULL, scan_bytes, PROT_READ, MAP_SHARED, fd, base);
    if (map == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    const volatile uint32_t *words = (const volatile uint32_t *)map;
    const uint32_t count = scan_bytes / 4;

    printf("scanning phys 0x%08x .. 0x%08x (%u bytes) for 0x%08x\n", base,
           base + scan_bytes - 1, scan_bytes, MARKER_VALUE);

    unsigned hits = 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (words[i] == MARKER_VALUE) {
            printf("  found at phys 0x%08x (offset 0x%08x from base)\n", base + i * 4,
                   i * 4);
            ++hits;
            if (hits >= 64) {
                printf("  ...stopping after 64 hits\n");
                break;
            }
        }
    }

    if (!hits) {
        printf("not found anywhere in the range.\n");
    }

    munmap((void *)map, scan_bytes);
    close(fd);
    return hits ? 0 : 1;
}
