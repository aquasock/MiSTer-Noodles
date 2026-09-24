#ifndef NOODLES_LINK_H
#define NOODLES_LINK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NOODLES_SDK_VERSION "0.2.0"
#define NOODLES_PROTOCOL_VERSION 0x00010000u
#define NOODLES_BUFFER_A_ADDR 0x31000000u
#define NOODLES_BUFFER_B_ADDR 0x31200000u
#define NOODLES_BUFFER_PITCH 3200u
#define NOODLES_BUFFER_WIDTH 800u
#define NOODLES_BUFFER_HEIGHT 600u
#define NOODLES_SPRITE_DESCRIPTOR_ADDR 0x30022000u
#define NOODLES_SPRITE_DESCRIPTOR_MAX 64u
#define NOODLES_SDRAM_WINDOW_BYTES 0x08000000u
#define NOODLES_SDRAM_PAGE_BYTES 1024u
#define NOODLES_DEFAULT_TIMEOUT_MS 2000u

typedef struct noodles_link noodles_link_t;
typedef uint32_t noodles_fence_t;

typedef struct {
    uint32_t dst_addr, dst_pitch, width, height, colorkey, src_addr, src_pitch, flags;
} noodles_sprite_descriptor_t;

typedef struct {
    uint32_t width, height, pitch;
    uint32_t opcode_mask;
    uint32_t protocol_version;
    int hardware_verified;
    const char *sdk_version;
} noodles_device_info_t;

/* Verified attachment to a stage-2B core. The FPGA must acknowledge a fresh
 * 64-bit session token before the command ring is enabled. */
int noodles_link_open(noodles_link_t **out);

/* Explicit legacy attachment: caller guarantees the matching initialized,
 * quiescent SVGA core is loaded. No identity, idle or reset detection exists.
 * One serialized producer; cooperative lock excludes other SDK clients only.
 * ack_reload may be 1 ONLY after the caller has reloaded and initialized the
 * matching core, to discard a prior dirty-session marker. Never auto-retry it.
 * All fallible APIs return 0 on success, -1 with errno on failure. */
int noodles_link_open_legacy(noodles_link_t **out, int ack_reload);
int noodles_link_get_info(const noodles_link_t *link, noodles_device_info_t *info);

/* Close always releases/frees the handle, even on failure. It drains within
 * timeout_ms; failure leaves a dirty marker requiring an explicit core reload.
 * A timeout faults the handle and does not cancel already submitted commands. */
int noodles_link_close(noodles_link_t *link, uint32_t timeout_ms);
int noodles_link_drain(noodles_link_t *link, uint32_t timeout_ms);
int noodles_link_wait(noodles_link_t *link, noodles_fence_t target, uint32_t timeout_ms);
int noodles_link_poll(noodles_link_t *link, noodles_fence_t target, int *complete);

/* Capture immediately after successful submission. Tokens are device-session
 * local, modulo 2^31; retain them for less than 2^30 completions. */
noodles_fence_t noodles_link_last_fence(const noodles_link_t *link);
uint32_t noodles_link_submitted_count(const noodles_link_t *link);
uint32_t noodles_link_done_count(const noodles_link_t *link);
uint32_t noodles_link_back_buffer(const noodles_link_t *link);
uint32_t noodles_rgb(uint8_t r, uint8_t g, uint8_t b);

/* Nonblocking submission: EAGAIN means no command was published. Inputs must
 * remain alive/unchanged until completion. No allocator or memory sandbox.
 * Raw commands are checked against the implemented opcode layouts. */
int noodles_push_command(noodles_link_t *link, const uint32_t command[8]);
int noodles_push_solid_fill(noodles_link_t *link, uint32_t dst_addr, uint16_t dst_pitch,
                            uint16_t width, uint16_t height, uint32_t color);
int noodles_push_blit_copy(noodles_link_t *link, uint32_t dst_addr, uint16_t dst_pitch,
                           uint32_t src_addr, uint16_t src_pitch, uint16_t width, uint16_t height);
int noodles_push_blit_copy_key(noodles_link_t *link, uint32_t dst_addr, uint16_t dst_pitch,
                               uint32_t src_addr, uint16_t src_pitch, uint16_t width,
                               uint16_t height, uint32_t colorkey);
int noodles_push_sprite_batch(noodles_link_t *link,
                              const noodles_sprite_descriptor_t *descriptors, uint16_t count);

/* Board-SDRAM loader only: production sprites still read DDR3. */
int noodles_push_load_sdram(noodles_link_t *link, uint32_t sdram_dst_addr,
                            uint32_t ddr3_src_addr, uint32_t length);

/* PRESENT submission and waiting are separate. While a present is pending,
 * further submissions/uploads return EAGAIN. poll/wait refresh back-buffer
 * tracking after retirement. Never resubmit on ETIMEDOUT. */
int noodles_push_present(noodles_link_t *link, noodles_fence_t *fence);
int noodles_present_and_wait(noodles_link_t *link);

/* Upload excludes control memory except the fixed descriptor table, which is
 * ownership-protected. Arbitrary texture lifetimes remain caller-managed. */
int noodles_link_upload(noodles_link_t *link, uint32_t dst_addr, const void *data, size_t size_bytes);

#ifdef __cplusplus
}
#endif
#endif
