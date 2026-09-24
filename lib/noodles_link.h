// Host-side library for LINK-001: the real ARM/Linux-side API for pushing
// draw commands into the FPGA's command ring buffer, replacing hand-rolled
// /dev/mem mmap code in every caller (tools/link_push.c was the first such
// caller and is now itself built on this library).
//
// This wraps exactly the mechanism LINK-002/LINK-003 define and this
// project has proven on real hardware: a 64-slot ring in shared DDR3, a
// write_ptr the host publishes and the FPGA reads, a read_ptr the FPGA
// publishes and the host reads. See ai/core-reference.md's LINK component
// records for the wire contract; this header is the C-callable form of it.
//
// noodles_push_* returning 0 means the command was written into the ring
// and the ring's write_ptr was published, not that the FPGA has finished
// (or even started) executing it -- LINK-004 shipped this library without
// a completion signal deliberately, since nothing needed one yet.
// LINK-005 adds one: noodles_link_submitted_count()/noodles_link_done_count()
// let a caller ask "has command #N actually finished" using a baseline-adjusted fence,
// for the first time cases that need it (surface readback, safely reusing a
// BLIT_COPY's source region) rather than just fire-and-forget.

#ifndef NOODLES_LINK_H
#define NOODLES_LINK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// OUT-004's two fixed double-buffer surfaces -- 640x480, 32bpp, pitch 2560
// (SURF-005). Buffer A is front (visible) immediately after an FPGA
// reset/core load; see noodles_link_back_buffer() for which one to draw
// into right now.
#define NOODLES_BUFFER_A_ADDR 0x31000000u
#define NOODLES_BUFFER_B_ADDR 0x31200000u
#define NOODLES_BUFFER_PITCH 2560u
#define NOODLES_BUFFER_WIDTH 640u
#define NOODLES_BUFFER_HEIGHT 480u
#define NOODLES_SPRITE_DESCRIPTOR_ADDR 0x30022000u  // 2 KiB after the 0x30021000 ring slots
#define NOODLES_SPRITE_DESCRIPTOR_MAX 64u

// SDR-008: sdram_adapter/sdram_loader's address space is a
// SEPARATE, FPGA-fabric-only 128MB window (see rtl/sdram_adapter.sv's own
// header) -- NOT the same address space as NOODLES_BUFFER_*_ADDR/DDR3.
// Production sprite_batch reads use DDR3, NOT this window. These constants
// describe the optional board-SDRAM loader path, not texture storage for
// the accepted production core.
#define NOODLES_SDRAM_WINDOW_BYTES 0x08000000u  // 128MB, byte-address space
#define NOODLES_SDRAM_PAGE_BYTES 1024u          // sdram_loader.sv's own page size; dst_addr must be a multiple of this

typedef struct {
    uint32_t dst_addr, dst_pitch, width, height, colorkey, src_addr, src_pitch, flags;
} noodles_sprite_descriptor_t;

// One producer/handle at a time, with calls serialized by the caller. Open
// only after previous work has drained (or a fresh core load), and finish
// pending work before close. Concurrent producers and reset during a handle's
// lifetime are unsupported; closing a handle does not cancel FPGA commands.
typedef struct {
    int fd;
    void *map;
    size_t map_span;
    volatile uint32_t *header;  // write_ptr [0], read_ptr [2], fence/count+front [3]
    volatile uint32_t *slots;
    uint32_t write_ptr;         // host's own tracked copy; the FPGA never writes this field
    uint32_t submitted;         // count of commands pushed through THIS handle since open()
    uint32_t presents_completed;  // current front parity: 0=A, 1=B
    uint32_t done_baseline;     // LINK-005 fence value at open() time; done_baseline + submitted
                                 // converts a per-handle submitted count into the fence's own
                                 // absolute numbering -- see noodles_present_and_wait()
    uint32_t batch_fence;       // completion target owning the fixed descriptor table
    int batch_pending;
} noodles_link_t;

