#define _POSIX_C_SOURCE 200809L
#include "../lib/noodles_link.h"
#include "../lib/noodles_surface.h"
#include "blend_ref.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static uint32_t memory[2048];
static unsigned char descriptor_memory[4096];
static unsigned char surface_memory[2 * 1024 * 1024];
static unsigned char back_buffer_memory[2][2 * 1024 * 1024];
static char lock_path[256];
static int map_fail, device_fail, complete_on_sleep, interrupt_sleep, clock_fail;
static int maps, unmaps, sleeps;
static int control_active;
static uint64_t now_ns;
static long last_pause_ns, max_pause_ns;
static int retire_after_sleeps;
static uint32_t retire_fence;
static const uint32_t fill[8] = {1, NOODLES_BUFFER_B_ADDR, 3200, 800, 600, 0, 0, 0};

int __real_open(const char *, int, ...);
int __wrap_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, int);
        va_end(args);
    }
    if (!strcmp(path, "/dev/mem")) {
        if (device_fail) { errno = EACCES; return -1; }
        return __real_open("/dev/null", flags, mode);
    }
    assert(!strcmp(path, "/run/noodles.lock"));
    return __real_open(lock_path, flags, mode);
}

void *__wrap_mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset) {
    if (map_fail) { errno = ENOMEM; return MAP_FAILED; }
    ++maps;
    if (offset == 0x30020000) {
        assert(length == sizeof(memory));
        return memory;
    }
    if (offset == 0x30022000) {
        assert(length == sizeof(descriptor_memory));
        return descriptor_memory;
    }
    if (offset >= NOODLES_BUFFER_A_ADDR &&
        (uint64_t)offset + length <= NOODLES_BUFFER_A_ADDR + sizeof(back_buffer_memory[0]))
        return back_buffer_memory[0] + (offset - NOODLES_BUFFER_A_ADDR);
    if (offset >= NOODLES_BUFFER_B_ADDR &&
        (uint64_t)offset + length <= NOODLES_BUFFER_B_ADDR + sizeof(back_buffer_memory[1]))
        return back_buffer_memory[1] + (offset - NOODLES_BUFFER_B_ADDR);
    assert(offset >= NOODLES_SURFACE_ARENA_ADDR);
    assert((uint64_t)offset + length <=
           (uint64_t)NOODLES_SURFACE_ARENA_ADDR + sizeof(surface_memory));
    return surface_memory + (offset - NOODLES_SURFACE_ARENA_ADDR);
}

int __wrap_munmap(void *addr, size_t size) {
    assert((addr == memory && size == sizeof(memory)) ||
           (addr == descriptor_memory && size == sizeof(descriptor_memory)) ||
           ((unsigned char *)addr >= back_buffer_memory[0] &&
            (unsigned char *)addr + size <= back_buffer_memory[0] + sizeof(back_buffer_memory[0])) ||
           ((unsigned char *)addr >= back_buffer_memory[1] &&
            (unsigned char *)addr + size <= back_buffer_memory[1] + sizeof(back_buffer_memory[1])) ||
           ((unsigned char *)addr >= surface_memory &&
            (unsigned char *)addr + size <= surface_memory + sizeof(surface_memory)));
    ++unmaps;
    return 0;
}

int __wrap_clock_gettime(clockid_t clock, struct timespec *time) {
    assert(clock == CLOCK_MONOTONIC);
    if (clock_fail) { errno = EIO; return -1; }
    time->tv_sec = now_ns / 1000000000u;
    time->tv_nsec = now_ns % 1000000000u;
    return 0;
}

int __wrap_nanosleep(const struct timespec *pause, struct timespec *remaining) {
    assert(pause->tv_sec == 0 && pause->tv_nsec > 0 && pause->tv_nsec <= 1000000);
    now_ns += pause->tv_nsec;
    ++sleeps;
    last_pause_ns = pause->tv_nsec;
    if (pause->tv_nsec > max_pause_ns) max_pause_ns = pause->tv_nsec;
    if (retire_after_sleeps > 0 && --retire_after_sleeps == 0) {
        memory[2] = memory[0];
        memory[3] = (memory[3] & 0x80000000u) | retire_fence;
    }
    uint32_t request = memory[12];
    if (!control_active && request == 0x434c414du &&
        (memory[10] != 0 || memory[11] != 0)) {
        memory[14] = memory[10];
        memory[15] = memory[11];
        memory[16] = request;
        control_active = 1;
    } else if (control_active && request == 0) {
        memory[16] = 0;
        control_active = 0;
    } else if (control_active && request != 0x434c414du &&
               memory[10] == memory[14] && memory[11] == memory[15]) {
        memory[16] = request;
    }
    if (complete_on_sleep) {
        while (memory[2] != memory[0]) {
            uint32_t op = memory[1024 + memory[2] * 8];
            uint32_t parity = memory[3] & 0x80000000u;
            if (op == 4) parity ^= 0x80000000u;
            memory[3] = parity | ((memory[3] + 1) & 0x7fffffffu);
            memory[2] = (memory[2] + 1) % 64;
        }
    }
    if (interrupt_sleep) { errno = EINTR; return -1; }
    return 0;
}

static noodles_link_t *open_device(int recover) {
    noodles_link_t *device = NULL;
    assert(noodles_link_open_legacy(&device, recover) == 0 && device);
    return device;
}

static void closed(noodles_link_t *device) {
    assert(noodles_link_close(device, 10) == 0);
}

static void seed_identity(void) {
    memory[4] = 0x4e444c53u;
    memory[5] = NOODLES_PROTOCOL_VERSION;
    memory[6] = 0x1fe;
    memory[7] = (800u << 16) | 600u;
    memory[8] = 3200;
    memory[16] = 0;
    control_active = 0;
}

