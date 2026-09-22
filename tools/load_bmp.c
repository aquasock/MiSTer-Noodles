// Loads a real image asset and displays it -- proves noodles_link_upload()
// (a plain mmap+memcpy straight into DDR3, bypassing the ring/BLIT engines
// entirely, per DDR-002: DDRAM_* addresses are direct, unwindowed physical
// addresses) alongside the existing BLIT_COPY path. Every sprite in every
// demo before this was built out of SOLID_FILL rects; this is the first
// real decoded pixel data this project has ever gotten into DDR3.
//
// Supports uncompressed 24-bit BMP only (BITMAPINFOHEADER) -- the simplest
// image format with zero decoding dependencies, deliberately not a
// general-purpose asset pipeline. Any image editor/ImageMagick/PIL can
// produce one: `convert input.png -type TrueColor BMP3:out.bmp` or
// PIL's Image.save(..., "BMP").
//
// Usage, as root on the MiSTer:
//   ./load_bmp <file.bmp> [x] [y]
// x/y default to centering the image on the buffer. The image must fit
// within the 640x480 buffer.

#define _POSIX_C_SOURCE 199309L
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "../lib/noodles_link.h"

// Shared off-screen scratch slot, same convention as blit_copy_push.c/
// blit_copy_key_push.c/sprite_demo.c.
#define SCRATCH_ADDR 0x31400000u

static uint32_t read_u32le(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t read_u16le(const unsigned char *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static int32_t read_i32le(const unsigned char *p) { return (int32_t)read_u32le(p); }

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

    FILE *f = fopen(argv[1], "rb");
    if (!f) {
        perror("fopen");
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long file_size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (file_size < 54) {
        fprintf(stderr, "file too small to be a BMP\n");
        fclose(f);
        return 1;
    }

    unsigned char *raw = malloc((size_t)file_size);
    if (!raw || fread(raw, 1, (size_t)file_size, f) != (size_t)file_size) {
        fprintf(stderr, "read failed\n");
        free(raw);
        fclose(f);
        return 1;
    }
    fclose(f);

    if (raw[0] != 'B' || raw[1] != 'M') {
        fprintf(stderr, "not a BMP file (missing 'BM' magic)\n");
        free(raw);
        return 1;
    }
    uint32_t pixel_offset = read_u32le(raw + 10);
    uint32_t dib_size = read_u32le(raw + 14);
    if (dib_size < 40) {
        fprintf(stderr, "unsupported BMP header (need BITMAPINFOHEADER, 40 bytes)\n");
        free(raw);
        return 1;
    }
    int32_t width = read_i32le(raw + 18);
    int32_t height_raw = read_i32le(raw + 22);
    uint16_t bpp = read_u16le(raw + 28);
    uint32_t compression = read_u32le(raw + 30);

    if (bpp != 24) {
        fprintf(stderr, "unsupported bpp=%u (only 24-bit uncompressed BMP supported)\n", bpp);
        free(raw);
        return 1;
    }
    if (compression != 0) {
        fprintf(stderr, "unsupported compression=%u (only BI_RGB supported)\n", compression);
        free(raw);
        return 1;
    }
    if (width <= 0) {
        fprintf(stderr, "invalid width\n");
        free(raw);
        return 1;
    }
    int top_down = (height_raw < 0);
    int32_t height = top_down ? -height_raw : height_raw;
    if (height <= 0) {
        fprintf(stderr, "invalid height\n");
        free(raw);
        return 1;
    }
    if ((uint32_t)width > NOODLES_BUFFER_WIDTH || (uint32_t)height > NOODLES_BUFFER_HEIGHT) {
        fprintf(stderr, "image %dx%d is larger than the %ux%u buffer\n", width, height,
                NOODLES_BUFFER_WIDTH, NOODLES_BUFFER_HEIGHT);
        free(raw);
        return 1;
    }

    uint32_t row_size = (uint32_t)(((width * 3 + 3) / 4) * 4);  // 24bpp row, padded to 4 bytes
    if ((uint64_t)pixel_offset + (uint64_t)row_size * (uint64_t)height > (uint64_t)file_size) {
        fprintf(stderr, "file too small for its own declared dimensions\n");
        free(raw);
        return 1;
    }

    // Convert BGR -> our packed R|(G<<8)|(B<<16) (BLIT-004), flipping to
    // top-down row order, packed at NOODLES_BUFFER_PITCH stride so the
    // result can be used directly as a BLIT_COPY source with that pitch.
    uint32_t *converted = calloc((size_t)height, NOODLES_BUFFER_PITCH);
    if (!converted) {
        fprintf(stderr, "out of memory\n");
        free(raw);
        return 1;
    }
    for (int32_t y = 0; y < height; ++y) {
        int32_t src_row = top_down ? y : (height - 1 - y);
        const unsigned char *row = raw + pixel_offset + (uint32_t)src_row * row_size;
        uint32_t *dst_row = converted + (uint32_t)y * (NOODLES_BUFFER_PITCH / 4);
        for (int32_t x = 0; x < width; ++x) {
            unsigned char b = row[x * 3 + 0];
            unsigned char g = row[x * 3 + 1];
            unsigned char r = row[x * 3 + 2];
            dst_row[x] = noodles_rgb(r, g, b);
        }
    }
    free(raw);

    noodles_link_t link;
    if (noodles_link_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        free(converted);
        return 1;
    }

    size_t upload_size = (size_t)height * NOODLES_BUFFER_PITCH;
    if (noodles_link_upload(&link, SCRATCH_ADDR, converted, upload_size) != 0) {
        perror("noodles_link_upload");
        free(converted);
        noodles_link_close(&link);
        return 1;
    }
    free(converted);
    printf("uploaded %dx%d image (%zu bytes) to 0x%08x\n", width, height, upload_size,
           SCRATCH_ADDR);

    int x_off = (argc > 2) ? atoi(argv[2]) : (int)(NOODLES_BUFFER_WIDTH - (uint32_t)width) / 2;
    int y_off = (argc > 3) ? atoi(argv[3]) : (int)(NOODLES_BUFFER_HEIGHT - (uint32_t)height) / 2;

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
    if (noodles_push_blit_copy(&link, dst, NOODLES_BUFFER_PITCH, SCRATCH_ADDR,
                                NOODLES_BUFFER_PITCH, (uint16_t)width, (uint16_t)height) != 0) {
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
