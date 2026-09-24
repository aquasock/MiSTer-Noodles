#include <noodles_link.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    int legacy = argc >= 2 && !strcmp(argv[1], "--legacy-svga");
    if (argc > 3 || (argc == 2 && !legacy) ||
        (argc == 3 && (!legacy || strcmp(argv[2], "--ack-core-reload")))) {
        fprintf(stderr, "Usage: %s [--legacy-svga [--ack-core-reload]]\n"
                "No arguments requires a live stage-2B core. Legacy mode requires\n"
                "the caller to guarantee a matching initialized, idle SVGA core.\n", argv[0]);
        return 1;
    }
    noodles_link_t *device = NULL;
    int opened = legacy ? noodles_link_open_legacy(&device, argc == 3) :
                          noodles_link_open(&device);
    if (opened != 0) {
        perror(legacy ? "legacy attachment" : "verified attachment");
        return 1;
    }
    noodles_device_info_t info;
    int failed = noodles_link_get_info(device, &info);
    if (!failed) {
        printf("SDK %s: %s %ux%u pitch=%u protocol=0x%08x opcode-mask=0x%x\n",
               info.sdk_version, info.hardware_verified ? "VERIFIED" : "LEGACY/UNVERIFIED",
               info.width, info.height, info.pitch, info.protocol_version,
               info.opcode_mask);
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
