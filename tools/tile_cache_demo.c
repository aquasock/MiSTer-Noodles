#define _POSIX_C_SOURCE 200809L
#include "noodles_link.h"
#include "noodles_surface.h"
#include "sdk_helpers.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#define TILE_SIZE 64
#define MAP_WIDTH 128
#define MAP_HEIGHT 128
#define CACHE_COLUMNS 16
#define CACHE_ROWS 16
#define MAX_VISIBLE_TILES 192

static double now_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec * 1e-9;
}

static void make_tile(uint32_t *pixels, uint32_t map_x, uint32_t map_y) {
    uint8_t base_r = (uint8_t)(32 + map_x * 17);
    uint8_t base_g = (uint8_t)(32 + map_y * 23);
    uint8_t base_b = (uint8_t)(48 + (map_x + map_y) * 11);
    for (uint32_t y = 0; y < TILE_SIZE; ++y) {
        for (uint32_t x = 0; x < TILE_SIZE; ++x) {
            uint32_t checker = ((x / 8) ^ (y / 8)) & 1;
            uint8_t boost = checker ? 28 : 0;
            pixels[y * TILE_SIZE + x] =
                noodles_rgb((uint8_t)(base_r + boost), (uint8_t)(base_g + boost),
                            (uint8_t)(base_b + boost));
        }
    }
}

static int submit_batch(noodles_texture_cache_t *cache,
                        const noodles_texture_blit_t *blits, size_t count) {
    struct timespec delay = {0, 100000};
    for (unsigned retry = 0; retry < 20000; ++retry) {
        if (noodles_texture_cache_batch_to_back_buffer(cache, blits, count) == 0) return 0;
        if (errno != EAGAIN) return -1;
        nanosleep(&delay, NULL);
    }
    errno = ETIMEDOUT;
    return -1;
}

int main(int argc, char **argv) {
    double duration = argc > 1 ? strtod(argv[1], NULL) : 15.0;
    if (duration <= 0.0) {
        fprintf(stderr, "usage: %s [seconds]\n", argv[0]);
        return 2;
    }

    noodles_link_t *link = NULL;
    if (tool_open(&link) != 0) {
        perror("noodles_link_open");
        return 1;
    }
    noodles_texture_cache_t *cache = NULL;
    if (noodles_texture_cache_create(link, TILE_SIZE, TILE_SIZE,
                                     CACHE_COLUMNS, CACHE_ROWS, &cache) != 0) {
        perror("noodles_texture_cache_create");
        tool_close(link);
        return 1;
    }

    uint32_t pixels[TILE_SIZE * TILE_SIZE];
    noodles_texture_blit_t visible[MAX_VISIBLE_TILES];
    uint64_t frame = 0;
    double start = now_seconds();
    while (now_seconds() - start < duration) {
        uint32_t camera_x = (uint32_t)(frame * 2) % ((MAP_WIDTH - 13) * TILE_SIZE);
        uint32_t camera_y = (uint32_t)(frame) % ((MAP_HEIGHT - 10) * TILE_SIZE);
        uint32_t first_x = camera_x / TILE_SIZE;
        uint32_t first_y = camera_y / TILE_SIZE;
        int32_t offset_x = -(int32_t)(camera_x % TILE_SIZE);
        int32_t offset_y = -(int32_t)(camera_y % TILE_SIZE);
        size_t visible_count = 0;

        for (uint32_t row = 0; row < 11; ++row) {
            for (uint32_t column = 0; column < 14; ++column) {
                uint32_t map_x = first_x + column;
                uint32_t map_y = first_y + row;
                uint64_t key = (uint64_t)map_y * MAP_WIDTH + map_x;
                if (!noodles_texture_cache_contains(cache, key)) {
                    make_tile(pixels, map_x, map_y);
                    if (noodles_texture_cache_upload(
                            cache, key, pixels, TILE_SIZE * 4,
                            NOODLES_DEFAULT_TIMEOUT_MS) != 0) {
                        perror("noodles_texture_cache_upload");
                        goto failed;
                    }
                }
                visible[visible_count++] = (noodles_texture_blit_t){
                    key, {0, 0, TILE_SIZE, TILE_SIZE},
                    offset_x + (int32_t)column * TILE_SIZE,
                    offset_y + (int32_t)row * TILE_SIZE
                };
            }
        }

        for (size_t offset = 0; offset < visible_count;
             offset += NOODLES_SPRITE_DESCRIPTOR_MAX) {
            size_t count = visible_count - offset;
            if (count > NOODLES_SPRITE_DESCRIPTOR_MAX)
                count = NOODLES_SPRITE_DESCRIPTOR_MAX;
            if (submit_batch(cache, visible + offset, count) != 0) {
                perror("tile batch submission");
                goto failed;
            }
        }
        if (noodles_present_and_wait(link) != 0) {
            perror("noodles_present_and_wait");
            goto failed;
        }
        ++frame;
    }

    double elapsed = now_seconds() - start;
    printf("tile cache: %llu frames in %.1fs (%.1f fps), 154 visible 64x64 tiles, "
           "256-cell atlas\n",
           (unsigned long long)frame, elapsed, frame / elapsed);
    if (noodles_texture_cache_destroy(cache, NOODLES_DEFAULT_TIMEOUT_MS) != 0) {
        perror("noodles_texture_cache_destroy");
        tool_close(link);
        return 1;
    }
    tool_close(link);
    return 0;

failed:
    (void)noodles_texture_cache_destroy(cache, NOODLES_DEFAULT_TIMEOUT_MS);
    tool_close(link);
    return 1;
}
