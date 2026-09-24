#include <noodles_link.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3 || strcmp(argv[1], "--legacy-svga") ||
        (argc == 3 && strcmp(argv[2], "--ack-core-reload"))) {
        fprintf(stderr, "Usage: %s --legacy-svga [--ack-core-reload]\n"
                "Requires the matching initialized, idle SVGA core. Recovery flag\n"
                "is only valid after YOU reload that core; it does not reset hardware.\n", argv[0]);
        return 1;
    }
    noodles_link_t *device = NULL;
    if (noodles_link_open_legacy(&device, argc == 3) != 0) {
        perror("legacy attachment (EBUSY: owner/queue; EOWNERDEAD: reload required)");
        return 1;
    }
    noodles_device_info_t info;
    int failed = noodles_link_get_info(device, &info);
    if (!failed) {
        printf("SDK %s: LEGACY/UNVERIFIED assumed %ux%u pitch=%u opcode-mask=0x%x\n",
               info.sdk_version, info.width, info.height, info.pitch, info.assumed_opcode_mask);
        failed = noodles_push_solid_fill(device, noodles_link_back_buffer(device),
            info.pitch, info.width, info.height, noodles_rgb(0, 128, 255));
    }
    noodles_fence_t fence;
    if (!failed) failed = noodles_push_present(device, &fence);
    if (!failed) failed = noodles_link_wait(device, fence, NOODLES_DEFAULT_TIMEOUT_MS);
    if (failed) perror("SDK smoke draw/present");
    if (noodles_link_close(device, NOODLES_DEFAULT_TIMEOUT_MS) != 0) {
        perror("SDK shutdown");
        failed = 1;
    }
    return failed != 0;
}
