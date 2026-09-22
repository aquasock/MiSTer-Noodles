// Implementation of noodles_link.h. See that header for the API contract;
// this file is just LINK-002/LINK-003's wire format (previously hand-rolled
// identically in tools/link_push.c) factored out into something reusable.

#include "noodles_link.h"

#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define NOODLES_HEADER_ADDR 0x30020000u
#define NOODLES_SLOT_BASE_ADDR 0x30021000u
#define NOODLES_RING_SLOTS 64u
#define NOODLES_SLOT_WORDS 8u
#define NOODLES_MAP_SPAN 0x2000u  // covers header (+16B used) and all 64 slots (2048B)

#define NOODLES_OP_SOLID_FILL 1u
#define NOODLES_OP_BLIT_COPY 2u

int noodles_link_open(noodles_link_t *link) {
    memset(link, 0, sizeof(*link));

    link->fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (link->fd < 0) return -1;

    link->map = mmap(NULL, NOODLES_MAP_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, link->fd,
                      NOODLES_HEADER_ADDR);
    if (link->map == MAP_FAILED) {
        close(link->fd);
        link->fd = -1;
        return -1;
    }

    link->map_span = NOODLES_MAP_SPAN;
    link->header = (volatile uint32_t *)link->map;
    link->slots =
        (volatile uint32_t *)((char *)link->map + (NOODLES_SLOT_BASE_ADDR - NOODLES_HEADER_ADDR));
    link->write_ptr = link->header[0];  // sync with whatever is already published

    return 0;
}

void noodles_link_close(noodles_link_t *link) {
    if (link->map && link->map != MAP_FAILED) munmap(link->map, link->map_span);
    if (link->fd >= 0) close(link->fd);
    memset(link, 0, sizeof(*link));
    link->fd = -1;
}

uint32_t noodles_rgb(uint8_t r, uint8_t g, uint8_t b) {
    return (uint32_t)r | ((uint32_t)g << 8) | ((uint32_t)b << 16);
}

int noodles_push_command(noodles_link_t *link, const uint32_t command[8]) {
    uint32_t read_ptr = link->header[2];  // +8 bytes = index 2 of a uint32_t array
    uint32_t next_write_ptr = (link->write_ptr + 1) % NOODLES_RING_SLOTS;
    if (next_write_ptr == read_ptr) return -1;  // ring full

    volatile uint32_t *slot = link->slots + link->write_ptr * NOODLES_SLOT_WORDS;
    for (unsigned i = 0; i < NOODLES_SLOT_WORDS; ++i) slot[i] = command[i];

    link->header[0] = next_write_ptr;  // publish: FPGA can now see and fetch it
    link->write_ptr = next_write_ptr;
    link->submitted += 1;
    return 0;
}

int noodles_push_solid_fill(noodles_link_t *link, uint32_t dst_addr, uint16_t dst_pitch,
                             uint16_t width, uint16_t height, uint32_t color) {
    const uint32_t command[8] = {
        NOODLES_OP_SOLID_FILL, dst_addr, dst_pitch, width, height, color, 0, 0,
    };
    return noodles_push_command(link, command);
}

int noodles_push_blit_copy(noodles_link_t *link, uint32_t dst_addr, uint16_t dst_pitch,
                            uint32_t src_addr, uint16_t src_pitch, uint16_t width,
                            uint16_t height) {
    const uint32_t command[8] = {
        NOODLES_OP_BLIT_COPY, dst_addr, dst_pitch, width, height, 0, src_addr, src_pitch,
    };
    return noodles_push_command(link, command);
}

uint32_t noodles_link_submitted_count(const noodles_link_t *link) { return link->submitted; }

uint32_t noodles_link_done_count(const noodles_link_t *link) {
    return link->header[3];  // +12 bytes = index 3 of a uint32_t array
}
