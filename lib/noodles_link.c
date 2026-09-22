// Implementation of noodles_link.h. See that header for the API contract;
// this file is just LINK-002/LINK-003's wire format (previously hand-rolled
// identically in tools/link_push.c) factored out into something reusable.

#define _POSIX_C_SOURCE 199309L
#include "noodles_link.h"

#include <fcntl.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define NOODLES_HEADER_ADDR 0x30020000u
#define NOODLES_SLOT_BASE_ADDR 0x30021000u
#define NOODLES_RING_SLOTS 64u
#define NOODLES_SLOT_WORDS 8u
#define NOODLES_MAP_SPAN 0x2000u  // covers header (+16B used) and all 64 slots (2048B)

#define NOODLES_OP_SOLID_FILL 1u
#define NOODLES_OP_BLIT_COPY 2u
#define NOODLES_OP_BLIT_COPY_KEY 3u
#define NOODLES_OP_PRESENT 4u

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
    uint32_t fence_state = link->header[3];
    link->done_baseline = fence_state & 0x7fffffffu;
    link->presents_completed = (fence_state >> 31) & 1u;

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

int noodles_push_blit_copy_key(noodles_link_t *link, uint32_t dst_addr, uint16_t dst_pitch,
                                uint32_t src_addr, uint16_t src_pitch, uint16_t width,
                                uint16_t height, uint32_t colorkey) {
    const uint32_t command[8] = {
        NOODLES_OP_BLIT_COPY_KEY, dst_addr, dst_pitch, width, height, colorkey, src_addr, src_pitch,
    };
    return noodles_push_command(link, command);
}

uint32_t noodles_link_submitted_count(const noodles_link_t *link) { return link->submitted; }

uint32_t noodles_link_done_count(const noodles_link_t *link) {
    return link->header[3] & 0x7fffffffu;
}

int noodles_present_and_wait(noodles_link_t *link) {
    const uint32_t command[8] = {NOODLES_OP_PRESENT, 0, 0, 0, 0, 0, 0, 0};
    if (noodles_push_command(link, command) != 0) return -1;  // ring full
    // This PRESENT's own position in the fence's GLOBAL numbering, not just
    // this handle's local submitted count -- done_count() never resets
    // except on a real core load, so it can already be well past any small
    // per-handle submitted value from a prior process's session. done_baseline
    // (captured at open()) converts link->submitted into the same absolute
    // space done_count() lives in. Comparing against a fixed target here
    // (rather than "done_count() advanced by any amount since a pre-push
    // sample", what this used to do) matters once other commands can be
    // in flight ahead of a present -- LINK-006's stress_demo.c pipelines
    // draws instead of fence-waiting each one, so an ordinary blit's
    // completion could otherwise satisfy a bare "advanced" check and report
    // the flip done before it actually happened, with the host then
    // drawing into the buffer still being scanned out live.
    uint32_t target = link->done_baseline + link->submitted;

    // Vblank-synced on the FPGA side (present.sv), so this can legitimately
    // take up to roughly one frame -- poll rather than a single short wait.
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 1000000};  // 1ms
    // A PRESENT may sit behind a full frame of DDRAM work before the
    // vblank-synchronized flip can complete. Keep the wait long enough for
    // that queued work plus the retirement acknowledgement; the command has
    // already been submitted, so timing out here would only make callers
    // report a false failure.
    for (int i = 0; i < 2000; ++i) {
        if (noodles_link_done_count(link) >= target) {
            link->presents_completed += 1;
            return 0;
        }
        nanosleep(&delay, NULL);
    }
    return 1;  // fence never caught up -- should not happen in practice
}

uint32_t noodles_link_back_buffer(const noodles_link_t *link) {
    return (link->presents_completed % 2 == 0) ? NOODLES_BUFFER_B_ADDR : NOODLES_BUFFER_A_ADDR;
}

int noodles_link_upload(noodles_link_t *link, uint32_t dst_addr, const void *data,
                         size_t size_bytes) {
    long page = sysconf(_SC_PAGESIZE);
    uint32_t aligned_addr = dst_addr & ~(uint32_t)(page - 1);
    size_t offset = dst_addr - aligned_addr;
    size_t map_span = offset + size_bytes;
    map_span = (map_span + (size_t)page - 1) & ~((size_t)page - 1);  // round up to a page

    void *map = mmap(NULL, map_span, PROT_WRITE, MAP_SHARED, link->fd, aligned_addr);
    if (map == MAP_FAILED) return -1;

    memcpy((char *)map + offset, data, size_bytes);

    munmap(map, map_span);
    return 0;
}
