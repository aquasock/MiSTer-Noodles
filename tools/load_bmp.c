// Loads a real image asset and displays it -- proves noodles_link_upload()
// (a plain mmap+memcpy straight into DDR3, bypassing the ring/BLIT engines
// entirely, per DDR-002: DDRAM_* addresses are direct, unwindowed physical
// addresses) alongside the existing BLIT_COPY path. Every sprite in every
// demo before this was built out of SOLID_FILL rects; this is the first
// real decoded pixel data this project has ever gotten into DDR3.
//
// BMP parsing (uncompressed 24-bit only) lives in tools/bmp_loader.h,
// shared with tools/stress_demo.c. Any image editor/ImageMagick/PIL can
// produce a compatible file: `convert input.png -type TrueColor BMP3:out.bmp`
// or PIL's Image.save(..., "BMP").
//
// Usage, as root on the MiSTer:
//   ./load_bmp <file.bmp> [x] [y]
// x/y default to centering the image on the buffer. The image must fit
// within the configured framebuffer.

#define _POSIX_C_SOURCE 199309L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "../lib/noodles_link.h"
#include "bmp_loader.h"

// Shared off-screen scratch slot, same convention as blit_copy_push.c/
// blit_copy_key_push.c/sprite_demo.c.
#define SCRATCH_ADDR 0x31400000u

static int wait_fence(noodles_link_t *link, uint32_t done_before) {
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 1000000};  // 1ms
    for (int i = 0; i < 2000; ++i) {
        if (noodles_link_done_count(link) > done_before) return 0;
        nanosleep(&delay, NULL);
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <file.bmp> [x] [y]\n", argv[0]);
        return 1;
    }

    uint32_t width, height;
    uint32_t *converted = noodles_bmp_load(argv[1], &width, &height);
    if (!converted) return 1;

    noodles_link_t link;
    if (noodles_link_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        free(converted);
        return 1;
    }

    uint32_t src_pitch = width * 4;
    size_t upload_size = (size_t)height * src_pitch;
    if (noodles_link_upload(&link, SCRATCH_ADDR, converted, upload_size) != 0) {
        perror("noodles_link_upload");
        free(converted);
        noodles_link_close(&link);
        return 1;
    }
    free(converted);
    printf("uploaded %ux%u image (%zu bytes) to 0x%08x\n", width, height, upload_size,
           SCRATCH_ADDR);

    int x_off = (argc > 2) ? atoi(argv[2]) : (int)(NOODLES_BUFFER_WIDTH - width) / 2;
    int y_off = (argc > 3) ? atoi(argv[3]) : (int)(NOODLES_BUFFER_HEIGHT - height) / 2;

    uint32_t back = noodles_link_back_buffer(&link);

    uint32_t done_before = noodles_link_done_count(&link);
    if (noodles_push_solid_fill(&link, back, NOODLES_BUFFER_PITCH, NOODLES_BUFFER_WIDTH,
                                 NOODLES_BUFFER_HEIGHT, noodles_rgb(0, 0, 0)) != 0) {
        fprintf(stderr, "ring full clearing background\n");
        noodles_link_close(&link);
        return 1;
    }
    if (wait_fence(&link, done_before)) {
        fprintf(stderr, "background clear never completed\n");
        noodles_link_close(&link);
        return 1;
    }

    done_before = noodles_link_done_count(&link);
    uint32_t dst = back + (uint32_t)y_off * NOODLES_BUFFER_PITCH + (uint32_t)x_off * 4;
    if (noodles_push_blit_copy(&link, dst, NOODLES_BUFFER_PITCH, SCRATCH_ADDR, src_pitch,
                                (uint16_t)width, (uint16_t)height) != 0) {
        fprintf(stderr, "ring full pushing image copy\n");
        noodles_link_close(&link);
        return 1;
    }
    if (wait_fence(&link, done_before)) {
        fprintf(stderr, "image copy never completed\n");
        noodles_link_close(&link);
        return 1;
    }

    if (noodles_present_and_wait(&link) != 0) {
        fprintf(stderr, "present failed\n");
        noodles_link_close(&link);
        return 1;
    }

    printf("presented at (%d,%d)\n", x_off, y_off);
    noodles_link_close(&link);
    return 0;
}
