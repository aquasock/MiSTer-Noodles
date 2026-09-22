// Pushes one command into LINK's ring buffer (LINK-002/LINK-003) via
// lib/noodles_link.h -- the same real host-driven path this project has
// used since LINK-001's first hardware proof, now going through the actual
// library instead of hand-rolled mmap code (LINK-004).
//
// Default command is SOLID_FILL of the same visible 64x64 surface
// (0x30000000, pitch 256) the OSD "Draw Test" button fills, but a
// different color (cyan, not magenta) -- so success is visually
// unambiguous: cyan means the FPGA picked this up via the ring, not the
// leftover OSD path.
//
// Usage, as root on the MiSTer:
//   ./link_push

#include <stdio.h>

#include "../lib/noodles_link.h"

int main(void) {
    noodles_link_t link;
    if (noodles_link_open(&link) != 0) {
        perror("noodles_link_open (are you root?)");
        return 1;
    }

    uint32_t write_ptr_before = link.write_ptr;
    uint32_t color = noodles_rgb(0x00, 0xFF, 0xFF);  // cyan

    if (noodles_push_solid_fill(&link, 0x30000000u, 256, 64, 64, color) != 0) {
        fprintf(stderr, "ring full (write_ptr=%u) -- refusing to push\n", write_ptr_before);
        noodles_link_close(&link);
        return 1;
    }

    printf("pushed SOLID_FILL (cyan) into slot %u; write_ptr %u -> %u\n", write_ptr_before,
           write_ptr_before, link.write_ptr);

    noodles_link_close(&link);
    return 0;
}
