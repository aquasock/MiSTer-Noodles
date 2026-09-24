// Implementation of noodles_link.h. See that header for the API contract;
// this file is just LINK-002/LINK-003's wire format (previously hand-rolled
// identically in tools/link_push.c) factored out into something reusable.

#define _POSIX_C_SOURCE 200809L
#include "noodles_link_internal.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <sys/file.h>
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
#define NOODLES_OP_SPRITE_BATCH 5u
#define NOODLES_OP_LOAD_SDRAM 6u
#define NOODLES_FENCE_MASK 0x7fffffffu

static int fail(int error) {
    errno = error;
    return -1;
}

static int healthy(const noodles_link_t *link) {
    if (!link) return fail(EINVAL);
    if (link->fault) return fail(link->fault);
    return 0;
}

static int mark_session(noodles_link_t *link, char state) {
    ssize_t written = pwrite(link->lock_fd, &state, 1, 0);
    if (written < 0) return -1;
    if (written != 1) return fail(EIO);
    return fsync(link->lock_fd);
}

int noodles_link_open_legacy(noodles_link_t **out, int ack_reload) {
    if (!out) return fail(EINVAL);
    *out = NULL;
    if (ack_reload != 0 && ack_reload != 1) return fail(EINVAL);
    noodles_link_t *link = calloc(1, sizeof(*link));
    if (!link) return -1;
    link->fd = link->lock_fd = -1;
    link->lock_fd = open("/run/noodles.lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (link->lock_fd < 0) goto failed;
    if (flock(link->lock_fd, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EWOULDBLOCK) errno = EBUSY;
        goto failed;
    }
    char state = 0;
    ssize_t got = pread(link->lock_fd, &state, 1, 0);
    if (got < 0) goto failed;
    if (got && state != 'C' && !ack_reload) {
        errno = EOWNERDEAD;
        goto failed;
    }

    link->fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);
    if (link->fd < 0) goto failed;

    link->map = mmap(NULL, NOODLES_MAP_SPAN, PROT_READ | PROT_WRITE, MAP_SHARED, link->fd,
                      NOODLES_HEADER_ADDR);
    if (link->map == MAP_FAILED) {
        goto failed;
    }

    link->map_span = NOODLES_MAP_SPAN;
    link->header = (volatile uint32_t *)link->map;
    link->slots =
        (volatile uint32_t *)((char *)link->map + (NOODLES_SLOT_BASE_ADDR - NOODLES_HEADER_ADDR));
    link->write_ptr = link->header[0];  // sync with whatever is already published
    uint32_t fence_state = link->header[3];
    link->done_baseline = fence_state & 0x7fffffffu;
    link->presents_completed = (fence_state >> 31) & 1u;
    if (link->write_ptr >= NOODLES_RING_SLOTS || link->header[2] >= NOODLES_RING_SLOTS) {
        errno = EPROTO;
        goto failed;
    }
    if (link->write_ptr != link->header[2]) {
        errno = EBUSY;
        goto failed;
    }
    /* Empty ring cannot prove idle on the legacy core: caller must guarantee it. */
    if (mark_session(link, 'D') != 0) goto failed;
    *out = link;
    return 0;
failed: {
    int saved = errno;
    if (link->map && link->map != MAP_FAILED) munmap(link->map, NOODLES_MAP_SPAN);
    if (link->fd >= 0) close(link->fd);
    if (link->lock_fd >= 0) close(link->lock_fd);
    free(link);
    return fail(saved);
}
}

int noodles_link_close(noodles_link_t *link, uint32_t timeout_ms) {
    if (!link) return fail(EINVAL);
    int error = noodles_link_drain(link, timeout_ms) == 0 ? 0 : errno;
    if (munmap(link->map, link->map_span) != 0 && !error) error = errno;
    if (close(link->fd) != 0 && !error) error = errno;
    if (!error && mark_session(link, 'C') != 0) {
        error = errno;
        /* Best effort to retain dirty state if persisting clean state failed. */
        if (mark_session(link, 'D') != 0) error = errno;
    }
    if (close(link->lock_fd) != 0 && !error) error = errno;
    free(link);
    return error ? fail(error) : 0;
}

