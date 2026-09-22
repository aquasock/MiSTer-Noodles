// Pushes one command into LINK's ring buffer (LINK-002/LINK-003) -- the
// first real host-driven path this project has: no OSD button, just an ARM
// process writing directly into shared DDR3 via /dev/mem, exactly as
// LINK-001 always intended, in place of the OSD test triggers that were
// always meant to be temporary scaffolding.
//
// Default command is SOLID_FILL of the same visible 64x64 surface
// (0x30000000, pitch 256) the OSD "Draw Test" button fills, but a
// different color (cyan, not magenta) -- so success is visually
// unambiguous: cyan means the FPGA picked this up via the ring, not the
// leftover OSD path.
//
// Usage, as root on the MiSTer:
//   ./link_push
//
// This never touches DDRAM_ADDR/DDRAM_* directly -- it only writes to
// shared DDR3 the same way any host process would, via mmap of /dev/mem.

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define HEADER_ADDR 0x30020000u
#define SLOT_BASE_ADDR 0x30021000u
#define RING_SLOTS 64u
#define SLOT_BYTES 32u
#define MAP_SPAN 0x2000u  // covers header (+16B used) and all 64 slots (2048B)

#define OP_SOLID_FILL 1u

int main(void) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem (are you root?)");
        return 1;
    }

    void *map = mmap(NULL, MAP_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, HEADER_ADDR);
    if (map == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    volatile uint32_t *header = (volatile uint32_t *)map;
    volatile uint32_t *slots = (volatile uint32_t *)((char *)map + (SLOT_BASE_ADDR - HEADER_ADDR));

    uint32_t write_ptr = header[0];
    uint32_t read_ptr = header[2];  // +8 bytes = index 2 of a uint32_t array
    uint32_t next_write_ptr = (write_ptr + 1) % RING_SLOTS;

    if (next_write_ptr == read_ptr) {
        fprintf(stderr, "ring full (write_ptr=%u read_ptr=%u) -- refusing to push\n", write_ptr,
                read_ptr);
        munmap(map, MAP_SPAN);
        close(fd);
        return 1;
    }

    const uint32_t command[8] = {
        OP_SOLID_FILL,  // opcode
        0x30000000u,    // dst_addr
        256,            // dst_pitch
        64,             // width
        64,             // height
        0x0000FFFFu,    // color: cyan
        0,              // reserved0 / src_addr (unused for SOLID_FILL)
        0,              // reserved1 / src_pitch (unused for SOLID_FILL)
    };

    volatile uint32_t *slot = slots + write_ptr * (SLOT_BYTES / 4);
    for (int i = 0; i < 8; ++i) slot[i] = command[i];

    header[0] = next_write_ptr;  // publish: FPGA can now see and fetch it

    printf("pushed SOLID_FILL (cyan) into slot %u; write_ptr %u -> %u (read_ptr currently %u)\n",
           write_ptr, write_ptr, next_write_ptr, read_ptr);

    munmap(map, MAP_SPAN);
    close(fd);
    return 0;
}
