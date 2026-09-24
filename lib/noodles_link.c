// Implementation of noodles_link.h: stage-2B session control plus the
// LINK-002/LINK-003 command transport.

#define _POSIX_C_SOURCE 200809L
#include "noodles_link_internal.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <stdlib.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <time.h>
#include <unistd.h>

#define NOODLES_HEADER_ADDR 0x30020000u
#define NOODLES_SLOT_BASE_ADDR 0x30021000u
#define NOODLES_RING_SLOTS 64u
#define NOODLES_SLOT_WORDS 8u
#define NOODLES_MAP_SPAN 0x2000u  // header/control block and all 64 command slots

#define NOODLES_OP_SOLID_FILL 1u
#define NOODLES_OP_BLIT_COPY 2u
#define NOODLES_OP_BLIT_COPY_KEY 3u
#define NOODLES_OP_PRESENT 4u
#define NOODLES_OP_SPRITE_BATCH 5u
#define NOODLES_OP_LOAD_SDRAM 6u
#define NOODLES_OP_BLIT_BLEND 7u
#define NOODLES_OP_BLEND_FILL 8u
#define NOODLES_FENCE_MASK 0x7fffffffu
// Wait-loop sleep backoff. The minimum covers link_control's 1024-cycle poll
// period plus a DDR3 round trip, so a liveness ping is normally answered by
// the first check after it is issued. The cap matches the pre-SDK tools'
// 0.1ms fence poll; a flat 1ms sleep cost about 2ms per verified wait.
#define NOODLES_POLL_MIN_NS 20000u
#define NOODLES_POLL_MAX_NS 100000u
#define NOODLES_CONTROL_MAGIC 0x4e444c53u
#define NOODLES_CONTROL_CLAIM 0x434c414du
#define NOODLES_REQUIRED_CAPABILITIES 0x0000007eu
#define NOODLES_CONTROL_MAGIC_WORD 4u
#define NOODLES_CONTROL_PROTOCOL_WORD 5u
#define NOODLES_CONTROL_CAPABILITIES_WORD 6u
#define NOODLES_CONTROL_GEOMETRY_WORD 7u
#define NOODLES_CONTROL_PITCH_WORD 8u
#define NOODLES_CONTROL_REQUEST_TOKEN_LO_WORD 10u
#define NOODLES_CONTROL_REQUEST_TOKEN_HI_WORD 11u
#define NOODLES_CONTROL_REQUEST_SEQ_WORD 12u
#define NOODLES_CONTROL_RESPONSE_TOKEN_LO_WORD 14u
#define NOODLES_CONTROL_RESPONSE_TOKEN_HI_WORD 15u
#define NOODLES_CONTROL_RESPONSE_SEQ_WORD 16u

static int fail(int error) {
    errno = error;
    return -1;
}

static int session_error(const noodles_link_t *link) {
    if (!link->verified) return 0;
    __sync_synchronize();
    if (link->header[NOODLES_CONTROL_RESPONSE_SEQ_WORD] == 0 ||
        link->header[NOODLES_CONTROL_RESPONSE_TOKEN_LO_WORD] != link->token_lo ||
        link->header[NOODLES_CONTROL_RESPONSE_TOKEN_HI_WORD] != link->token_hi) {
        return ESTALE;
    }
    return 0;
}

int noodles_link_check(noodles_link_t *link) {
    if (!link) return fail(EINVAL);
    if (link->fault) return fail(link->fault);
    int error = session_error(link);
    if (error) {
        link->fault = error;
        return fail(error);
    }
    return 0;
}

static int mark_session(noodles_link_t *link, char state) {
    ssize_t written = pwrite(link->lock_fd, &state, 1, 0);
    if (written < 0) return -1;
    if (written != 1) return fail(EIO);
    return fsync(link->lock_fd);
}

static int monotonic_ns(uint64_t *value) {
    struct timespec time;
    if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) return -1;
    *value = (uint64_t)time.tv_sec * 1000000000u + (uint64_t)time.tv_nsec;
    return 0;
}

static int pause_until(uint64_t deadline, uint32_t *step) {
    uint64_t now;
    if (monotonic_ns(&now) != 0) return -1;
    if (now >= deadline) return fail(ETIMEDOUT);
    uint64_t remaining = deadline - now;
    struct timespec pause = {0, remaining < *step ? (long)remaining : (long)*step};
    *step = *step >= NOODLES_POLL_MAX_NS / 2 ? NOODLES_POLL_MAX_NS : *step * 2;
    if (nanosleep(&pause, NULL) != 0 && errno != EINTR) return -1;
    return 0;
}