int noodles_link_get_info(const noodles_link_t *link, noodles_device_info_t *info) {
    if (healthy(link) != 0) return -1;
    if (!info) return fail(EINVAL);
    *info = (noodles_device_info_t){NOODLES_BUFFER_WIDTH, NOODLES_BUFFER_HEIGHT,
        NOODLES_BUFFER_PITCH, 0x7eu, 0, NOODLES_SDK_VERSION};
    return 0;
}

uint32_t noodles_rgb(uint8_t r, uint8_t g, uint8_t b) {
    return (uint32_t)r | ((uint32_t)g << 8) | ((uint32_t)b << 16);
}

int noodles_link_fence_reached(const noodles_link_t *link, uint32_t target) {
    return ((noodles_link_done_count(link) - target) & NOODLES_FENCE_MASK) < 0x40000000u;
}

noodles_fence_t noodles_link_last_fence(const noodles_link_t *link) {
    return (link->done_baseline + link->submitted) & NOODLES_FENCE_MASK;
}

int noodles_link_poll(noodles_link_t *link, noodles_fence_t target, int *complete) {
    if (healthy(link) != 0) return -1;
    if (!complete) return fail(EINVAL);
    __sync_synchronize();
    *complete = noodles_link_fence_reached(link, target);
    if (link->present_pending && noodles_link_fence_reached(link, link->present_fence)) {
        link->presents_completed = (link->header[3] >> 31) & 1u;
        link->present_pending = 0;
    }
    return 0;
}

static int monotonic_ns(uint64_t *value) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) return -1;
    *value = (uint64_t)time.tv_sec * 1000000000u + (uint64_t)time.tv_nsec;
    return 0;
}

int noodles_link_wait(noodles_link_t *link, noodles_fence_t target, uint32_t timeout_ms) {
    if (healthy(link) != 0) return -1;
    uint64_t start, now;
    if (monotonic_ns(&start) != 0) { link->fault = errno; return -1; }
    uint64_t deadline = start + (uint64_t)timeout_ms * 1000000u;
    for (;;) {
        int complete;
        if (noodles_link_poll(link, target, &complete) != 0) return -1;
        if (complete) return 0;
        if (monotonic_ns(&now) != 0) { link->fault = errno; return -1; }
        if (now >= deadline) {
            link->fault = ETIMEDOUT;
            return fail(ETIMEDOUT);
        }
        uint64_t remaining = deadline - now;
        struct timespec pause = {0, remaining < 1000000u ? (long)remaining : 1000000};
        if (nanosleep(&pause, NULL) != 0 && errno != EINTR) {
            link->fault = errno;
            return -1;
        }
    }
}

int noodles_link_drain(noodles_link_t *link, uint32_t timeout_ms) {
    if (healthy(link) != 0) return -1;
    return noodles_link_wait(link, noodles_link_last_fence(link), timeout_ms);
}

static int submission_ready(noodles_link_t *link) {
    if (healthy(link) != 0) return -1;
    return link->present_pending ? fail(EAGAIN) : 0;
}

static int valid_span(uint32_t address, uint64_t bytes) {
    uint64_t end = (uint64_t)address + bytes;
    return bytes && address >= 0x30000000u && end <= 0x40000000ull &&
        !(address < 0x30022800u && end > 0x30020000u);
}

static int valid_rect(uint32_t address, uint32_t pitch, uint32_t width, uint32_t height) {
    return width && height && width <= 65535 && height <= 65535 &&
        pitch <= 65535 && !(pitch & 3) && !(address & 3) &&
        pitch >= (uint64_t)width * 4 &&
        valid_span(address, (uint64_t)(height - 1) * pitch + (uint64_t)width * 4);
}

