#define _POSIX_C_SOURCE 200809L
#include "../lib/noodles_link_internal.h"

#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>

static uint32_t header[4], slots[64 * 8];
static unsigned char memory[8192];
static int maps, fail_map;
static noodles_link_t link;
static noodles_sprite_descriptor_t descriptors[NOODLES_SPRITE_DESCRIPTOR_MAX];

static void test_framebuffer_geometry(void) {
    assert(NOODLES_BUFFER_WIDTH == 800 && NOODLES_BUFFER_HEIGHT == 600);
    assert(NOODLES_BUFFER_PITCH == NOODLES_BUFFER_WIDTH * sizeof(uint32_t));
    uint32_t bytes = NOODLES_BUFFER_PITCH * NOODLES_BUFFER_HEIGHT;
    assert(bytes == 1920000u && bytes <= 0x200000u);
    assert(NOODLES_BUFFER_A_ADDR + bytes <= NOODLES_BUFFER_B_ADDR);
    assert(NOODLES_BUFFER_B_ADDR + bytes <= 0x31400000u);
}

void *__wrap_mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    ++maps;
    if (fail_map) {
        errno = ENOMEM;
        return MAP_FAILED;
    }
    assert(length <= sizeof(memory));
    return memory;
}

int __wrap_munmap(void *addr, size_t length) {
    assert(addr == memory);
    return 0;
}

static void reset(uint32_t baseline) {
    memset(&link, 0, sizeof(link));
    memset(header, 0, sizeof(header));
    memset(slots, 0, sizeof(slots));
    memset(memory, 0xa5, sizeof(memory));
    for (unsigned i = 0; i < NOODLES_SPRITE_DESCRIPTOR_MAX; ++i)
        descriptors[i] = (noodles_sprite_descriptor_t){
            NOODLES_BUFFER_B_ADDR, 3200, 1, 1, 0, 0x31400000u, 4, 0};
    maps = fail_map = 0;
    header[3] = baseline;
    link.header = header;
    link.slots = slots;
    link.done_baseline = baseline & 0x7fffffffu;
    link.capabilities = 0x7eu;  /* legacy opcode set: no BLIT_BLEND */
}

static void rejected(int expected_errno, uint16_t count) {
    unsigned char before[sizeof(memory)];
    uint32_t before_slots[64 * 8], before_header[4];
    memcpy(before, memory, sizeof(memory));
    memcpy(before_slots, slots, sizeof(slots));
    memcpy(before_header, header, sizeof(header));
    uint32_t submitted = link.submitted, ptr = link.write_ptr;
    int before_maps = maps;
    errno = 0;
    assert(noodles_push_sprite_batch(&link, descriptors, count) == -1);
    assert(errno == expected_errno);
    assert(maps == before_maps);
    assert(memcmp(before, memory, sizeof(memory)) == 0);
    assert(memcmp(before_slots, slots, sizeof(slots)) == 0);
    assert(memcmp(before_header, header, sizeof(header)) == 0);
    assert(link.submitted == submitted && link.write_ptr == ptr);
}

