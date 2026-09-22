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
// let a caller ask "has command #N actually finished" by comparing the two,
// for the first time cases that need it (surface readback, safely reusing a
// BLIT_COPY's source region) rather than just fire-and-forget.

#ifndef NOODLES_LINK_H
#define NOODLES_LINK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int fd;
    void *map;
    size_t map_span;
    volatile uint32_t *header;  // write_ptr at [0], read_ptr at [2], fence at [3] (LINK-005)
    volatile uint32_t *slots;
    uint32_t write_ptr;         // host's own tracked copy; the FPGA never writes this field
    uint32_t submitted;         // count of commands pushed through THIS handle since open()
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
// Returns 0 on success, -1 if the ring is full (the command is NOT
// partially written in that case). Every noodles_push_* wrapper below is
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

// Count of commands successfully pushed through THIS handle since
// noodles_link_open() -- NOT an absolute, cross-session count (the library
// has no way to know that). Only meaningful compared against
// noodles_link_done_count() when the handle has been open since a fresh
// core load, matching the FPGA-side counter's own lifetime (LINK-005).
// Concretely: this is safe for one long-lived handle (open once, e.g. at
// game startup, push many commands over the run), but comparing it against
// noodles_link_done_count() across two SEPARATE short-lived processes each
// opening their own handle is not meaningful -- each one's submitted count
// restarts at 0 while done_count keeps counting from the shared FPGA
// session, so an old, already-satisfied done_count can make a brand new
// command look "done" before it has even been pushed. When in doubt, use
// noodles_link_done_count() alone and compare it against a value read
// BEFORE the push, not against submitted_count().
uint32_t noodles_link_submitted_count(const noodles_link_t *link);

// Reads LINK-005's completion fence directly from DRAM: a monotonic count,
// published by rtl/link_fence.sv, of commands that have ACTUALLY finished
// executing (not just been dispatched). A command is done once this
// return value is >= the noodles_link_submitted_count() value observed
// right after that command's push call returned.
uint32_t noodles_link_done_count(const noodles_link_t *link);

#ifdef __cplusplus
}
#endif

#endif  // NOODLES_LINK_H