// Opens /dev/mem and maps LINK-002's header+slot region. Returns 0 on
// success, -1 on failure (check errno). Synchronizes the handle's local
// write_ptr with whatever is currently published in DRAM, so re-opening
// after a previous session (rather than a fresh FPGA reset) still works.
int noodles_link_open(noodles_link_t *link);

// Unmaps and closes. Safe to call on a handle that failed to open.
void noodles_link_close(noodles_link_t *link);

// Packs an R,G,B triple into SOLID_FILL's color field, matching BLIT-004's
// byte order (R in the low byte) -- use this instead of hand-deriving a
// 0xRRGGBB-style constant, which produces the WRONG color under this
// project's FB_FORMAT (see BLIT-004's decision for why).
uint32_t noodles_rgb(uint8_t r, uint8_t g, uint8_t b);

// Pushes a raw 8-word command (CMDQ-001's slot layout) into the ring.
// Returns 0 on success, -1 with errno=EAGAIN if the ring is full or an
// opcode-5 batch still owns the descriptor table; NULL command gives EINVAL.
// Failed submissions do not write a slot. Raw opcode-5 submissions also
// acquire descriptor ownership, but the caller must upload descriptors first.
// Every noodles_push_* wrapper below is
// built on this; use it directly for an opcode this library doesn't yet
// wrap.
int noodles_push_command(noodles_link_t *link, const uint32_t command[8]);

// SOLID_FILL (opcode 1, BLIT-002): fills a width x height rect at dst_addr
// (dst_pitch bytes/row) with color (see noodles_rgb). Returns 0 on success,
// -1 if the ring is full.
int noodles_push_solid_fill(noodles_link_t *link, uint32_t dst_addr, uint16_t dst_pitch,
                             uint16_t width, uint16_t height, uint32_t color);

// BLIT_COPY (opcode 2, BLIT-003): copies a width x height rect from
// src_addr (src_pitch bytes/row) to dst_addr (dst_pitch bytes/row), no
// scale/blend/format conversion. Returns 0 on success, -1 if the ring is
// full.
int noodles_push_blit_copy(noodles_link_t *link, uint32_t dst_addr, uint16_t dst_pitch,
                            uint32_t src_addr, uint16_t src_pitch, uint16_t width,
                            uint16_t height);

// BLIT_COPY_KEY (opcode 3, BLIT-006): same as noodles_push_blit_copy, but
// any source pixel exactly equal to colorkey is skipped -- the destination
// pixel underneath is left untouched instead of being overwritten. This is
// colorkey transparency (SDL_SetColorKey + SDL_BlitSurface's model), the
// mechanism sprite compositing needs so a sprite doesn't carry a solid
// rectangle around it. colorkey uses the same R|(G<<8)|(B<<16) packing as
// noodles_rgb -- pick one color the sprite's own art never legitimately
// uses. Returns 0 on success, -1 if the ring is full.
int noodles_push_blit_copy_key(noodles_link_t *link, uint32_t dst_addr, uint16_t dst_pitch,
                                uint32_t src_addr, uint16_t src_pitch, uint16_t width,
                                uint16_t height, uint32_t colorkey);

// SPRITE_BATCH (opcode 5): uploads up to 64 fixed-format descriptors (2 KiB)
// to the reserved DDRAM list and queues one command. Descriptor flags bit 0 enables
// colorkeying; all other bits are reserved and must be zero.
// Returns 0 on submission, NOT completion. Returns -1 with errno=EAGAIN
// while the previous batch is unfinished or the ring is full, without
// touching descriptors or publishing a command. Retry later; no explicit
// per-batch fence wait is required for safe reuse. Invalid pointer/count
// gives EINVAL; upload failures preserve their errno and publish nothing.
int noodles_push_sprite_batch(noodles_link_t *link,
                               const noodles_sprite_descriptor_t *descriptors,
                               uint16_t count);

