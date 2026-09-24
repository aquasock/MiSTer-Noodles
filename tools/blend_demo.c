// BLIT_BLEND (BLIT-007) hardware check, throughput bench and visual demo.
//
//   blend-demo verify              managed-surface blends of random pixels at
//                                  every alignment pairing and several alpha
//                                  modulations, read back and compared with
//                                  the C reference model pixel for pixel
//   blend-demo bench [seconds]     64 blended 128x128 sprites per fence wait
//                                  into the back buffer, no PRESENT
//   blend-demo show [seconds] [n]  n translucent sprites with varying alpha
//                                  modulation drifting over colour bars
#define _POSIX_C_SOURCE 200809L
#include "noodles_link.h"
#include "noodles_surface.h"
#include "sdk_helpers.h"
#include "../sim/blend_ref.h"

#include <errno.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define SPRITE 128
#define MAX_SHOW 64

static double now_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec * 1e-9;
}

static uint32_t rng_state = 0x6e646c42u;
static uint32_t next_random(void) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

// Retries submissions that only failed because the ring or table was busy.
#define RETRY(call)                                                        \
    ({                                                                     \
        int rc_ = -1;                                                      \
        struct timespec delay_ = {0, 50000};                               \
        for (unsigned try_ = 0; try_ < 40000; ++try_) {                    \
            rc_ = (call);                                                  \
            if (rc_ == 0 || errno != EAGAIN) break;                        \
            nanosleep(&delay_, NULL);                                      \
        }                                                                  \
        rc_;                                                               \
    })

static void make_sprite(uint32_t *pixels) {
    const double c = (SPRITE - 1) / 2.0;
    for (int y = 0; y < SPRITE; ++y) {
        for (int x = 0; x < SPRITE; ++x) {
            double r = sqrt((x - c) * (x - c) + (y - c) * (y - c)) / (SPRITE / 2.0);
            uint32_t a = r >= 1.0 ? 0 : (uint32_t)(255.0 * (1.0 - r * r));
            uint32_t red = (uint32_t)(255 * x / (SPRITE - 1));
            uint32_t green = (uint32_t)(255 * y / (SPRITE - 1));
            uint32_t blue = 255 - red / 2;
            pixels[y * SPRITE + x] = (a << 24) | (blue << 16) | (green << 8) | red;
        }
    }
}

static int require_blend(noodles_link_t *link) {
    noodles_device_info_t info;
    if (noodles_link_get_info(link, &info) != 0) {
        perror("noodles_link_get_info");
        return -1;
    }
    if (!(info.opcode_mask & NOODLES_CAP_BLIT_BLEND)) {
        fprintf(stderr, "core protocol 0x%08x mask 0x%02x lacks BLIT_BLEND\n",
                info.protocol_version, info.opcode_mask);
        return -1;
    }
    return 0;
}

static int verify(noodles_link_t *link) {
    enum { DW = 300, DH = 40, SW = 131, SH = 33 };
    static uint32_t dst[DW * DH], src[SW * SH], expect[DW * DH], got[DW * DH];
    noodles_surface_t *ds = NULL, *ss = NULL;
    if (noodles_surface_create(link, DW, DH, &ds) != 0 ||
        noodles_surface_create(link, SW, SH, &ss) != 0) {
        perror("noodles_surface_create");
        return -1;
    }
    const noodles_rect_t whole_dst = {0, 0, DW, DH}, whole_src = {0, 0, SW, SH};
    const struct { int dx, dy, sx, sy, w, h, mod; } cases[] = {
        {0, 0, 0, 0, SW, SH, 255},   {1, 2, 0, 0, 128, 30, 255}, {0, 1, 1, 0, 128, 30, 200},
        {3, 0, 1, 1, 127, 31, 128},  {5, 3, 2, 0, 1, 20, 255},   {6, 4, 3, 2, 2, 17, 77},
        {7, 5, 0, 3, 3, 9, 1},       {100, 7, 5, 5, 64, 25, 0},  {169, 0, 0, 0, SW, SH, 254},
        {2, 6, 9, 1, 101, 27, 255},
    };
    unsigned long pixels = 0;
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        for (size_t p = 0; p < DW * DH; ++p) dst[p] = next_random();
        for (size_t p = 0; p < SW * SH; ++p) {
            uint32_t pick = next_random() % 4;
            uint32_t alpha = pick == 0 ? 0 : pick == 1 ? 255 : next_random() & 0xff;
            src[p] = (alpha << 24) | (next_random() & 0xffffff);
        }
        memcpy(expect, dst, sizeof(dst));
        for (int y = 0; y < cases[i].h; ++y)
            for (int x = 0; x < cases[i].w; ++x) {
                uint32_t *d = &expect[(cases[i].dy + y) * DW + cases[i].dx + x];
                *d = noodles_blend_ref(src[(cases[i].sy + y) * SW + cases[i].sx + x], *d,
                                       (uint32_t)cases[i].mod);
            }
        if (noodles_surface_update(ds, &whole_dst, dst, DW * 4, 2000) != 0 ||
            noodles_surface_update(ss, &whole_src, src, SW * 4, 2000) != 0) {
            perror("noodles_surface_update");
            return -1;
        }
        const noodles_rect_t rect = {cases[i].sx, cases[i].sy, (uint32_t)cases[i].w,
                                     (uint32_t)cases[i].h};
        if (RETRY(noodles_surface_blend(ds, cases[i].dx, cases[i].dy, ss, &rect,
                                        (uint8_t)cases[i].mod)) != 0) {
            perror("noodles_surface_blend");
            return -1;
        }
        if (noodles_surface_read(ds, &whole_dst, got, DW * 4, 2000) != 0) {
            perror("noodles_surface_read");
            return -1;
        }
        int bad = 0;
        for (int y = 0; y < DH; ++y)
            for (int x = 0; x < DW; ++x)
                if (got[y * DW + x] != expect[y * DW + x] && bad++ < 8)
                    fprintf(stderr, "case %zu: (%d,%d) got %08x want %08x was %08x\n", i, x, y,
                            got[y * DW + x], expect[y * DW + x], dst[y * DW + x]);
        if (bad) {
            fprintf(stderr, "FAIL: case %zu dst=(%d,%d) src=(%d,%d) %dx%d mod=%d: %d pixels\n",
                    i, cases[i].dx, cases[i].dy, cases[i].sx, cases[i].sy, cases[i].w,
                    cases[i].h, cases[i].mod, bad);
            return -1;
        }
        pixels += (unsigned long)cases[i].w * (unsigned long)cases[i].h;
    }
    noodles_surface_destroy(ds);
    noodles_surface_destroy(ss);
    printf("PASS: %zu hardware blend cases, %lu blended pixels bit-exact, surroundings unchanged\n",
           sizeof(cases) / sizeof(cases[0]), pixels);
    return 0;
}