static int random_token(uint32_t *lo, uint32_t *hi) {
    uint32_t token[2];
    size_t offset = 0;
    while (offset < sizeof(token)) {
        ssize_t got = getrandom((char *)token + offset, sizeof(token) - offset, 0);
        if (got < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (got == 0) return fail(EIO);
        offset += (size_t)got;
    }
    if (token[0] == 0 && token[1] == 0) token[0] = 1;
    *lo = token[0];
    *hi = token[1];
    return 0;
}

static void request_sequence(noodles_link_t *link, uint32_t sequence) {
    __sync_synchronize();
    link->header[NOODLES_CONTROL_REQUEST_SEQ_WORD] = sequence;
    __sync_synchronize();
}

static int wait_response_until(noodles_link_t *link, uint32_t sequence, uint64_t deadline) {
    uint32_t step = NOODLES_POLL_MIN_NS;
    for (;;) {
        __sync_synchronize();
        if (link->header[NOODLES_CONTROL_RESPONSE_SEQ_WORD] == sequence &&
            (!sequence ||
             (link->header[NOODLES_CONTROL_RESPONSE_TOKEN_LO_WORD] == link->token_lo &&
              link->header[NOODLES_CONTROL_RESPONSE_TOKEN_HI_WORD] == link->token_hi))) {
            return 0;
        }
        if (pause_until(deadline, &step) != 0) return -1;
    }
}

static int wait_response(noodles_link_t *link, uint32_t sequence, uint32_t timeout_ms) {
    uint64_t start;
    if (monotonic_ns(&start) != 0) return -1;
    return wait_response_until(link, sequence, start + (uint64_t)timeout_ms * 1000000u);
}

static int initialize_transport(noodles_link_t *link) {
    link->write_ptr = link->header[0];
    uint32_t fence_state = link->header[3];
    link->done_baseline = fence_state & NOODLES_FENCE_MASK;
    link->confirmed_done = link->done_baseline;
    link->presents_completed = (fence_state >> 31) & 1u;
    if (link->write_ptr >= NOODLES_RING_SLOTS || link->header[2] >= NOODLES_RING_SLOTS)
        return fail(EPROTO);
    if (link->write_ptr != link->header[2]) return fail(EBUSY);
    return 0;
}

static int open_common(noodles_link_t **out, int verified, int ack_reload) {
    if (!out) return fail(EINVAL);
    *out = NULL;
    if (verified && ack_reload) return fail(EINVAL);
    if (!verified && ack_reload != 0 && ack_reload != 1) return fail(EINVAL);
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
    int dirty = got && state != 'C';
    if (!verified && dirty && !ack_reload) {
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

    if (verified) {
        if (link->header[NOODLES_CONTROL_MAGIC_WORD] != NOODLES_CONTROL_MAGIC) {
            errno = ENODEV;
            goto failed;
        }
        if ((link->header[NOODLES_CONTROL_PROTOCOL_WORD] >> 16) !=
            (NOODLES_PROTOCOL_VERSION >> 16)) {
            errno = EPROTONOSUPPORT;
            goto failed;
        }
        uint32_t geometry = link->header[NOODLES_CONTROL_GEOMETRY_WORD];
        if ((link->header[NOODLES_CONTROL_CAPABILITIES_WORD] &
             NOODLES_REQUIRED_CAPABILITIES) != NOODLES_REQUIRED_CAPABILITIES ||
            (geometry >> 16) != NOODLES_BUFFER_WIDTH ||
            (geometry & 0xffffu) != NOODLES_BUFFER_HEIGHT ||
            link->header[NOODLES_CONTROL_PITCH_WORD] != NOODLES_BUFFER_PITCH) {
            errno = ENOTSUP;
            goto failed;
        }
        link->capabilities = link->header[NOODLES_CONTROL_CAPABILITIES_WORD];
        link->protocol = link->header[NOODLES_CONTROL_PROTOCOL_WORD];
        uint32_t response = link->header[NOODLES_CONTROL_RESPONSE_SEQ_WORD];
        if (response != 0) {
            errno = dirty ? EOWNERDEAD : EBUSY;
            goto failed;
        }
        if (random_token(&link->token_lo, &link->token_hi) != 0) goto failed;
        link->header[NOODLES_CONTROL_REQUEST_TOKEN_LO_WORD] = link->token_lo;
        link->header[NOODLES_CONTROL_REQUEST_TOKEN_HI_WORD] = link->token_hi;
        link->verified = 1;
        request_sequence(link, NOODLES_CONTROL_CLAIM);
        if (wait_response(link, NOODLES_CONTROL_CLAIM, NOODLES_DEFAULT_TIMEOUT_MS) != 0)
            goto failed;
    } else if (link->header[NOODLES_CONTROL_MAGIC_WORD] == NOODLES_CONTROL_MAGIC &&
               (link->header[NOODLES_CONTROL_PROTOCOL_WORD] >> 16) ==
                   (NOODLES_PROTOCOL_VERSION >> 16)) {
        errno = EPROTONOSUPPORT;
        goto failed;
    } else {
        link->capabilities = NOODLES_REQUIRED_CAPABILITIES;
    }

    if (initialize_transport(link) != 0) goto failed;
    /* Empty ring proves readiness only after the stage-2B claim gates it. */
    if (mark_session(link, 'D') != 0) goto failed;
    *out = link;
    return 0;
failed: {
    int saved = errno;
    if (link->verified && link->map && link->map != MAP_FAILED)
        request_sequence(link, 0);
    if (link->map && link->map != MAP_FAILED) munmap(link->map, NOODLES_MAP_SPAN);
    if (link->fd >= 0) close(link->fd);
    if (link->lock_fd >= 0) close(link->lock_fd);
    free(link);
    return fail(saved);
}
}

int noodles_link_open(noodles_link_t **out) {
    return open_common(out, 1, 0);
}

int noodles_link_open_legacy(noodles_link_t **out, int ack_reload) {
    return open_common(out, 0, ack_reload);
}

int noodles_link_close(noodles_link_t *link, uint32_t timeout_ms) {
    if (!link) return fail(EINVAL);
    uint64_t start = 0, deadline = 0;
    int error = 0;
    if (noodles_link_check(link) != 0) {
        error = errno;
    } else if (monotonic_ns(&start) != 0) {
        error = errno;
    } else {
        deadline = start + (uint64_t)timeout_ms * 1000000u;
    }
    if (!error) {
        uint32_t step = NOODLES_POLL_MIN_NS;
        for (;;) {
            int complete;
            int pinging = link->ping_pending;
            if (noodles_link_poll(link, noodles_link_last_fence(link), &complete) != 0) {
                error = errno;
                break;
            }
            if (complete) break;
            if (!pinging && link->ping_pending) step = NOODLES_POLL_MIN_NS;
            if (pause_until(deadline, &step) != 0) {
                error = errno;
                link->fault = error;
                break;
            }
        }
    }
    if (!error && link->verified) {
        request_sequence(link, 0);
        if (wait_response_until(link, 0, deadline) != 0) error = errno;
    }
    if (munmap(link->map, link->map_span) != 0 && !error) error = errno;
    if (close(link->fd) != 0 && !error) error = errno;
    if (!error && mark_session(link, 'C') != 0) {
        error = errno;
        /* Best effort to retain dirty state if persisting clean state failed. */
        if (mark_session(link, 'D') != 0) error = errno;
    }
    if (close(link->lock_fd) != 0 && !error) error = errno;
    noodles_surface_link_cleanup(link);
    free(link);
    return error ? fail(error) : 0;
}

int noodles_link_get_info(const noodles_link_t *link, noodles_device_info_t *info) {
    if (!link) return fail(EINVAL);
    if (link->fault) return fail(link->fault);
    int error = session_error(link);
    if (error) return fail(error);
    if (!info) return fail(EINVAL);
    uint32_t geometry = link->verified ? link->header[NOODLES_CONTROL_GEOMETRY_WORD] :
                                        (NOODLES_BUFFER_WIDTH << 16) | NOODLES_BUFFER_HEIGHT;
    *info = (noodles_device_info_t){
        geometry >> 16,
        geometry & 0xffffu,
        link->verified ? link->header[NOODLES_CONTROL_PITCH_WORD] : NOODLES_BUFFER_PITCH,
        link->verified ? link->header[NOODLES_CONTROL_CAPABILITIES_WORD] :
                         NOODLES_REQUIRED_CAPABILITIES,
        link->verified ? link->header[NOODLES_CONTROL_PROTOCOL_WORD] : 0,
        link->verified,
        NOODLES_SDK_VERSION,
    };
    return 0;
}

uint32_t noodles_rgb(uint8_t r, uint8_t g, uint8_t b) {
    return (uint32_t)r | ((uint32_t)g << 8) | ((uint32_t)b << 16);
}

int noodles_link_fence_reached(const noodles_link_t *link, uint32_t target) {
    return ((noodles_link_done_count(link) - target) & NOODLES_FENCE_MASK) < 0x40000000u;
}

static int confirmed_fence_reached(const noodles_link_t *link, uint32_t target) {
    return ((link->confirmed_done - target) & NOODLES_FENCE_MASK) < 0x40000000u;
}

noodles_fence_t noodles_link_last_fence(const noodles_link_t *link) {
    return (link->done_baseline + link->submitted) & NOODLES_FENCE_MASK;
}

int noodles_link_poll(noodles_link_t *link, noodles_fence_t target, int *complete) {
    if (noodles_link_check(link) != 0) return -1;
    if (!complete) return fail(EINVAL);
    __sync_synchronize();
    int reached = confirmed_fence_reached(link, target);
    if (!reached) {
        reached = noodles_link_fence_reached(link, target);
        if (reached && link->verified) {
            if (!link->ping_pending) {
                do {
                    ++link->ping_seq;
                } while (link->ping_seq == 0 || link->ping_seq == NOODLES_CONTROL_CLAIM);
                request_sequence(link, link->ping_seq);
                link->ping_pending = 1;
                reached = 0;
            } else if (link->header[NOODLES_CONTROL_RESPONSE_SEQ_WORD] == link->ping_seq) {
                link->ping_pending = 0;
                link->confirmed_done = noodles_link_done_count(link);
            } else {
                reached = 0;
            }
        } else if (reached) {
            link->confirmed_done = noodles_link_done_count(link);
        }
    }
    *complete = reached;
    if (reached && link->present_pending &&
        noodles_link_fence_reached(link, link->present_fence)) {
        link->presents_completed = (link->header[3] >> 31) & 1u;
        link->present_pending = 0;
    }
    return 0;
}

int noodles_link_wait(noodles_link_t *link, noodles_fence_t target, uint32_t timeout_ms) {
    if (noodles_link_check(link) != 0) return -1;
    uint64_t start;
    if (monotonic_ns(&start) != 0) { link->fault = errno; return -1; }
    uint64_t deadline = start + (uint64_t)timeout_ms * 1000000u;
    uint32_t step = NOODLES_POLL_MIN_NS;
    for (;;) {
        int complete;
        int pinging = link->ping_pending;
        if (noodles_link_poll(link, target, &complete) != 0) return -1;
        if (complete) return 0;
        // A new ping is answered within microseconds; do not let a long
        // raw-fence wait's backoff delay observing it.
        if (!pinging && link->ping_pending) step = NOODLES_POLL_MIN_NS;
        if (pause_until(deadline, &step) != 0) {
            link->fault = errno;
            return -1;
        }
    }
}

int noodles_link_drain(noodles_link_t *link, uint32_t timeout_ms) {
    if (noodles_link_check(link) != 0) return -1;
    return noodles_link_wait(link, noodles_link_last_fence(link), timeout_ms);
}

static int submission_ready(noodles_link_t *link) {
    if (noodles_link_check(link) != 0) return -1;
    return link->present_pending ? fail(EAGAIN) : 0;
}

static int overlaps_managed_arena(uint32_t address, uint64_t bytes) {
    uint64_t end = (uint64_t)address + bytes;
    uint64_t arena_end = (uint64_t)NOODLES_SURFACE_ARENA_ADDR + NOODLES_SURFACE_ARENA_BYTES;
    return address < arena_end && end > NOODLES_SURFACE_ARENA_ADDR;
}

static int valid_span(uint32_t address, uint64_t bytes, int allow_managed) {
    uint64_t end = (uint64_t)address + bytes;
    return bytes && address >= 0x30000000u && end <= 0x40000000ull &&
        !(address < 0x30022800u && end > 0x30020000u) &&
        (allow_managed || !overlaps_managed_arena(address, bytes));
}

static int valid_rect(uint32_t address, uint32_t pitch, uint32_t width, uint32_t height,
                      int allow_managed) {
    return width && height && width <= 65535 && height <= 65535 &&
        pitch <= 65535 && !(pitch & 3) && !(address & 3) &&
        pitch >= (uint64_t)width * 4 &&
        valid_span(address, (uint64_t)(height - 1) * pitch + (uint64_t)width * 4,
                   allow_managed);
}

static uint64_t rect_end(uint32_t address, uint32_t pitch, uint32_t width, uint32_t height) {
    return (uint64_t)address + (uint64_t)(height - 1) * pitch + (uint64_t)width * 4;
}

static int valid_mode(uint32_t f);

static int valid_command(const uint32_t *c, int allow_managed) {
    if (!c) return 0;
    switch (c[0]) {
    case NOODLES_OP_SOLID_FILL:
        return !c[6] && !c[7] && valid_rect(c[1], c[2], c[3], c[4], allow_managed);
    case NOODLES_OP_BLIT_COPY:
    case NOODLES_OP_BLIT_COPY_KEY:
        return (c[0] != NOODLES_OP_BLIT_COPY || !c[5]) &&
            valid_rect(c[1], c[2], c[3], c[4], allow_managed) &&
            valid_rect(c[6], c[7], c[3], c[4], allow_managed);
    case NOODLES_OP_BLIT_BLEND:
        /* Byte spans, not just pixels, must be disjoint: stricter than
         * BLIT-007 but checkable without per-row arithmetic. */
        return c[5] <= 0xffu &&
            valid_rect(c[1], c[2], c[3], c[4], allow_managed) &&
            valid_rect(c[6], c[7], c[3], c[4], allow_managed) &&
            (rect_end(c[1], c[2], c[3], c[4]) <= c[6] ||
             rect_end(c[6], c[7], c[3], c[4]) <= c[1]);
    case NOODLES_OP_BLEND_FILL:
        return !c[7] && !(c[6] & (NOODLES_DRAW_MIRROR_X | NOODLES_DRAW_MIRROR_Y)) &&
            valid_mode(c[6]) && valid_rect(c[1], c[2], c[3], c[4], allow_managed);
    case NOODLES_OP_PRESENT:
        return !(c[1] | c[2] | c[3] | c[4] | c[5] | c[6] | c[7]);
    case NOODLES_OP_SPRITE_BATCH:
        return c[1] == NOODLES_SPRITE_DESCRIPTOR_ADDR && c[3] >= 1 &&
            c[3] <= NOODLES_SPRITE_DESCRIPTOR_MAX && !(c[2] | c[4] | c[5] | c[6] | c[7]);
    case NOODLES_OP_LOAD_SDRAM: {
        uint64_t length = ((uint64_t)c[5] + 1023) & ~1023ull;
        return !(c[2] | c[3] | c[4] | c[7]) && c[5] &&
            !(c[1] & 1023) && !(c[6] & 7) &&
            (uint64_t)c[1] + length <= NOODLES_SDRAM_WINDOW_BYTES &&
            valid_span(c[6], length, allow_managed);
    }
    default: return 0;
    }
}

/* An explicit mode's fields (BLIT-009): SDL factors 1-10, operations 1-5,
 * single rounding only with two ADDs, reserved bits 7:5 and 9 clear. */
static int valid_mode(uint32_t f) {
    const uint32_t csf = f >> 10 & 0xfu, cdf = f >> 14 & 0xfu, cop = f >> 18 & 0x7u;
    const uint32_t asf = f >> 21 & 0xfu, adf = f >> 25 & 0xfu, aop = f >> 29 & 0x7u;
    return !(f & 0x2e0u) && !(f & NOODLES_DRAW_BLEND) &&
        csf >= 1 && csf <= 10 && cdf >= 1 && cdf <= 10 && asf >= 1 && asf <= 10 &&
        adf >= 1 && adf <= 10 && cop >= 1 && cop <= 5 && aop >= 1 && aop <= 5 &&
        (!(f & NOODLES_DRAW_SINGLE_ROUNDING) ||
         (cop == NOODLES_BLENDOP_ADD && aop == NOODLES_BLENDOP_ADD));
}

/* Descriptor checks shared by the raw and managed batch paths: 0, or the
 * errno to fail with. Flagged draws (BLIT-008) need protocol 1.2 and
 * explicit modes (BLIT-009) 1.3; both carry their modulation in the
 * colour-key word and so cannot also be keyed, and must not read the
 * rectangle they write. */
static int check_descriptors(const noodles_link_t *link, const noodles_sprite_descriptor_t *d,
                             unsigned count, int allow_managed) {
    for (unsigned i = 0; i < count; ++i, ++d) {
        const int explicit_mode = (d->flags & NOODLES_DRAW_MODE) != 0;
        if ((explicit_mode ? !valid_mode(d->flags) : d->flags > NOODLES_DRAW_FLAGS_MASK) ||
            !valid_rect(d->dst_addr, d->dst_pitch, d->width, d->height, allow_managed) ||
            !valid_rect(d->src_addr, d->src_pitch, d->width, d->height, allow_managed))
            return EINVAL;
        if (!(d->flags & ~NOODLES_DRAW_KEY)) continue;
        if ((d->flags & NOODLES_DRAW_KEY) ||
            !(rect_end(d->dst_addr, d->dst_pitch, d->width, d->height) <= d->src_addr ||
              rect_end(d->src_addr, d->src_pitch, d->width, d->height) <= d->dst_addr))
            return EINVAL;
        if ((link->protocol & 0xffffu) < (explicit_mode ? 3u : 2u)) return ENOTSUP;
    }
    return 0;
}

static int descriptors_available(noodles_link_t *link) {
    if (link->batch_pending) {
        int complete;
        if (link->verified) {
            if (noodles_link_poll(link, link->batch_fence, &complete) != 0) return 0;
        } else {
            complete = noodles_link_fence_reached(link, link->batch_fence);
        }
        if (!complete) {
            errno = EAGAIN;
            return 0;
        }
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

static int push_command(noodles_link_t *link, const uint32_t command[8], int allow_managed) {
    if (submission_ready(link) != 0) return -1;
    if (!valid_command(command, allow_managed)) {
        errno = EINVAL;
        return -1;
    }
    if (command[0] < 32 && !(link->capabilities & (1u << command[0])))
        return fail(ENOTSUP);
    int is_batch = (command[0] & 0xffu) == NOODLES_OP_SPRITE_BATCH;
    // Reap completed ownership on every push, including long runs of non-batch work.
    int available = descriptors_available(link);
    if (!available && errno != EAGAIN) return -1;
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

int noodles_push_command(noodles_link_t *link, const uint32_t command[8]) {
    return push_command(link, command, 0);
}

int noodles_link_push_command_managed(noodles_link_t *link, const uint32_t command[8]) {
    return push_command(link, command, 1);
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

int noodles_push_blit_blend(noodles_link_t *link, uint32_t dst_addr, uint16_t dst_pitch,
                            uint32_t src_addr, uint16_t src_pitch, uint16_t width,
                            uint16_t height, uint8_t alpha_mod) {
    const uint32_t command[8] = {
        NOODLES_OP_BLIT_BLEND, dst_addr, dst_pitch, width, height, alpha_mod, src_addr, src_pitch,
    };
    return noodles_push_command(link, command);
}

int noodles_push_blend_fill(noodles_link_t *link, uint32_t dst_addr, uint16_t dst_pitch,
                            uint16_t width, uint16_t height, uint32_t color,
                            uint32_t blend_mode) {
    const uint32_t command[8] = {
        NOODLES_OP_BLEND_FILL, dst_addr, dst_pitch, width, height, color, blend_mode, 0,
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
    int invalid = check_descriptors(link, descriptors, count, 0);
    if (invalid) return fail(invalid);
    if (!descriptors_available(link) || !ring_has_space(link)) return -1;
    if (noodles_link_upload(link, NOODLES_SPRITE_DESCRIPTOR_ADDR, descriptors,
                             (size_t)count * sizeof(*descriptors)) != 0) return -1;
    const uint32_t command[8] = {
        NOODLES_OP_SPRITE_BATCH, NOODLES_SPRITE_DESCRIPTOR_ADDR, 0, count, 0, 0, 0, 0,
    };
    return push_command(link, command, 0);
}

int noodles_link_push_sprite_descriptors_managed(
    noodles_link_t *link, const noodles_sprite_descriptor_t *descriptors, uint16_t count) {
    if (submission_ready(link) != 0) return -1;
    if (!descriptors || count == 0 || count > NOODLES_SPRITE_DESCRIPTOR_MAX) {
        errno = EINVAL;
        return -1;
    }
    int invalid = check_descriptors(link, descriptors, count, 1);
    if (invalid) return fail(invalid);
    if (!descriptors_available(link) || !ring_has_space(link)) return -1;
    if (noodles_link_upload(link, NOODLES_SPRITE_DESCRIPTOR_ADDR, descriptors,
                             (size_t)count * sizeof(*descriptors)) != 0) return -1;
    const uint32_t command[8] = {
        NOODLES_OP_SPRITE_BATCH, NOODLES_SPRITE_DESCRIPTOR_ADDR, 0, count, 0, 0, 0, 0,
    };
    return push_command(link, command, 1);
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
        (!descriptor_upload && !valid_span(dst_addr, size_bytes, 0))) return fail(EINVAL);
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
