// Diagnostic: scans a range of physical memory for an arbitrary 32-bit
// value, given on the command line. Generalizes ddram_marker_scan.c (which
// is hardcoded to 0xDEADBEEF for the marker test specifically) -- this one
// was written to hunt down a link_ring bug where a link-pushed SOLID_FILL
// visibly started and completed on CMDQ/BLIT (per LED diagnostics) but the
// fill color never appeared at the expected destination address. Scanning
// wider ranges for the fill color itself (rather than checking one fixed
// address) is what proved the write wasn't silently landing somewhere else
// nearby, which in turn pointed at dst_addr itself being wrong before ever
// reaching BLIT -- see LINK-002/LINK-003 and link_ring.sv's rd_active port.
//
// Usage, as root on the MiSTer:
//   ./mem_scan [base_hex] [size_bytes_hex] [target_value_hex]
// Defaults: base=0x30000000, size=0x100000 (1MB), target=0x0000ffff

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv) {
    uint32_t base = (argc > 1) ? (uint32_t)strtoul(argv[1], NULL, 16) : 0x30000000u;
    uint32_t scan_bytes = (argc > 2) ? (uint32_t)strtoul(argv[2], NULL, 16) : 0x00100000u;
    uint32_t target = (argc > 3) ? (uint32_t)strtoul(argv[3], NULL, 16) : 0x0000ffffu;

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

    printf("scanning phys 0x%08x .. 0x%08x for 0x%08x\n", base, base + scan_bytes - 1, target);
    unsigned hits = 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (words[i] == target) {
            printf("  found at phys 0x%08x\n", base + i * 4);
            if (++hits >= 32) {
                printf("  ...stopping after 32 hits\n");
                break;
            }
        }
    }
    if (!hits) printf("not found in range.\n");

    munmap((void *)map, scan_bytes);
    close(fd);
    return hits ? 0 : 1;
}