static int bench(noodles_link_t *link, noodles_surface_t *sprite, double seconds) {
    const noodles_rect_t rect = {0, 0, SPRITE, SPRITE};
    long draws = 0;
    double start = now_seconds();
    while (now_seconds() - start < seconds) {
        for (int i = 0; i < 64; ++i) {
            int x = (i % 8) * 84, y = (i / 8) * 59;
            if (RETRY(noodles_surface_blend_to_back_buffer(link, x, y, sprite, &rect, 255)) != 0) {
                perror("blend");
                return -1;
            }
        }
        if (tool_wait(link, "blend completion") != 0) return -1;
        draws += 64;
    }
    double elapsed = now_seconds() - start;
    printf("bench: %ld blends of %dx%d in %.1fs, %.2f Mpixel/s\n", draws, SPRITE, SPRITE,
           elapsed, (double)draws * SPRITE * SPRITE / elapsed / 1e6);
    return 0;
}

static int show(noodles_link_t *link, noodles_surface_t *sprite, double seconds, int count) {
    static const uint32_t bars[8][3] = {
        {255, 255, 255}, {255, 255, 0}, {0, 255, 255}, {0, 255, 0},
        {255, 0, 255},   {255, 0, 0},   {0, 0, 255},   {24, 24, 24},
    };
    const noodles_rect_t rect = {0, 0, SPRITE, SPRITE};
    long frames = 0;
    double start = now_seconds();
    while (now_seconds() - start < seconds) {
        uint32_t back = noodles_link_back_buffer(link);
        for (int b = 0; b < 8; ++b) {
            if (RETRY(noodles_push_solid_fill(link, back + (uint32_t)b * 100 * 4,
                                              NOODLES_BUFFER_PITCH, 100, NOODLES_BUFFER_HEIGHT,
                                              noodles_rgb((uint8_t)bars[b][0], (uint8_t)bars[b][1],
                                                          (uint8_t)bars[b][2]))) != 0) {
                perror("fill");
                return -1;
            }
        }
        for (int i = 0; i < count; ++i) {
            double t = frames / 60.0 + i * 0.7;
            int x = (int)(336 + 330 * sin(t * (0.5 + 0.05 * i)));
            int y = (int)(236 + 230 * cos(t * (0.4 + 0.03 * i)));
            uint8_t mod = (uint8_t)(64 + (191 * i) / (count > 1 ? count - 1 : 1));
            if (RETRY(noodles_surface_blend_to_back_buffer(link, x, y, sprite, &rect, mod)) != 0) {
                perror("blend");
                return -1;
            }
        }
        if (RETRY(noodles_present_and_wait(link)) != 0) {
            perror("present");
            return -1;
        }
        ++frames;
    }
    double elapsed = now_seconds() - start;
    printf("show: %ld frames in %.1fs (%.1f fps), %d translucent %dx%d sprites over colour bars\n",
           frames, elapsed, frames / elapsed, count, SPRITE, SPRITE);
    return 0;
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "";
    double seconds = argc > 2 ? strtod(argv[2], NULL) : 15.0;
    int count = argc > 3 ? atoi(argv[3]) : 16;
    if ((strcmp(mode, "verify") && strcmp(mode, "bench") && strcmp(mode, "show")) ||
        seconds <= 0.0 || count < 1 || count > MAX_SHOW) {
        fprintf(stderr, "usage: %s verify | bench [seconds] | show [seconds] [1-%d]\n", argv[0],
                MAX_SHOW);
        return 2;
    }
    noodles_link_t *link = NULL;
    if (tool_open(&link) != 0) {
        perror("noodles_link_open");
        return 1;
    }
    int rc = require_blend(link);
    if (!rc && !strcmp(mode, "verify")) {
        rc = verify(link);
    } else if (!rc) {
        static uint32_t pixels[SPRITE * SPRITE];
        make_sprite(pixels);
        noodles_surface_t *sprite = NULL;
        const noodles_rect_t rect = {0, 0, SPRITE, SPRITE};
        if (noodles_surface_create(link, SPRITE, SPRITE, &sprite) != 0 ||
            noodles_surface_update(sprite, &rect, pixels, SPRITE * 4, 2000) != 0) {
            perror("sprite surface");
            rc = -1;
        } else {
            rc = !strcmp(mode, "bench") ? bench(link, sprite, seconds)
                                        : show(link, sprite, seconds, count);
        }
    }
    tool_close(link);
    return rc ? 1 : 0;
}
