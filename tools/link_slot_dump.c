// Diagnostic: dumps LINK's header (write_ptr, read_ptr) and one ring slot's
// raw 8 words directly from shared DDR3, bypassing the FPGA's own
// reconstruction entirely. Used to tell apart "the host wrote the command
// wrong" from "link_ring read/reassembled it wrong" when a link-pushed
// command visibly starts BLIT (LED_USER) but writes no pixels and still
// completes (LED_DISK) -- see LINK-001/LINK-002/LINK-003 and
// blit.sv's width!=0&&height!=0 IDLE guard.
//
// Usage, as root on the MiSTer:
//   ./link_slot_dump [slot_index]

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdlib.h>

#define HEADER_ADDR 0x30020000u
#define SLOT_BASE_ADDR 0x30021000u
#define SLOT_BYTES 32u
#define MAP_SPAN 0x2000u

int main(int argc, char **argv) {
    unsigned slot_index = (argc > 1) ? (unsigned)strtoul(argv[1], NULL, 0) : 0u;

    int fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem (are you root?)");
        return 1;
    }

    void *map = mmap(NULL, MAP_SPAN, PROT_READ, MAP_SHARED, fd, HEADER_ADDR);
    if (map == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    volatile uint32_t *header = (volatile uint32_t *)map;
    volatile uint32_t *slots = (volatile uint32_t *)((char *)map + (SLOT_BASE_ADDR - HEADER_ADDR));

    printf("write_ptr (header[0]): %u\n", header[0]);
    printf("read_ptr  (header[2]): %u\n", header[2]);

    volatile uint32_t *slot = slots + slot_index * (SLOT_BYTES / 4);
    static const char *names[8] = {
        "opcode", "dst_addr", "dst_pitch", "width", "height", "color", "src_addr", "src_pitch"
    };
    printf("slot %u raw words:\n", slot_index);
    for (int i = 0; i < 8; ++i) {
        printf("  [%d] %-9s = 0x%08x (%u)\n", i, names[i], slot[i], slot[i]);
    }

    munmap(map, MAP_SPAN);
    close(fd);
    return 0;
}