static noodles_link_t *open_verified(void) {
    noodles_link_t *device = NULL;
    assert(noodles_link_open(&device) == 0 && device);
    return device;
}

int main(void) {
    char dir[] = "/tmp/noodles-sdk-test.XXXXXX";
    assert(mkdtemp(dir));
    snprintf(lock_path, sizeof(lock_path), "%s/lock", dir);
    noodles_link_t *a = NULL, *b = NULL;
    assert(noodles_link_open_legacy(NULL, 0) == -1 && errno == EINVAL);
    assert(noodles_link_open_legacy(&a, 2) == -1 && errno == EINVAL && !a);
    device_fail = 1;
    assert(noodles_link_open_legacy(&a, 0) == -1 && errno == EACCES && !a);
    device_fail = 0;
    map_fail = 1;
    assert(noodles_link_open_legacy(&a, 0) == -1 && errno == ENOMEM && !a);
    map_fail = 0;
    memory[0] = 64;
    assert(noodles_link_open_legacy(&a, 0) == -1 && errno == EPROTO);
    memory[0] = 1;
    assert(noodles_link_open_legacy(&a, 0) == -1 && errno == EBUSY);
    memory[0] = 0;
    a = open_device(0);
    assert(noodles_link_open_legacy(&b, 0) == -1 && errno == EBUSY && !b);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        /* Inherited owner fd remains open; a new open must still conflict. */
        assert(noodles_link_open_legacy(&b, 1) == -1 && errno == EBUSY);
        _exit(0);
    }
    int status;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && !WEXITSTATUS(status));
    noodles_device_info_t info;
    assert(noodles_link_get_info(a, &info) == 0 && !info.hardware_verified);
    assert(info.width == 800 && info.height == 600 && info.pitch == 3200);
    assert(info.opcode_mask == 0x7e);
    assert(noodles_push_command(a, fill) == 0);
    assert(noodles_link_last_fence(a) == 1);
    int done;
    assert(noodles_link_poll(a, 1, &done) == 0 && !done);
    noodles_fence_t fence;
    assert(noodles_push_present(a, &fence) == 0 && fence == 2);
    uint32_t before = memory[0];
    assert(noodles_push_command(a, fill) == -1 && errno == EAGAIN && memory[0] == before);
    assert(noodles_link_back_buffer(a) == NOODLES_BUFFER_B_ADDR);
    /* Even after physical retirement, callers must observe it before drawing
     * with the next buffer; a submission cannot silently change buffer roles. */
    memory[2] = memory[0];
    memory[3] = 0x80000002u;
    assert(noodles_push_command(a, fill) == -1 && errno == EAGAIN);
    assert(noodles_link_poll(a, fence, &done) == 0 && done);
    complete_on_sleep = interrupt_sleep = 1;
    assert(noodles_link_wait(a, fence, 10) == 0);
    assert(noodles_link_back_buffer(a) == NOODLES_BUFFER_A_ADDR);
    assert(noodles_push_command(a, fill) == 0);
    closed(a); /* drains outstanding work, including after EINTR */
    assert(sleeps == 1);
    a = open_device(0);
    closed(a);
    a = open_device(0);
    assert(noodles_link_wait(a, noodles_link_last_fence(a), 0) == 0);
    closed(a);

    /* Exact deadline, faulted handle, late completion does not authorize reuse. */
    complete_on_sleep = interrupt_sleep = 0;
    a = open_device(0);
    assert(noodles_push_command(a, fill) == 0);
    uint64_t start = now_ns;
    int sleeps_before_drain = sleeps;
    max_pause_ns = 0;
    assert(noodles_link_drain(a, 3) == -1 && errno == ETIMEDOUT);
    assert(now_ns - start == 3000000);
    /* Long waits back off from 20us but never sleep past 0.1ms, so a fence
     * that retires late in a wait is still observed promptly. */
    assert(max_pause_ns == 100000 && sleeps - sleeps_before_drain > 30);
    before = memory[0];
    assert(noodles_push_command(a, fill) == -1 && errno == ETIMEDOUT && memory[0] == before);
    assert(noodles_link_poll(a, 0, &done) == -1 && errno == ETIMEDOUT);
    assert(noodles_link_close(a, 10) == -1 && errno == ETIMEDOUT);
    assert(noodles_link_open_legacy(&a, 0) == -1 && errno == EOWNERDEAD && !a);
    memset(memory, 0, sizeof(memory)); /* model explicit external core reload */
    a = open_device(1);
    closed(a);

    /* Process death releases flock but leaves the dirty marker. */
    child = fork();
    assert(child >= 0);
    if (!child) { (void)open_device(0); _exit(0); }
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && !WEXITSTATUS(status));
    assert(noodles_link_open_legacy(&a, 0) == -1 && errno == EOWNERDEAD);
    a = open_device(1);
    closed(a);

    memory[3] = 0x7ffffffeu;
    a = open_device(0);
    assert(noodles_push_command(a, fill) == 0);
    assert(noodles_push_present(a, &fence) == 0 && fence == 0);
    complete_on_sleep = 1;
    assert(noodles_link_wait(a, fence, 10) == 0);
    closed(a);
    a = open_device(0);
    before = memory[0];
    uint32_t bad[8];
    for (unsigned kind = 0; kind < 6; ++kind) {
        memcpy(bad, fill, sizeof(bad));
        switch (kind) {
        case 0: bad[0] = 255; break;
        case 1: bad[1] = 0xfffffffcu; break;
        case 2: bad[2] = 3199; break;
        case 3: bad[3] = 0; break;
        case 4: bad[1] = NOODLES_SPRITE_DESCRIPTOR_ADDR; break;
        case 5: bad[4] = 0x10000; break;
        }
        assert(noodles_push_command(a, bad) == -1 && errno == EINVAL && memory[0] == before);
    }

    /* Managed surfaces isolate their arena from raw access, preserve pitched
     * partial transfers and clip draw geometry before publication. */
    assert(noodles_link_upload(a, NOODLES_SURFACE_ARENA_ADDR, fill, sizeof(fill)) == -1 &&
           errno == EINVAL);
    memcpy(bad, fill, sizeof(bad));
    bad[1] = NOODLES_SURFACE_ARENA_ADDR;
    bad[2] = 256;
    bad[3] = bad[4] = 64;
    assert(noodles_push_command(a, bad) == -1 && errno == EINVAL);

    noodles_surface_t *surface = NULL;
    assert(noodles_surface_create(a, 0, 64, &surface) == -1 && errno == EINVAL && !surface);
    assert(noodles_surface_create(a, 64, 64, &surface) == 0);
    assert(noodles_surface_width(surface) == 64 && noodles_surface_height(surface) == 64);
    assert(noodles_surface_pitch(surface) == 256);
    noodles_rect_t transfer_rect = {2, 3, 2, 2};
    uint32_t upload[6] = {0x11223344, 0x55667788, 0xdeadbeef,
                          0x99aabbcc, 0xddeeff00, 0xcafebabe};
    uint32_t readback[6] = {0};
    assert(noodles_surface_update(surface, &transfer_rect, upload, 12, 10) == 0);
    assert(noodles_surface_read(surface, &transfer_rect, readback, 12, 10) == 0);
    assert(readback[0] == upload[0] && readback[1] == upload[1] && readback[2] == 0);
    assert(readback[3] == upload[3] && readback[4] == upload[4] && readback[5] == 0);

    uint32_t slot = memory[0];
    noodles_rect_t clipped_fill = {-4, -5, 10, 12};
    assert(noodles_surface_fill(surface, &clipped_fill, 0x12345678) == 0);
    uint32_t *published = &memory[1024 + slot * 8];
    uint32_t first_surface_address = published[1];
    assert(published[0] == 1 && published[2] == 256 &&
           published[3] == 6 && published[4] == 7);

    /* Destruction invalidates the handle immediately, but allocation cannot
     * recycle its physical extent until the submitted fill completes. */
    assert(noodles_surface_destroy(surface) == 0);
    assert(noodles_surface_width(surface) == 0);
    noodles_surface_t *next_surface = NULL;
    assert(noodles_surface_create(a, 64, 64, &next_surface) == 0);
    slot = memory[0];
    noodles_rect_t full_tile = {0, 0, 64, 64};
    assert(noodles_surface_fill(next_surface, &full_tile, 0) == 0);
    published = &memory[1024 + slot * 8];
    assert(published[1] != first_surface_address);
    memory[2] = memory[0];
    memory[3] = (memory[3] & 0x80000000u) | noodles_link_last_fence(a);
    size_t collected = 0;
    assert(noodles_surface_collect(a, &collected) == 0 && collected == 1);
    noodles_surface_t *reused_surface = NULL;
    assert(noodles_surface_create(a, 64, 64, &reused_surface) == 0);
    slot = memory[0];
    assert(noodles_surface_fill(reused_surface, &full_tile, 0) == 0);
    published = &memory[1024 + slot * 8];
    assert(published[1] == first_surface_address);
    memory[2] = memory[0];
    memory[3] = (memory[3] & 0x80000000u) | noodles_link_last_fence(a);

    /* Batch clipping translates managed sources to ordinary hardware
     * descriptors while retaining the surface until that batch completes. */
    noodles_surface_blit_t tile = {reused_surface, {0, 0, 66, 66}, -2, -2};
    assert(noodles_surface_batch_to_back_buffer(a, &tile, 1) == 0);
    const noodles_sprite_descriptor_t *descriptor =
        (const noodles_sprite_descriptor_t *)descriptor_memory;
    assert(descriptor->width == 62 && descriptor->height == 62);
    assert(descriptor->dst_addr == noodles_link_back_buffer(a));
    assert(descriptor->src_addr == first_surface_address + 2 * 256 + 2 * 4);

    /* Free-space coalescing must recover the entire 224 MiB arena. */
    memory[2] = memory[0];
    memory[3] = (memory[3] & 0x80000000u) | noodles_link_last_fence(a);
    assert(noodles_surface_destroy(next_surface) == 0);
    assert(noodles_surface_destroy(reused_surface) == 0);
    assert(noodles_surface_collect(a, &collected) == 0 && collected == 2);

    noodles_texture_cache_t *cache = NULL;
    assert(noodles_texture_cache_create(a, 64, 64, 2, 1, &cache) == 0);
    uint32_t tile_pixels[64 * 64];
    for (size_t i = 0; i < 64 * 64; ++i) tile_pixels[i] = (uint32_t)i;
    assert(noodles_texture_cache_upload(cache, 1, tile_pixels, 256, 10) == 0);
    assert(noodles_texture_cache_upload(cache, 2, tile_pixels, 256, 10) == 0);
    noodles_texture_blit_t cached_tile = {1, {0, 0, 64, 64}, 0, 0};
    assert(noodles_texture_cache_batch_to_back_buffer(cache, &cached_tile, 1) == 0);
    memory[2] = memory[0];
    memory[3] = (memory[3] & 0x80000000u) | noodles_link_last_fence(a);
    assert(noodles_texture_cache_upload(cache, 3, tile_pixels, 256, 10) == 0);
    cached_tile.key = 2;
    assert(noodles_texture_cache_batch_to_back_buffer(cache, &cached_tile, 1) == -1 &&
           errno == ENOENT);
    cached_tile.key = 3;
    assert(noodles_texture_cache_batch_to_back_buffer(cache, &cached_tile, 1) == 0);
    memory[2] = memory[0];
    memory[3] = (memory[3] & 0x80000000u) | noodles_link_last_fence(a);
    assert(noodles_texture_cache_destroy(cache, 10) == 0);
    assert(noodles_surface_collect(a, &collected) == 0 && collected == 1);

    noodles_surface_t *blocks[224];
    for (size_t i = 0; i < 224; ++i)
        assert(noodles_surface_create(a, 4096, 64, &blocks[i]) == 0);
    noodles_surface_t *exhausted = NULL;
    assert(noodles_surface_create(a, 1, 1, &exhausted) == -1 && errno == ENOMEM);
    for (size_t i = 0; i < 224; i += 2) assert(noodles_surface_destroy(blocks[i]) == 0);
    for (size_t i = 1; i < 224; i += 2) assert(noodles_surface_destroy(blocks[i]) == 0);
    assert(noodles_surface_collect(a, &collected) == 0 && collected == 224);
    noodles_surface_t *whole_arena = NULL;
    assert(noodles_surface_create(a, 4096, 14336, &whole_arena) == 0);

    clock_fail = 1;
    assert(noodles_link_drain(a, 10) == -1 && errno == EIO);
    assert(noodles_link_close(a, 10) == -1 && errno == EIO);

    /* Verified stage-2B attachment validates identity and requires a live claim. */
    clock_fail = 0;
    memset(memory, 0, sizeof(memory));
    assert(noodles_link_open(&a) == -1 && errno == ENODEV && !a);
    seed_identity();
    memory[5] = 0x00020000u;
    assert(noodles_link_open(&a) == -1 && errno == EPROTONOSUPPORT && !a);
    seed_identity();
    memory[6] = 0x3e;
    assert(noodles_link_open(&a) == -1 && errno == ENOTSUP && !a);
    seed_identity();
    assert(noodles_link_open_legacy(&a, 1) == -1 && errno == EPROTONOSUPPORT && !a);
    a = open_verified();
    assert(memory[16] == 0x434c414du && control_active);
    assert(noodles_link_get_info(a, &info) == 0 && info.hardware_verified);
    assert(info.protocol_version == NOODLES_PROTOCOL_VERSION);
    assert(info.opcode_mask == 0x1fe);
    assert(noodles_push_command(a, fill) == 0);
    memory[2] = memory[0];
    memory[3] = 1;
    int sleeps_before_ping = sleeps;
    assert(noodles_link_wait(a, 1, 10) == 0);
    /* The ping is issued without sleeping and answered by the first
     * minimum-length check, not after a full backoff period. */
    assert(sleeps == sleeps_before_ping + 1 && last_pause_ns == 20000);
    int sleeps_after_confirmation = sleeps;
    uint32_t confirmed_sequence = memory[12];
    assert(noodles_link_wait(a, 1, 10) == 0);
    assert(sleeps == sleeps_after_confirmation && memory[12] == confirmed_sequence);
    closed(a);
    assert(!control_active && memory[16] == 0);

    /* Protocol 1.0 cores remain attachable; BLIT_BLEND is refused without
     * publishing anything when capability bit 7 is absent (LINK-012). */
    memory[0] = memory[2] = memory[3] = 0;
    seed_identity();
    memory[5] = 0x00010000u;
    memory[6] = 0x7e;
    a = open_verified();
    assert(noodles_link_get_info(a, &info) == 0 && info.protocol_version == 0x00010000u);
    before = memory[0];
    assert(noodles_push_blit_blend(a, NOODLES_BUFFER_B_ADDR, 3200, 0x31400000u, 256,
                                   64, 64, 255) == -1 && errno == ENOTSUP);
    assert(memory[0] == before);
    closed(a);

    /* A 1.1 core advertising BLIT_BLEND receives opcode 7 verbatim. */
    seed_identity();
    memory[6] = 0xfe;
    a = open_verified();
    assert(noodles_link_get_info(a, &info) == 0 && (info.opcode_mask & NOODLES_CAP_BLIT_BLEND));
    slot = memory[0];
    assert(noodles_push_blit_blend(a, NOODLES_BUFFER_B_ADDR + 8, 3200, 0x31400000u, 256,
                                   64, 32, 0x80) == 0);
    published = &memory[1024 + slot * 8];
    assert(published[0] == 7 && published[1] == NOODLES_BUFFER_B_ADDR + 8 &&
           published[2] == 3200 && published[3] == 64 && published[4] == 32 &&
           published[5] == 0x80 && published[6] == 0x31400000u && published[7] == 256);
    before = memory[0];
    assert(noodles_push_blend_fill(a, NOODLES_BUFFER_B_ADDR, 3200, 4, 4,
                                   0x80402010u, NOODLES_DRAW_MODE_ADD) == -1 &&
           errno == ENOTSUP && memory[0] == before);

    /* Overlapping byte spans, out-of-range modulation and empty rectangles
     * are refused; exactly adjacent spans are allowed. */
    before = memory[0];
    assert(noodles_push_blit_blend(a, NOODLES_BUFFER_B_ADDR, 3200,
                                   NOODLES_BUFFER_B_ADDR + 3200 * 10, 3200, 64, 32, 255) == -1 &&
           errno == EINVAL);
    uint32_t raw_blend[8] = {7, NOODLES_BUFFER_B_ADDR, 3200, 4, 4, 0x100, 0x31400000u, 16};
    assert(noodles_push_command(a, raw_blend) == -1 && errno == EINVAL);
    assert(noodles_push_blit_blend(a, NOODLES_BUFFER_B_ADDR, 3200, 0x31400000u, 16,
                                   0, 4, 255) == -1 && errno == EINVAL);
    assert(memory[0] == before);
    assert(noodles_push_blit_blend(a, NOODLES_BUFFER_B_ADDR, 3200,
                                   NOODLES_BUFFER_B_ADDR + 3200 * 31 + 256, 256,
                                   64, 32, 255) == 0);

    /* Managed surfaces and cached textures clip, then publish BLIT_BLEND. */
    noodles_surface_t *blend_surface = NULL;
    assert(noodles_surface_create(a, 64, 64, &blend_surface) == 0);
    slot = memory[0];
    noodles_rect_t blend_rect = {0, 0, 66, 66};
    assert(noodles_surface_blend_to_back_buffer(a, -2, -2, blend_surface, &blend_rect, 200) == 0);
    published = &memory[1024 + slot * 8];
    assert(published[0] == 7 && published[3] == 62 && published[4] == 62 &&
           published[5] == 200 && published[1] == noodles_link_back_buffer(a));
    noodles_texture_cache_t *blend_cache = NULL;
    assert(noodles_texture_cache_create(a, 64, 64, 2, 1, &blend_cache) == 0);
    assert(noodles_texture_cache_upload(blend_cache, 9, tile_pixels, 256, 10) == 0);
    noodles_texture_blit_t blend_tile = {9, {0, 0, 64, 64}, 100, 50};
    slot = memory[0];
    assert(noodles_texture_cache_blend_to_back_buffer(blend_cache, &blend_tile, 255) == 0);
    published = &memory[1024 + slot * 8];
    assert(published[0] == 7 && published[3] == 64 && published[5] == 255 &&
           published[1] == noodles_link_back_buffer(a) + 50 * 3200 + 100 * 4);
    blend_tile.key = 10;
    assert(noodles_texture_cache_blend_to_back_buffer(blend_cache, &blend_tile, 255) == -1 &&
           errno == ENOENT);
    assert(noodles_texture_cache_destroy(blend_cache, 10) == 0);
    assert(noodles_surface_destroy(blend_surface) == 0);
    closed(a);

    /* BLIT-008 flagged batches need protocol 1.2: a 1.1 core refuses them
     * without publishing, while unflagged batches still work. */
    memory[0] = memory[2] = memory[3] = 0;
    seed_identity();
    memory[5] = 0x00010001u;
    memory[6] = 0xfe;
    a = open_verified();
    noodles_surface_t *sprite = NULL;
    assert(noodles_surface_create(a, 64, 64, &sprite) == 0);
    noodles_surface_draw_t draw = {sprite, {0, 0, 64, 64}, 10, 10,
                                   NOODLES_DRAW_BLEND | NOODLES_DRAW_MIRROR_X, 0x80ffffffu};
    before = memory[0];
    assert(noodles_surface_draw_batch(a, NULL, &draw, 1) == -1 && errno == ENOTSUP);
    assert(memory[0] == before);
    draw.flags = 0;
    assert(noodles_surface_draw_batch(a, NULL, &draw, 1) == 0);
    assert(noodles_surface_destroy(sprite) == 0);
    closed(a);

    /* On a 1.2 core, mirroring is applied before clipping: clipping the
     * destination's left or top edge trims the far side of a mirrored
     * source instead of its near side. */
    memory[0] = memory[2] = memory[3] = 0;
    seed_identity();
    memory[6] = 0xfe;
    a = open_verified();
    assert(noodles_surface_create(a, 64, 64, &sprite) == 0);
    const noodles_sprite_descriptor_t *drawn =
        (const noodles_sprite_descriptor_t *)descriptor_memory;
    uint32_t back = noodles_link_back_buffer(a);
    uint32_t sprite_base;
    {
        noodles_surface_draw_t plain = {sprite, {0, 0, 64, 64}, 0, 0, 0, 0xffffffffu};
        assert(noodles_surface_draw_batch(a, NULL, &plain, 1) == 0);
        sprite_base = drawn[0].src_addr;
        assert(noodles_link_drain(a, 10) == 0);
    }
    noodles_surface_draw_t draws[4] = {
        {sprite, {0, 0, 64, 64}, -10, -5, NOODLES_DRAW_BLEND, 0x80ffffffu},
        {sprite, {0, 0, 64, 64}, -10, -5, NOODLES_DRAW_MIRROR_X | NOODLES_DRAW_MIRROR_Y,
         0xffffffffu},
        {sprite, {-3, 0, 64, 64}, 790, 0, NOODLES_DRAW_MIRROR_X, 0x11223344u},
        {sprite, {0, 0, 64, 64}, 20, 20, NOODLES_DRAW_KEY, 0x00ff00ffu},
    };
    assert(noodles_surface_draw_batch(a, NULL, draws, 4) == 0);
    assert(drawn[0].width == 54 && drawn[0].height == 59 && drawn[0].dst_addr == back &&
           drawn[0].src_addr == sprite_base + 5 * 256 + 10 * 4 &&
           drawn[0].flags == NOODLES_DRAW_BLEND && drawn[0].colorkey == 0x80ffffffu);
    assert(drawn[1].width == 54 && drawn[1].height == 59 && drawn[1].dst_addr == back &&
           drawn[1].src_addr == sprite_base);
    /* Source x = -3 trims 3 pixels; mirrored, that is the destination's right
     * side, and the screen edge at 800 then trims 51 more from the left. */
    assert(drawn[2].width == 10 && drawn[2].dst_addr == back + 790 * 4 &&
           drawn[2].src_addr == sprite_base + 51 * 4 && drawn[2].colorkey == 0x11223344u);
    assert(drawn[3].flags == NOODLES_DRAW_KEY && drawn[3].colorkey == 0x00ff00ffu);
    assert(noodles_link_drain(a, 10) == 0);

    /* Property check: every clipped draw shows exactly the pixels of the
     * unclipped (possibly mirrored) draw that land on screen and come from
     * inside the source surface. */
    uint32_t seed = 12345;
    for (int trial = 0; trial < 400; ++trial) {
        int32_t v[6];
        for (int k = 0; k < 6; ++k) {
            seed = seed * 1103515245u + 12345u;
            v[k] = (int32_t)((seed >> 8) % 1100u);
        }
        noodles_surface_draw_t d = {sprite,
                                    {v[0] % 160 - 80, v[1] % 160 - 80,
                                     (uint32_t)(v[2] % 100 + 1), (uint32_t)(v[3] % 100 + 1)},
                                    v[4] - 150, v[5] % 750 - 150,
                                    (uint32_t)(trial & 3) << 2, 0xffffffffu};
        int mirror[2] = {(trial & 1) != 0, (trial & 2) != 0};
        int64_t rect_pos[2] = {d.source_rect.x, d.source_rect.y};
        int64_t rect_len[2] = {d.source_rect.width, d.source_rect.height};
        int64_t dst_pos[2] = {d.dst_x, d.dst_y};
        int64_t src_limit[2] = {64, 64}, dst_limit[2] = {800, 600};
        int64_t lo[2], hi[2];   /* valid unclipped offsets, [lo, hi) */
        for (int ax = 0; ax < 2; ++ax) {
            lo[ax] = rect_len[ax];
            hi[ax] = 0;
            for (int64_t i = 0; i < rect_len[ax]; ++i) {
                int64_t dc = dst_pos[ax] + i;
                int64_t sc = rect_pos[ax] + (mirror[ax] ? rect_len[ax] - 1 - i : i);
                if (dc >= 0 && dc < dst_limit[ax] && sc >= 0 && sc < src_limit[ax]) {
                    if (i < lo[ax]) lo[ax] = i;
                    hi[ax] = i + 1;
                }
            }
        }
        before = memory[0];
        assert(noodles_surface_draw_batch(a, NULL, &d, 1) == 0);
        if (hi[0] <= lo[0] || hi[1] <= lo[1]) {
            assert(memory[0] == before);
            continue;
        }
        assert(memory[0] != before);
        uint32_t doff = drawn[0].dst_addr - back, soff = drawn[0].src_addr - sprite_base;
        int64_t got_dst[2] = {(doff % 3200) / 4, doff / 3200};
        int64_t got_src[2] = {(soff % 256) / 4, soff / 256};
        int64_t got_len[2] = {drawn[0].width, drawn[0].height};
        for (int ax = 0; ax < 2; ++ax) {
            assert(got_len[ax] == hi[ax] - lo[ax]);
            assert(got_dst[ax] == dst_pos[ax] + lo[ax]);
            /* Descriptor pixel j shows source got_src + (mirrored ? len-1-j : j),
             * which must equal the unclipped mapping of offset lo + j. */
            for (int64_t j = 0; j < got_len[ax]; ++j) {
                int64_t want = rect_pos[ax] + (mirror[ax] ? rect_len[ax] - 1 - (lo[ax] + j)
                                                          : lo[ax] + j);
                int64_t have = got_src[ax] + (mirror[ax] ? got_len[ax] - 1 - j : j);
                assert(want == have);
            }
        }
        assert(noodles_link_drain(a, 10) == 0);
    }

    /* Keyed draws cannot also be flagged; a surface cannot draw onto itself;
     * flagged raw descriptors must not overlap their own destination. */
    draws[0].flags = NOODLES_DRAW_KEY | NOODLES_DRAW_BLEND;
    assert(noodles_surface_draw_batch(a, NULL, draws, 1) == -1 && errno == EINVAL);
    assert(noodles_surface_draw_batch(a, sprite, &draws[1], 1) == -1 && errno == EINVAL);
    noodles_sprite_descriptor_t overlap = {NOODLES_BUFFER_B_ADDR, 3200, 32, 32, 0xffffffffu,
                                           NOODLES_BUFFER_B_ADDR + 3200 * 8, 3200,
                                           NOODLES_DRAW_BLEND};
    assert(noodles_push_sprite_batch(a, &overlap, 1) == -1 && errno == EINVAL);
    overlap.src_addr = 0x31400000u;
    overlap.src_pitch = 128;
    assert(noodles_push_sprite_batch(a, &overlap, 1) == 0);
    assert(noodles_link_drain(a, 10) == 0);

    /* Batches into a managed surface and from the texture cache. */
    noodles_surface_t *target = NULL;
    assert(noodles_surface_create(a, 128, 128, &target) == 0);
    draws[1].dst_x = draws[1].dst_y = 100;
    assert(noodles_surface_draw_batch(a, target, &draws[1], 1) == 0);
    assert(drawn[0].width == 28 && drawn[0].height == 28 && drawn[0].dst_pitch == 512 &&
           drawn[0].src_addr == sprite_base + 36 * 256 + 36 * 4);
    assert(noodles_link_drain(a, 10) == 0);
    noodles_texture_cache_t *draw_cache = NULL;
    assert(noodles_texture_cache_create(a, 64, 64, 2, 1, &draw_cache) == 0);
    assert(noodles_texture_cache_upload(draw_cache, 5, tile_pixels, 256, 10) == 0);
    noodles_texture_draw_t cached = {5, {0, 0, 64, 64}, 0, 0, NOODLES_DRAW_MIRROR_Y, 0xffffffffu};
    assert(noodles_texture_cache_draw_batch_to_back_buffer(draw_cache, &cached, 1) == 0);
    assert(drawn[0].flags == NOODLES_DRAW_MIRROR_Y && drawn[0].height == 64);
    cached.key = 6;
    assert(noodles_texture_cache_draw_batch_to_back_buffer(draw_cache, &cached, 1) == -1 &&
           errno == ENOENT);
    assert(noodles_texture_cache_destroy(draw_cache, 10) == 0);
    assert(noodles_surface_destroy(target) == 0);
    assert(noodles_surface_destroy(sprite) == 0);
    closed(a);

    /* BLIT-009 explicit modes: the SDK's encodings are the reference
     * model's, a protocol 1.2 core refuses them without publishing, and a
     * 1.3 core receives them intact; malformed modes are rejected. */
    assert(NOODLES_DRAW_MODE_MUL ==
           noodles_ref_mode(NOODLES_REF_DST_COLOR, NOODLES_REF_ONE_MINUS_SRC_ALPHA,
                            NOODLES_REF_ADD, NOODLES_REF_ZERO, NOODLES_REF_ONE, NOODLES_REF_ADD, 1));
    assert(NOODLES_DRAW_MODE_ADD ==
           noodles_ref_mode(NOODLES_REF_SRC_ALPHA, NOODLES_REF_ONE, NOODLES_REF_ADD,
                            NOODLES_REF_ZERO, NOODLES_REF_ONE, NOODLES_REF_ADD, 0));
    assert(NOODLES_DRAW_MODE_BLEND == NOODLES_REF_MODE_BLEND);
    assert(NOODLES_DRAW_MODE_NONE == NOODLES_REF_MODE_NONE);
    memory[0] = memory[2] = memory[3] = 0;
    seed_identity();
    memory[5] = 0x00010002u;
    memory[6] = 0xfe;
    a = open_verified();
    noodles_surface_t *mode_sprite = NULL;
    assert(noodles_surface_create(a, 64, 64, &mode_sprite) == 0);
    noodles_surface_draw_t mode_draw = {mode_sprite, {0, 0, 64, 64}, 10, 10,
                                        NOODLES_DRAW_MODE_ADD, 0xffffffffu};
    before = memory[0];
    assert(noodles_surface_draw_batch(a, NULL, &mode_draw, 1) == -1 && errno == ENOTSUP);
    assert(memory[0] == before);
    mode_draw.flags = NOODLES_DRAW_BLEND;
    assert(noodles_surface_draw_batch(a, NULL, &mode_draw, 1) == 0);
    assert(noodles_surface_destroy(mode_sprite) == 0);
    closed(a);

    memory[0] = memory[2] = memory[3] = 0;
    seed_identity();
    memory[6] = 0xfe;
    a = open_verified();
    assert(noodles_surface_create(a, 64, 64, &mode_sprite) == 0);
    mode_draw.source = mode_sprite;   /* the previous link's surfaces are gone */
    const noodles_sprite_descriptor_t *mode_desc =
        (const noodles_sprite_descriptor_t *)descriptor_memory;
    mode_draw.flags = NOODLES_DRAW_MODE_MUL | NOODLES_DRAW_MIRROR_X;
    mode_draw.modulation = 0x80ff40ffu;
    assert(noodles_surface_draw_batch(a, NULL, &mode_draw, 1) == 0);
    assert(mode_desc[0].flags == (NOODLES_DRAW_MODE_MUL | NOODLES_DRAW_MIRROR_X) &&
           mode_desc[0].colorkey == 0x80ff40ffu);
    assert(noodles_link_drain(a, 10) == 0);
    mode_draw.flags = NOODLES_DRAW_MODE_STENCIL_ALPHA;
    assert(noodles_surface_draw_batch(a, NULL, &mode_draw, 1) == 0);
    assert(noodles_link_drain(a, 10) == 0);
    const uint32_t bad_modes[] = {
        NOODLES_DRAW_MODE_ADD | NOODLES_DRAW_BLEND,          /* mode replaces BLEND */
        NOODLES_DRAW_MODE_ADD | NOODLES_DRAW_KEY,            /* flagged draws cannot key */
        NOODLES_DRAW_MODE_ADD | 0x200u,                      /* reserved bit 9 */
        NOODLES_DRAW_MODE_ADD | 0x20u,                       /* reserved bit 5 */
        NOODLES_DRAW_BLEND_MODE(0, 1, 1, 1, 1, 1),            /* factor 0 */
        NOODLES_DRAW_BLEND_MODE(11, 1, 1, 1, 1, 1),           /* factor 11 */
        NOODLES_DRAW_BLEND_MODE(1, 1, 6, 1, 1, 1),            /* operation 6 */
        NOODLES_DRAW_BLEND_MODE(1, 1, NOODLES_BLENDOP_SUBTRACT, 1, 1, 1) |
            NOODLES_DRAW_SINGLE_ROUNDING,                   /* single rounding needs ADD */
        NOODLES_DRAW_BLEND | 0x100u,                         /* mode bits without bit 4 */
    };
    for (size_t k = 0; k < sizeof(bad_modes) / sizeof(bad_modes[0]); ++k) {
        mode_draw.flags = bad_modes[k];
        before = memory[0];
        assert(noodles_surface_draw_batch(a, NULL, &mode_draw, 1) == -1 && errno == EINVAL);
        assert(memory[0] == before);
    }
    assert(noodles_surface_destroy(mode_sprite) == 0);
    closed(a);

    /* CPU back-buffer transfers preserve host pitch, follow the observed
     * buffer role, refuse a pending present and clip hardware fills. */
    memory[0] = memory[2] = memory[3] = 0;
    seed_identity();
    a = open_verified();
    complete_on_sleep = 1;
    noodles_rect_t back_rect = {2, 3, 2, 2};
    uint32_t back_upload[6] = {0x01020304, 0x11121314, 0xdeadbeef,
                               0x21222324, 0x31323334, 0xcafebabe};
    uint32_t back_read[6] = {0};
    assert(noodles_back_buffer_update(a, &back_rect, back_upload, 12, 10) == 0);
    assert(noodles_back_buffer_read(a, &back_rect, back_read, 12, 10) == 0);
    assert(back_read[0] == back_upload[0] && back_read[1] == back_upload[1] &&
           back_read[2] == 0 && back_read[3] == back_upload[3] &&
           back_read[4] == back_upload[4] && back_read[5] == 0);
    noodles_rect_t bad_back_rect = {799, 599, 2, 2};
    assert(noodles_back_buffer_read(a, &bad_back_rect, back_read, 12, 10) == -1 &&
           errno == EINVAL);
    noodles_rect_t clipped_back_fill = {-4, -5, 10, 12};
    slot = memory[0];
    assert(noodles_back_buffer_fill(a, &clipped_back_fill, 0x55667788) == 0);
    published = &memory[1024 + slot * 8];
    assert(published[0] == 1 && published[1] == NOODLES_BUFFER_B_ADDR &&
           published[2] == NOODLES_BUFFER_PITCH && published[3] == 6 &&
           published[4] == 7 && published[5] == 0x55667788);
    noodles_rect_t clipped_blend_fill = {-2, 4, 9, 6};
    slot = memory[0];
    assert(noodles_back_buffer_blend_fill(a, &clipped_blend_fill, 0x80402010u,
                                          NOODLES_DRAW_MODE_ADD) == 0);
    published = &memory[1024 + slot * 8];
    assert(published[0] == 8 && published[1] == NOODLES_BUFFER_B_ADDR + 4 * 3200 &&
           published[2] == NOODLES_BUFFER_PITCH && published[3] == 7 &&
           published[4] == 6 && published[5] == 0x80402010u &&
           published[6] == NOODLES_DRAW_MODE_ADD && published[7] == 0);
    before = memory[0];
    assert(noodles_back_buffer_blend_fill(a, &clipped_blend_fill, 0x80402010u,
                                          NOODLES_DRAW_BLEND) == -1 && errno == EINVAL &&
           memory[0] == before);
    noodles_surface_t *fill_surface = NULL;
    assert(noodles_surface_create(a, 32, 24, &fill_surface) == 0);
    noodles_rect_t managed_blend_fill = {28, 20, 10, 10};
    slot = memory[0];
    assert(noodles_surface_blend_fill(fill_surface, &managed_blend_fill, 0x40112233u,
                                      NOODLES_DRAW_MODE_MUL) == 0);
    published = &memory[1024 + slot * 8];
    assert(published[0] == 8 && published[3] == 4 && published[4] == 4 &&
           published[5] == 0x40112233u && published[6] == NOODLES_DRAW_MODE_MUL);
    assert(noodles_surface_destroy(fill_surface) == 0);
    assert(noodles_push_present(a, &fence) == 0);
    assert(noodles_back_buffer_read(a, &back_rect, back_read, 12, 10) == -1 &&
           errno == EAGAIN);
    assert(noodles_link_wait(a, fence, 10) == 0);
    assert(noodles_link_back_buffer(a) == NOODLES_BUFFER_A_ADDR);
    assert(noodles_back_buffer_update(a, &back_rect, back_upload, 12, 10) == 0);
    assert(!memcmp(back_buffer_memory[0] + 3 * NOODLES_BUFFER_PITCH + 2 * 4,
                   back_upload, 8));
    closed(a);

    /* A raw fence that retires after the backoff has grown still gets a
     * minimum-length ping check, including across fence wraparound. */
    memory[0] = memory[2] = 0;
    memory[3] = 0x7fffffffu;
    a = open_verified();
    assert(noodles_push_command(a, fill) == 0);
    assert(noodles_link_last_fence(a) == 0);
    complete_on_sleep = 0;
    retire_after_sleeps = 4;
    retire_fence = 0;
    max_pause_ns = 0;
    assert(noodles_link_wait(a, 0, 10) == 0);
    assert(max_pause_ns == 100000 && last_pause_ns == 20000);
    closed(a);

    /* Reset while a ping is outstanding faults the waiter instead of
     * accepting the reset-cleared fence as completion. */
    memory[0] = memory[2] = memory[3] = 0;
    a = open_verified();
    assert(noodles_push_command(a, fill) == 0);
    memory[2] = memory[0];
    memory[3] = 1;
    assert(noodles_link_poll(a, 1, &done) == 0 && !done);
    control_active = 0;
    memory[0] = memory[2] = memory[3] = memory[16] = 0;
    assert(noodles_link_wait(a, 1, 10) == -1 && errno == ESTALE);
    assert(noodles_link_close(a, 10) == -1 && errno == ESTALE);
    seed_identity();

    /* An FPGA reset clears the response and faults the stale handle before
     * a reset fence can be accepted as completion. A new live core may then
     * recover a dirty software marker without a blind acknowledgement flag. */
    a = open_verified();
    assert(noodles_push_command(a, fill) == 0);
    control_active = 0;
    memory[0] = memory[2] = memory[3] = memory[16] = 0;
    assert(noodles_link_poll(a, 0, &done) == -1 && errno == ESTALE);
    assert(noodles_link_close(a, 10) == -1 && errno == ESTALE);
    seed_identity();
    a = open_verified();
    closed(a);

    assert(maps == unmaps);
    assert(unlink(lock_path) == 0 && rmdir(dir) == 0);
    puts("PASS: legacy/verified SDK lifecycle, identity, reset loss, locking, deadlines and validation");
    return 0;
}