static int valid_command(const uint32_t *c) {
    if (!c) return 0;
    switch (c[0]) {
    case NOODLES_OP_SOLID_FILL:
        return !c[6] && !c[7] && valid_rect(c[1], c[2], c[3], c[4]);
    case NOODLES_OP_BLIT_COPY:
    case NOODLES_OP_BLIT_COPY_KEY:
        return (c[0] != NOODLES_OP_BLIT_COPY || !c[5]) &&
            valid_rect(c[1], c[2], c[3], c[4]) && valid_rect(c[6], c[7], c[3], c[4]);
    case NOODLES_OP_PRESENT:
        return !(c[1] | c[2] | c[3] | c[4] | c[5] | c[6] | c[7]);
    case NOODLES_OP_SPRITE_BATCH:
        return c[1] == NOODLES_SPRITE_DESCRIPTOR_ADDR && c[3] >= 1 &&
            c[3] <= NOODLES_SPRITE_DESCRIPTOR_MAX && !(c[2] | c[4] | c[5] | c[6] | c[7]);
    case NOODLES_OP_LOAD_SDRAM: {
        uint64_t length = ((uint64_t)c[5] + 1023) & ~1023ull;
        return !(c[2] | c[3] | c[4] | c[7]) && c[5] &&
            !(c[1] & 1023) && !(c[6] & 7) &&
            (uint64_t)c[1] + length <= NOODLES_SDRAM_WINDOW_BYTES && valid_span(c[6], length);
    }
    default: return 0;
    }
}

static int descriptors_available(noodles_link_t *link) {
    if (link->batch_pending) {
        if (!noodles_link_fence_reached(link, link->batch_fence)) {
            errno = EAGAIN;
            return 0;
        }
        __sync_synchronize();
        link->batch_pending = 0;
    }
    return 1;
}

static int ring_has_space(const noodles_link_t *link) {
    if ((link->write_ptr + 1) % NOODLES_RING_SLOTS == link->header[2]) {
        errno = EAGAIN;
        return 0;
    }
    return 1;
}

