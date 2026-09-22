// Checks DDR-002's hypothesis: that a write the FPGA makes to DDRAM_ADDR=0
// (via rtl/ddram_marker_test.sv, fired once from the "Marker Test" OSD
// option) lands at Linux physical address 0x20000000 -- the start of the
// FPGA-reserved DDR3 window Main_MiSTer's own source uses (SURF-003).
//
// Usage, as root on the MiSTer, after pressing "Marker Test" in the OSD:
//   ./ddram_marker_check
//
// This only reads physical memory; it never writes. Run it as many times
// as you like -- it can't make the result worse.

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

#define FPGA_MEM_BASE 0x20000000u
#define MARKER_VALUE  0xDEADBEEFu

int main(void) {
    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem (are you root?)");
        return 1;
    }

    long page = sysconf(_SC_PAGESIZE);
    void *map = mmap(NULL, (size_t)page, PROT_READ, MAP_SHARED, fd, FPGA_MEM_BASE);
    if (map == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    volatile uint32_t *word = (volatile uint32_t *)map;
    uint32_t got = *word;

    printf("phys 0x%08x: 0x%08x\n", FPGA_MEM_BASE, got);
    int ok = (got == MARKER_VALUE);
    if (ok) {
        printf("PASS: marker found -- DDRAM_ADDR=0 is physical 0x%08x (DDR-002 confirmed)\n",
               FPGA_MEM_BASE);
    } else {
        printf("NO MATCH (expected 0x%08x): either \"Marker Test\" wasn't pressed yet on the\n"
               "loaded core, or DDR-002's address mapping is wrong.\n",
               MARKER_VALUE);
    }

    munmap(map, (size_t)page);
    close(fd);
    return ok ? 0 : 1;
}