int main(void) {
    test_framebuffer_geometry();
    const uint32_t fill[8] = {1, NOODLES_BUFFER_B_ADDR, 3200, 1, 1, 0, 0, 0};
    const uint32_t batch[8] = {5, NOODLES_SPRITE_DESCRIPTOR_ADDR, 0, 1, 0, 0, 0, 0};
    reset(100);
    assert(noodles_push_command(&link, fill) == 0);
    assert(noodles_push_sprite_batch(&link, descriptors, 64) == 0);
    assert(maps == 1 && link.batch_pending && link.batch_fence == 102);
    assert(memcmp(memory, descriptors, sizeof(descriptors)) == 0);
    assert(header[0] == 2 && slots[8] == 5 && slots[11] == 64);
    for (unsigned i = 0; i < NOODLES_SPRITE_DESCRIPTOR_MAX; ++i)
        descriptors[i].colorkey = 0x7e7e7e7eu;
    rejected(EAGAIN, 64);
    header[2] = header[0];  // fetched is not completed
    header[3] = 0x80000065u;  // only the preceding fill retired; parity must be ignored
    rejected(EAGAIN, 64);
    assert(noodles_push_command(&link, batch) == -1 && errno == EAGAIN);
    assert(noodles_push_command(&link, fill) == 0);  // unrelated work may pipeline
    assert(link.batch_fence == 102);

    int before_maps = maps;
    assert(noodles_link_upload(&link, NOODLES_SPRITE_DESCRIPTOR_ADDR, descriptors, 32) == -1);
    assert(errno == EAGAIN);
    assert(noodles_link_upload(&link, NOODLES_SPRITE_DESCRIPTOR_ADDR - 16, descriptors, 32) == -1);
    assert(errno == EAGAIN);
    assert(noodles_link_upload(&link, NOODLES_SPRITE_DESCRIPTOR_ADDR + 2047, descriptors, 1) == -1);
    assert(errno == EAGAIN && maps == before_maps);

    header[3] = 0x80000066u;
    assert(noodles_push_sprite_batch(&link, descriptors, 1) == 0);
    assert(link.batch_fence == 104 && link.batch_pending);
    assert(memcmp(memory, descriptors, sizeof(*descriptors)) == 0);
    header[3] = 104;
    assert(noodles_push_command(&link, fill) == 0);
    header[3] = 105;  // completion beyond the batch target is also sufficient
    assert(noodles_push_sprite_batch(&link, descriptors, 1) == 0);

    reset(0);
    header[2] = 1;  // full, even though no batch owns the table
    rejected(EAGAIN, 1);
    header[2] = 0;
    rejected(EINVAL, 0);
    rejected(EINVAL, 65);
    assert(noodles_push_sprite_batch(&link, NULL, 1) == -1 && errno == EINVAL);
    assert(maps == 0 && link.submitted == 0);
    fail_map = 1;
    assert(noodles_push_sprite_batch(&link, descriptors, 1) == -1 && errno == ENOMEM);
    assert(!link.batch_pending && link.submitted == 0 && header[0] == 0 && slots[0] == 0);
    fail_map = 0;
    assert(noodles_push_sprite_batch(&link, descriptors, 1) == 0);
    assert(link.batch_fence == 1);

    reset(0);
    link.submitted = 0xffffffffu;
    assert(noodles_push_sprite_batch(&link, descriptors, 1) == 0);
    assert(link.submitted == 0 && link.batch_fence == 0);
    header[3] = 0x7fffffffu;
    rejected(EAGAIN, 1);
    header[3] = 0;
    assert(noodles_push_sprite_batch(&link, descriptors, 1) == 0);

    reset(0xfffffffeu);
    assert(noodles_push_command(&link, fill) == 0);
    assert(noodles_push_sprite_batch(&link, descriptors, 1) == 0);
    assert(link.batch_fence == 0);
    header[3] = 0xffffffffu;
    rejected(EAGAIN, 1);
    assert(!noodles_link_fence_reached(&link, 0x80000000u));
    header[3] = 0x80000000u;
    assert(noodles_link_fence_reached(&link, 0x80000000u));
    assert(noodles_push_sprite_batch(&link, descriptors, 1) == 0);
    assert(link.batch_fence == 1);

    reset(17);
    assert(noodles_push_command(&link, batch) == 0);
    rejected(EAGAIN, 1);  // raw opcode-5 submission also owns the table
    header[3] = 18;
    assert(noodles_link_upload(&link, NOODLES_SPRITE_DESCRIPTOR_ADDR, descriptors, 32) == 0);
    assert(!link.batch_pending);

    reset(0);
    assert(noodles_push_sprite_batch(&link, descriptors, 1) == 0);
    assert(noodles_link_upload(&link, NOODLES_SPRITE_DESCRIPTOR_ADDR - 32, descriptors, 32) == -1);
    assert(errno == EINVAL);
    assert(noodles_link_upload(&link, NOODLES_SPRITE_DESCRIPTOR_ADDR + 2048, descriptors, 32) == 0);
    assert(link.batch_pending);  // adjacent uploads do not release ownership

    reset(123);
    for (unsigned i = 0; i < 256; ++i) {
        assert(noodles_push_sprite_batch(&link, descriptors, 64) == 0);
        rejected(EAGAIN, 64);
        header[2] = header[0];
        header[3] = link.batch_fence;
    }
    assert(link.write_ptr == 0 && link.submitted == 256);
    // A completed owner must not stay latched through a long non-batch stream.
    assert(noodles_push_command(&link, fill) == 0 && !link.batch_pending);
    reset(0);
    descriptors[0].flags = 2;
    rejected(EINVAL, 1);
    descriptors[0].flags = 0;
    descriptors[0].src_pitch = 3;
    rejected(EINVAL, 1);
    assert(noodles_link_upload(&link, 0xfffffff0u, descriptors, 32) == -1 && errno == EINVAL);
    assert(noodles_link_upload(&link, 0x31400000u, NULL, 32) == -1 && errno == EINVAL);
    assert(noodles_link_upload(&link, 0x31400000u, descriptors, 0) == -1 && errno == EINVAL);
    assert(maps == 0 && link.submitted == 0);
    puts("PASS: descriptor ownership, non-destructive retries, raw uploads, errors and fence/ring wrap");
    return 0;
}