int noodles_push_command(noodles_link_t *link, const uint32_t command[8]) {
    if (submission_ready(link) != 0) return -1;
    if (!valid_command(command)) {
        errno = EINVAL;
        return -1;
    }
    int is_batch = (command[0] & 0xffu) == NOODLES_OP_SPRITE_BATCH;
    // Reap completed ownership on every push, including long runs of non-batch work.
    int available = descriptors_available(link);
    if ((is_batch && !available) || !ring_has_space(link)) return -1;
    uint32_t next_write_ptr = (link->write_ptr + 1) % NOODLES_RING_SLOTS;

    volatile uint32_t *slot = link->slots + link->write_ptr * NOODLES_SLOT_WORDS;
    for (unsigned i = 0; i < NOODLES_SLOT_WORDS; ++i) slot[i] = command[i];

    __sync_synchronize();  // descriptor and slot writes must precede publication
    link->header[0] = next_write_ptr;  // publish: FPGA can now see and fetch it
    link->write_ptr = next_write_ptr;
    link->submitted += 1;
    if (is_batch) {
        link->batch_fence = (link->done_baseline + link->submitted) & NOODLES_FENCE_MASK;
        link->batch_pending = 1;
    }
    if (command[0] == NOODLES_OP_PRESENT) {
        link->present_fence = noodles_link_last_fence(link);
        link->present_pending = 1;
    }
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

int noodles_push_sprite_batch(noodles_link_t *link,
                              const noodles_sprite_descriptor_t *descriptors,
                              uint16_t count) {
    if (submission_ready(link) != 0) return -1;
    if (!descriptors || count == 0 || count > NOODLES_SPRITE_DESCRIPTOR_MAX) {
        errno = EINVAL;
        return -1;
    }
    for (unsigned i = 0; i < count; ++i) {
        const noodles_sprite_descriptor_t *d = descriptors + i;
        if (d->flags > 1 || !valid_rect(d->dst_addr, d->dst_pitch, d->width, d->height) ||
            !valid_rect(d->src_addr, d->src_pitch, d->width, d->height)) return fail(EINVAL);
    }
    if (!descriptors_available(link) || !ring_has_space(link)) return -1;
    if (noodles_link_upload(link, NOODLES_SPRITE_DESCRIPTOR_ADDR, descriptors,
                             (size_t)count * sizeof(*descriptors)) != 0) return -1;
    const uint32_t command[8] = {
        NOODLES_OP_SPRITE_BATCH, NOODLES_SPRITE_DESCRIPTOR_ADDR, 0, count, 0, 0, 0, 0,
    };
    return noodles_push_command(link, command);
}

int noodles_push_load_sdram(noodles_link_t *link, uint32_t sdram_dst_addr,
                             uint32_t ddr3_src_addr, uint32_t length) {
    // cmdq.sv's OP_LOAD_SDRAM decode reuses dst_addr/src_addr/color as
    // SDRAM dest/DDR3 src/byte length respectively (see cmdq.sv's own
    // header comment) -- dst_pitch/width/height are unused for this
    // opcode.
    const uint32_t command[8] = {
        NOODLES_OP_LOAD_SDRAM, sdram_dst_addr, 0, 0, 0, length, ddr3_src_addr, 0,
    };
    return noodles_push_command(link, command);
}

uint32_t noodles_link_submitted_count(const noodles_link_t *link) { return link->submitted; }

uint32_t noodles_link_done_count(const noodles_link_t *link) {
    return link->header[3] & 0x7fffffffu;
}

int noodles_push_present(noodles_link_t *link, noodles_fence_t *fence) {
    if (!fence) return fail(EINVAL);
    const uint32_t command[8] = {NOODLES_OP_PRESENT, 0, 0, 0, 0, 0, 0, 0};
    if (noodles_push_command(link, command) != 0) return -1;
    *fence = noodles_link_last_fence(link);
    return 0;
}

int noodles_present_and_wait(noodles_link_t *link) {
    noodles_fence_t fence;
    if (noodles_push_present(link, &fence) != 0) return -1;
    return noodles_link_wait(link, fence, NOODLES_DEFAULT_TIMEOUT_MS);
}

uint32_t noodles_link_back_buffer(const noodles_link_t *link) {
    return (link->presents_completed % 2 == 0) ? NOODLES_BUFFER_B_ADDR : NOODLES_BUFFER_A_ADDR;
}

int noodles_link_upload(noodles_link_t *link, uint32_t dst_addr, const void *data,
                         size_t size_bytes) {
    if (submission_ready(link) != 0) return -1;
    const uint32_t descriptor_end = NOODLES_SPRITE_DESCRIPTOR_ADDR +
        NOODLES_SPRITE_DESCRIPTOR_MAX * sizeof(noodles_sprite_descriptor_t);
    if (size_bytes && dst_addr < descriptor_end &&
        (dst_addr >= NOODLES_SPRITE_DESCRIPTOR_ADDR ||
         size_bytes > NOODLES_SPRITE_DESCRIPTOR_ADDR - dst_addr) &&
        !descriptors_available(link)) return -1;
    uint64_t end = (uint64_t)dst_addr + size_bytes;
    int descriptor_upload = dst_addr >= NOODLES_SPRITE_DESCRIPTOR_ADDR && end <= descriptor_end;
    if (!data || !size_bytes || size_bytes > UINT32_MAX ||
        (!descriptor_upload && !valid_span(dst_addr, size_bytes))) return fail(EINVAL);
    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0 || (page & (page - 1))) return fail(EIO);
    uint32_t aligned_addr = dst_addr & ~(uint32_t)(page - 1);
    size_t offset = dst_addr - aligned_addr;
    size_t map_span = offset + size_bytes;
    map_span = (map_span + (size_t)page - 1) & ~((size_t)page - 1);  // round up to a page

    void *map = mmap(NULL, map_span, PROT_WRITE, MAP_SHARED, link->fd, aligned_addr);
    if (map == MAP_FAILED) return -1;

    memcpy((char *)map + offset, data, size_bytes);
    __sync_synchronize();

    return munmap(map, map_span);
}
