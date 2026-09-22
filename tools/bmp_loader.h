// Shared uncompressed-24-bit-BMP loader (BITMAPINFOHEADER only), factored
// out of tools/load_bmp.c once a second caller (tools/stress_demo.c) needed
// the same parsing -- see LINK-006 for the noodles_link_upload() primitive
// this feeds. Not a general asset pipeline; deliberately BMP-only, same
// scope as LINK-006's own proof.
//
// noodles_bmp_load() returns a malloc'd buffer (caller frees) of
// width*height uint32_t pixels, packed BLIT-004 order (R|(G<<8)|(B<<16)),
// tightly packed at pitch = width*4 bytes/row (NOT NOODLES_BUFFER_PITCH --
// pass that as src_pitch to noodles_push_blit_copy/_key, not the buffer's
// screen pitch), already flipped to top-down row order regardless of the
// source file's own row order. Returns NULL on failure, message on stderr.

#ifndef NOODLES_BMP_LOADER_H
#define NOODLES_BMP_LOADER_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "../lib/noodles_link.h"

static uint32_t noodles_bmp_read_u32le(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t noodles_bmp_read_u16le(const unsigned char *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}
static int32_t noodles_bmp_read_i32le(const unsigned char *p) {
    return (int32_t)noodles_bmp_read_u32le(p);
}

static uint32_t *noodles_bmp_load(const char *path, uint32_t *out_width, uint32_t *out_height) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror("fopen");
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long file_size = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (file_size < 54) {
        fprintf(stderr, "%s: file too small to be a BMP\n", path);
        fclose(f);
        return NULL;
    }

    unsigned char *raw = malloc((size_t)file_size);
    if (!raw || fread(raw, 1, (size_t)file_size, f) != (size_t)file_size) {
        fprintf(stderr, "%s: read failed\n", path);
        free(raw);
        fclose(f);
        return NULL;
    }
    fclose(f);

    if (raw[0] != 'B' || raw[1] != 'M') {
        fprintf(stderr, "%s: not a BMP file (missing 'BM' magic)\n", path);
        free(raw);
        return NULL;
    }
    uint32_t pixel_offset = noodles_bmp_read_u32le(raw + 10);
    uint32_t dib_size = noodles_bmp_read_u32le(raw + 14);
    if (dib_size < 40) {
        fprintf(stderr, "%s: unsupported BMP header (need BITMAPINFOHEADER, 40 bytes)\n", path);
        free(raw);
        return NULL;
    }
    int32_t width = noodles_bmp_read_i32le(raw + 18);
    int32_t height_raw = noodles_bmp_read_i32le(raw + 22);
    uint16_t bpp = noodles_bmp_read_u16le(raw + 28);
    uint32_t compression = noodles_bmp_read_u32le(raw + 30);

    if (bpp != 24) {
        fprintf(stderr, "%s: unsupported bpp=%u (only 24-bit uncompressed BMP supported)\n", path,
                bpp);
        free(raw);
        return NULL;
    }
    if (compression != 0) {
        fprintf(stderr, "%s: unsupported compression=%u (only BI_RGB supported)\n", path,
                compression);
        free(raw);
        return NULL;
    }
    if (width <= 0) {
        fprintf(stderr, "%s: invalid width\n", path);
        free(raw);
        return NULL;
    }
    int top_down = (height_raw < 0);
    int32_t height = top_down ? -height_raw : height_raw;
    if (height <= 0) {
        fprintf(stderr, "%s: invalid height\n", path);
        free(raw);
        return NULL;
    }
    if ((uint32_t)width > NOODLES_BUFFER_WIDTH || (uint32_t)height > NOODLES_BUFFER_HEIGHT) {
        fprintf(stderr, "%s: image %dx%d is larger than the %ux%u buffer\n", path, width, height,
                NOODLES_BUFFER_WIDTH, NOODLES_BUFFER_HEIGHT);
        free(raw);
        return NULL;
    }

    uint32_t row_size = (uint32_t)(((width * 3 + 3) / 4) * 4);  // 24bpp row, padded to 4 bytes
    if ((uint64_t)pixel_offset + (uint64_t)row_size * (uint64_t)height > (uint64_t)file_size) {
        fprintf(stderr, "%s: file too small for its own declared dimensions\n", path);
        free(raw);
        return NULL;
    }

    uint32_t *converted = malloc((size_t)width * (size_t)height * 4);
    if (!converted) {
        fprintf(stderr, "%s: out of memory\n", path);
        free(raw);
        return NULL;
    }
    for (int32_t y = 0; y < height; ++y) {
        int32_t src_row = top_down ? y : (height - 1 - y);
        const unsigned char *row = raw + pixel_offset + (uint32_t)src_row * row_size;
        uint32_t *dst_row = converted + (uint32_t)y * (uint32_t)width;
        for (int32_t x = 0; x < width; ++x) {
            unsigned char b = row[x * 3 + 0];
            unsigned char g = row[x * 3 + 1];
            unsigned char r = row[x * 3 + 2];
            dst_row[x] = noodles_rgb(r, g, b);
        }
    }
    free(raw);

    *out_width = (uint32_t)width;
    *out_height = (uint32_t)height;
    return converted;
}

#endif  // NOODLES_BMP_LOADER_H