// LOAD_SDRAM (opcode 6, SDR-003/SDR-004): one-shot bulk copy of length
// bytes from ddr3_src_addr (a normal DDR3 byte address) into the FPGA's
// dedicated SDRAM board at sdram_dst_addr, a byte address within the
// SEPARATE, 128MB sdram_adapter/sdram_loader address window (see
// NOODLES_SDRAM_WINDOW_BYTES above) -- NOT a DDR3 address. sdram_dst_addr
// MUST already be aligned to NOODLES_SDRAM_PAGE_BYTES (sdram_loader.sv
// copies whole 1KB pages regardless of length). The SDRAM board has no
// HPS/host write path (SDR-001); this FPGA-internal copy populates it.
// Production sprite_batch still reads DDR3 (SDR-008), so loading board
// SDRAM does not make it a production sprite source. Keep production
// descriptor src_addr values in the reserved DDR3 address space.
// Returns 0 on success, -1 if the ring is full.
int noodles_push_load_sdram(noodles_link_t *link, uint32_t sdram_dst_addr,
                             uint32_t ddr3_src_addr, uint32_t length);

// Count of commands successfully pushed through THIS handle since open.
// Capture target = link->done_baseline + noodles_link_submitted_count(link)
// immediately after a successful push, then use noodles_link_fence_reached().
uint32_t noodles_link_submitted_count(const noodles_link_t *link);

// Reads the 31-bit completion count, excluding front-buffer parity. Wraps
// modulo 2^31; a plain >= comparison is not safe across wraparound.
uint32_t noodles_link_done_count(const noodles_link_t *link);

// Nonblocking completion check for a baseline-adjusted target. Both values
// are compared modulo 2^31; target must be less than 2^30 completions away.
int noodles_link_fence_reached(const noodles_link_t *link, uint32_t target);

// PRESENT (opcode 4, OUT-004): the double-buffer flip. Pushes the command
// and BLOCKS until LINK-005's fence confirms the flip actually happened --
// vblank-synced on the FPGA side, so this can take up to roughly one frame.
// Returns 0 on success, -1 if the ring was full when pushing, 1 if the
// fence never caught up (should not happen in practice). On success,
// updates the handle's back-buffer tracking, so the NEXT
// noodles_link_back_buffer() call reflects the new state -- do not call
// this and keep drawing into the buffer you just presented; it is now
// the front buffer, being scanned out live.
int noodles_present_and_wait(noodles_link_t *link);

// Returns the buffer address the host should currently draw into (the back
// buffer, i.e. the one NOT being scanned out right now). Starts as
// NOODLES_BUFFER_B_ADDR (buffer A is front after an FPGA reset/core load)
// and follows the FPGA-published front parity across process launches.
// Draw a full frame's worth of commands at this address, then call
// noodles_present_and_wait() before reading this again.
uint32_t noodles_link_back_buffer(const noodles_link_t *link);

// Writes size_bytes of data directly into DDR3 at dst_addr via mmap+memcpy
// -- bypasses the ring buffer and every BLIT engine entirely. This is how
// real asset data (a decoded image, a sprite sheet) gets into a surface:
// loading and decoding an asset is inherently host-side work, and DDR-002
// already established DDRAM_* addresses are direct, unwindowed physical
// addresses, so a plain /dev/mem mmap of dst_addr just works -- no command
// needed. dst_addr does not need to be page-aligned. Once uploaded, use
// noodles_push_blit_copy()/noodles_push_blit_copy_key() to composite it
// onto a buffer, exactly like any other source region. Returns 0 on
// success, -1 on failure (check errno).
// Uploads overlapping the reserved descriptor table return EAGAIN without
// touching memory while a batch owns it. Direct /dev/mem writes bypass this
// protection and must not modify in-flight descriptors.
int noodles_link_upload(noodles_link_t *link, uint32_t dst_addr, const void *data,
                         size_t size_bytes);

#ifdef __cplusplus
}
#endif

#endif  // NOODLES_LINK_H
