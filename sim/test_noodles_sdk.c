#define _POSIX_C_SOURCE 200809L
#include "../lib/noodles_link.h"

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
static char lock_path[256];
static int map_fail, device_fail, complete_on_sleep, interrupt_sleep, clock_fail;
static int maps, unmaps, sleeps;
static int control_active;
static uint64_t now_ns;
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
    assert(length == sizeof(memory) && offset == 0x30020000);
    ++maps;
    return memory;
}

int __wrap_munmap(void *addr, size_t size) {
    assert(addr == memory && size == sizeof(memory));
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
    memory[6] = 0x7e;
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
    assert(noodles_link_drain(a, 3) == -1 && errno == ETIMEDOUT);
    assert(now_ns - start == 3000000);
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
    assert(info.opcode_mask == 0x7e);
    assert(noodles_push_command(a, fill) == 0);
    memory[2] = memory[0];
    memory[3] = 1;
    assert(noodles_link_wait(a, 1, 10) == 0);
    closed(a);
    assert(!control_active && memory[16] == 0);

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
