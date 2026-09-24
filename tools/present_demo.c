// Proves OUT-004's double buffering over the real LINK path: cycles
// through a handful of solid colors, each time filling whichever buffer
// noodles_link_back_buffer() says is currently back, then calling
// noodles_present_and_wait() to flip it to front. If double buffering
// works, each flip should show one clean, solid color with no visible
// tearing or bleed from the previous frame -- and the buffer address used
// should alternate between NOODLES_BUFFER_A_ADDR/NOODLES_BUFFER_B_ADDR
// every time.
//
// Usage, as root on the MiSTer:
//   ./present_demo [seconds_per_color]

#define _POSIX_C_SOURCE 199309L
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "sdk_helpers.h"

int main(int argc, char **argv) {
    double seconds = (argc > 1) ? atof(argv[1]) : 1.0;

    noodles_link_t *link = NULL;
    if (tool_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        return 1;
    }

    struct {
        const char *name;
        uint8_t r, g, b;
    } colors[] = {
        {"red", 0xFF, 0x00, 0x00}, {"green", 0x00, 0xFF, 0x00}, {"blue", 0x00, 0x00, 0xFF},
        {"yellow", 0xFF, 0xFF, 0x00}, {"cyan", 0x00, 0xFF, 0xFF}, {"magenta", 0xFF, 0x00, 0xFF},
    };
    const int n_colors = (int)(sizeof(colors) / sizeof(colors[0]));

    for (int i = 0; i < n_colors; ++i) {
        uint32_t back = noodles_link_back_buffer(link);
        uint32_t color = noodles_rgb(colors[i].r, colors[i].g, colors[i].b);

        if (noodles_push_solid_fill(link, back, NOODLES_BUFFER_PITCH, NOODLES_BUFFER_WIDTH,
                                     NOODLES_BUFFER_HEIGHT, color) != 0) {
            perror("back buffer fill submission");
            tool_close(link);
            return 1;
        }
        if (tool_wait(link, "fill completion") != 0) {
            tool_close(link);
            return 1;
        }

        int rc = noodles_present_and_wait(link);
        if (rc != 0) {
            fprintf(stderr, "present failed (rc=%d) on color %s\n", rc, colors[i].name);
            tool_close(link);
            return 1;
        }

        printf("presented %-8s into back buffer 0x%08x (now front)\n", colors[i].name, back);

        struct timespec hold = {.tv_sec = (time_t)seconds,
                                 .tv_nsec = (long)((seconds - (time_t)seconds) * 1e9)};
        nanosleep(&hold, NULL);
    }

    tool_close(link);
    printf("done -- screen should have cycled cleanly through all %d colors, "
           "one solid color at a time, no tearing.\n",
           n_colors);
    return 0;
}
