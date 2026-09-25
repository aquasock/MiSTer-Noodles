# Noodles integration baseline

This is the consumer-facing description of the 100MHz core, not
a new GPU ABI or an SDL implementation. Architecture decisions remain in
[ai/core-reference.md](../ai/core-reference.md); later records override
earlier bring-up assumptions. Relevant records include CMDQ-001, BLIT-003/004/006/007/008/009/010,
SURF-003/004/006, LINK-002/005/008/011/012/013/014/015/016 and SDR-008.

## Standard configuration: 800x600

Current source renders 800x600 with a 3200-byte pitch (SURF-006), retaining
the 100MHz GPU, 4:3 aspect ratio and existing buffer addresses. Each buffer
uses 1920000 bytes and still fits its reserved 2MiB slot. The HDMI mode is
independent: MiSTer's scaler scales this framebuffer to its configured output.
The accepted protocol 1.5 seed-13 image passes all four timing corners,
exact-pixel hardware diagnostics, HDMI audio, multi-batch stress and the
MiSTer-GemRB AR4000 workload. Its RBF SHA-256 is
`b79037fce611af71513b7aba9f48ace0a3fa1ffc3f6820c96080be4e60dd5e56`,
built from source `513f218`. See [QUALIFICATION.md](QUALIFICATION.md) for
provenance, results and the protocol 1.4 recovery image.

Build the host library/tools from the same source as the loaded core.
Geometry remains compile-time in FPGA logic, but protocol 1.6 reports and
verifies the fixed 800x600 values at attachment. The fallback 640x480 image
has no protocol block and must use its preserved legacy tools.

## Preserved 640x480 recovery baseline

- Source: `c3d04ab68dd1d2f14ba7bd858f6cfe98c1508e86`.
- RBF SHA-256: `b76fb924c43cb25b9c516e216f247dacb576ec72ab6ef408b1a275d9bc247b8d`.
- Quartus Prime Lite 17.0.2 Build 602, Cyclone V `5CSEBA6U23I7`,
  seed 5, 16 fitter threads, MEDIUM register packing.
- `SOURCE_DATE_EPOCH=1790121600`; shared 100MHz core/board-SDRAM clock.
- Fixed 640x480 scanout through the MiSTer framebuffer/scaler, double
  buffered; production draw sources and destinations are in HPS DDR3.

See [BUILD.md](BUILD.md) for reproduction and the post-fit timing gate,
and [QUALIFICATION.md](QUALIFICATION.md) for hardware and four-corner evidence.
Pin the source and matching host library together. The stage-2B source adds
the protocol identifier and fixed capability/geometry report described
below; the accepted fallback image predates it and remains unverified.

## Memory and pixels

Commands carry **absolute physical byte addresses**, not virtual pointers,
handles or offsets into a GPU window. The DDRAM bridge does not sandbox
them: an incorrect address can write Linux memory. `/dev/mem` access requires
the corresponding privileges on the MiSTer Linux host.

The FPGA-reserved physical region is `[0x20000000, 0x40000000)` on the
documented target, but it is NOT an exclusively owned Noodles allocation
arena. MiSTer has other consumers within it: in particular `0x20000000`
is the system scaler's memory base. Do not infer free texture capacity from
that region's size. SURF-004 corrects the older SURF-003 placement assumption.

Current fixed uses (end addresses are exclusive):

| Physical range | Use / ownership |
|---|---|
| `[0x30020000, 0x30020010)` | Shared ring header; fields described below. |
| `[0x30020010, 0x30020044)` | Live identity/session control block; fields described below. |
| `[0x30021000, 0x30021800)` | 64 command slots, 32 bytes each. |
| `[0x30022000, 0x30042000)` | Protocol 1.5+ descriptor pool: 64 aligned tables of 64 descriptors, 32 bytes per descriptor and 2 KiB per table. Protocol 1.4 and older use only the first table. |
| `[0x31000000, 0x311d4c00)` | 800x600 buffer A pixels; within its fixed 2MiB slot beginning at `0x31000000`. |
| `[0x31200000, 0x313d4c00)` | 800x600 buffer B pixels; within its fixed 2MiB slot beginning at `0x31200000`. |
| `0x31400000` and tool-specific addresses | Demo scratch/assets, not an allocator or a promise of available capacity. |
| `[0x31600000, 0x317d4c00)` | Protocol 1.7 800x600 buffer C pixels, used only by queued three-buffer flips (OUT-013); not scratch while such a client is displaying. |
| `[0x32000000, 0x40000000)` | SDK 0.3 managed-surface arena; 224MiB, excluded from raw SDK commands and uploads. |

Leave the control-memory neighborhood and both 2MiB scanout slots reserved;
do not treat gaps or demo addresses as a shared allocator. Run only one
producer/application and no concurrent memory-writing diagnostic tools.
SDK 0.3 owns the bounded arena shown above for opaque managed surfaces. Do not
address it through raw commands, direct `/dev/mem` mappings or legacy tools.

Pixels occupy four bytes, with increasing-address bytes **R, G, B, unused**.
`noodles_rgb(r,g,b)` produces `r | (g << 8) | (b << 16)` with a zero high byte.
The high byte is straight (non-premultiplied) alpha for BLIT_BLEND, flagged draws and BLEND_FILL.
Copies preserve all 32 bits, color-key comparisons compare the entire
32-bit pixel and scanout ignores the high byte; initialize it consistently,
and meaningfully for any blended source. Scanout uses `FB_FORMAT=00110`, pitch 3200 bytes in
the SVGA configuration (2560 in the accepted 640x480 fallback).

Addresses and row pitches for pixel operations must be four-byte aligned.
Pitches are in bytes; widths and heights are in pixels. Supply a sufficient
pitch and valid backing storage for every row. There is no hardware bounds
checking, automatic clipping, format conversion or defined overlapping-copy
semantics. The stage-2A SDK validates basic alignment, geometry and address
spans, but cannot prove allocation or ownership; see [SDK.md](SDK.md).

Board SDRAM is a separate FPGA-only, byte-addressed 128MiB window beginning
at zero. It is not HPS DDR3, not host-mappable and not a production sprite
source. `LOAD_SDRAM` populates this optional path; its addresses must never
be substituted for production DDR3 sprite addresses.

## Command wire format

Each slot is eight little-endian 32-bit words, 32 bytes total. This is the
wire representation, not the layout of `noodles_link_t`.

| Word / byte offset | Normal draw meaning | Bits used |
|---|---|---|
| 0 / 0 | Opcode | 7:0 |
| 1 / 4 | Destination byte address | 31:0 |
| 2 / 8 | Destination pitch | 15:0 |
| 3 / 12 | Width | 15:0 |
| 4 / 16 | Height | 15:0 |
| 5 / 20 | Fill color or color key | 31:0 |
| 6 / 24 | Source byte address | 31:0 |
| 7 / 28 | Source pitch | 15:0 |

Unused words and unused high bits must be zero. Field widths are encoding
limits, not a promise that every representable rectangle is safe.

| Opcode | Operation | Fields / restrictions |
|---|---|---|
| 1 | SOLID_FILL | Words 1-5 describe the destination rectangle and pixel value. |
| 2 | BLIT_COPY | Words 1-4 and 6-7; word 5 zero. No scale or blend. |
| 3 | BLIT_COPY_KEY | As COPY, with full-pixel key in word 5; matching pixels leave destination untouched. |
| 4 | PRESENT | Words 1-7 zero; flips the two fixed buffers at vblank and waits for scanout retirement. |
| 5 | SPRITE_BATCH | Word 1 selects a 2 KiB-aligned table in `[0x30022000, 0x30042000)` and word 3 is descriptor count, 1-64. Other words zero. Protocol 1.4 and older require word 1 `0x30022000`. |
| 6 | LOAD_SDRAM | Word 1 is board-SDRAM destination, word 5 byte length, word 6 DDR3 source; others zero. Destination aligned to 1024 bytes; loader copies complete pages, so source/destination backing storage must cover the rounded-up length. |
| 7 | BLIT_BLEND | As COPY, with alpha modulation in word 5 bits 7:0 and bits 31:8 zero. Straight-alpha source-over per BLIT-007; source and destination must not overlap. Protocol 1.1 cores only (capability bit 7). |
| 8 | BLEND_FILL | Words 1-4 describe the destination; word 5 is one constant straight-RGBA source colour; word 6 is a validated explicit blend mode; word 7 is zero. Reads the destination but no source surface. Protocol 1.4 cores only (capability bit 8). |
| 10 | FILL_BATCH | Word 1 selects a descriptor table exactly as SPRITE_BATCH and word 3 is descriptor count, 1-64. Other words zero. Protocol 1.6 and newer cores only (capability bit 10). |
| 11 | PRESENT_QUEUED | Word 1 is display buffer 0-2 (A, B, C) or 3 for a flip barrier; others zero. Waits unaccepted while a flip is pending, then completes on acceptance while the flip happens at the next vblank; a barrier completes without flipping. Protocol 1.7 and newer cores only (capability bit 11). |

Bytes beyond the requested length in the last SDRAM page are not valid
copied data; the loader can flush stale page-buffer contents there.

A sprite descriptor has eight 32-bit words in this order:
`dst_addr, dst_pitch, width, height, colorkey, src_addr, src_pitch, flags`.
Pitch/dimension fields use their low 16 bits. Flags bit 0 enables color
keying. On protocol 1.2 cores (BLIT-008), bit 1 blends straight alpha,
bit 2 mirrors horizontally and bit 3 vertically; a descriptor with any of
those is a flagged draw whose colorkey word is instead an RGBA modulation
(`0xffffffff` = none), and it cannot also set bit 0. On protocol 1.3 cores
(BLIT-009), bit 4 replaces bit 1 with an explicit blend mode in bits 31:8:
SDL blend factors for colour source/destination in bits 13:10 and 17:14,
colour operation in 20:18, alpha factors in 24:21 and 28:25, alpha operation
in 31:29 and single rounding (SDL's MUL) in bit 8; bits 7:5 and 9 must be
zero. Without bit 4, bits 31:4 must be zero.
Descriptors run strictly in list order and each sees every earlier one's
completed writes; batching is not parallel sprite composition. Unflagged
copies with an even width and an 8-byte-aligned source address and pitch use
the paired copy engine; all others, and all flagged draws, use the blend
engine. Earlier cores ran every unflagged descriptor on the paired engine,
which leaves the last column of odd widths uncopied (hanging from the
second row on) and misreads sources that are not 8-byte aligned; avoid those
geometries on protocol 1.0 and 1.1 images.

A fill descriptor has eight 32-bit words in this order:
`dst_addr, dst_pitch, width, height, color, reserved0, reserved1, reserved2`.
All reserved words are zero. Descriptors execute strictly in list order through
the existing opaque fill engine, and the entire batch retires as one command.
Sprite and fill batches share the descriptor-table pool and fence ownership.

Submit only the documented valid commands. Unknown opcodes are dropped,
without a normal engine completion; invalid raw batch counts can stall
execution. Neither is a capability probe or a supported no-op/fence.

## Submission, completion and resource ownership

Ring header fields are 32-bit little-endian words:

| Byte offset | Writer | Meaning |
|---|---|---|
| +0 | Host after FPGA initialization | Next write index, modulo 64. |
| +4 | Reserved | Do not use. |
| +8 | FPGA | Next read index, modulo 64; advances on dispatch, not completion. |
| +12 | FPGA | Bits 30:0 completion count modulo 2^31; bit 31 front parity (0=A, 1=B). |

The ring leaves one slot empty: at most 63 queued slots, separate from a
command already dispatched. Publish slot contents and uploaded inputs
before updating the write pointer. Use the library's barriers and mapped
access path rather than substituting cached mappings or `volatile` alone.

The stage-2B control block is:

| Byte offset from `0x30020000` | Writer | Meaning |
|---|---|---|
| `+0x10` | FPGA | Magic `0x4e444c53`, published last. |
| `+0x14` | FPGA | Protocol version `0x00010006` (1.6, FILL_BATCH); `0x00010005`, `0x00010004`, `0x00010003`, `0x00010002`, `0x00010001` or `0x00010000` on older stage-2B images. |
| `+0x18` | FPGA | Capability mask `0x000007fe`; bit 10 advertises FILL_BATCH, bit 9 the descriptor ring, and bits 8 and 7 BLEND_FILL and BLIT_BLEND. Older images publish `0x000003fe`, `0x000001fe`, `0x000000fe` or `0x0000007e`. |
| `+0x1c` | FPGA | Width in bits 31:16, height in bits 15:0. |
| `+0x20` | FPGA | Pitch in bytes. |
| `+0x28/+0x2c` | Host | Request token low/high. |
| `+0x30` | Host | Request sequence. |
| `+0x38/+0x3c` | FPGA | Response token low/high. |
| `+0x40` | FPGA | Response sequence. |

On reset, hardware disables command polling and clears request/response
sequences before publishing identity. `noodles_link_open()` checks protocol,
capabilities and geometry, writes a random 64-bit token and claim sequence
`0x434c414d`, and waits for an exact echo. Only then does hardware enable the
ring. Later nonzero non-claim sequence echoes prove liveness; sequence zero
disarms the session. Static control bytes are not proof because DDR3 survives
core reload.

Serialize SDK calls. Cooperative process locking and the dirty marker remain
separate from hardware readiness; neither excludes legacy/direct memory
writers. Reset/reload during a handle clears the live response and causes
fallible SDK operations to return `ESTALE`. A reset racing a host write may
leave unconsumed bytes in DDR3, but the reset ring remains disabled and the
SDK does not report completion without a fresh challenge.

Successful push means submission, not completion. After a successful push,
capture `noodles_link_last_fence(device)` and use
`noodles_link_poll()` or `noodles_link_wait()`. Comparison is modulo 2^31 and
requires a target distance less than 2^30 completions. Do not compare raw
counts with `>=`, or use the ring read pointer to authorize asset reuse.

Keep all raw source pixels alive and unchanged until their last consumer
completes. Wait before CPU access to unfinished raw GPU destinations. SDK 0.9+
tracks an independent completion fence for every descriptor table:
sprite and fill batch submission select a free table and return `-1/EAGAIN`
before any descriptor write when all supported tables or the command ring are
busy. Raw opcode-5 or opcode-10 submissions claim their selected table; overlapping library
uploads are blocked until its completion. On older cores the supported pool is
one table, preserving the existing ownership rule.
Direct `/dev/mem` writes bypass this protection. Managed surfaces add general
allocation and lifetime tracking inside `[0x32000000, 0x40000000)`: their
source and destination fences are recorded on successful submission,
destruction defers reuse, and partial CPU transfers wait before access.

Draw into `noodles_link_back_buffer()`, then call
`noodles_present_and_wait()`, then query the back buffer again. The helper
returns 0 on completed presentation or -1 with errno on failure.
`noodles_push_present()` also supports submission separately from waiting.
A timeout faults the handle without cancelling the submitted command;
do not resubmit blindly or assume either buffer is safe to reuse. Raw and
typed PRESENT submissions both block further writes until SDK poll/wait
observes retirement and refreshes buffer tracking.

Close with one deadline drains, disarms the hardware session and always frees
local resources; check its return value. Failure leaves the session dirty.
If hardware still reports that session, verified reopen fails with
`EOWNERDEAD`; after an actual reload clears the response, verified reopen can
recover without a blind acknowledgement flag. Only retry transient `EAGAIN`;
report other errors. See [SDK.md](SDK.md) for the complete lifecycle policy.

## Handoff boundary

Step 1 documented the original unversioned interface. The subsequent SVGA
change kept command layouts and buffer addresses while changing geometry.
Stage 2B adds identified protocol 1.0 and a live session without changing
draw-command layouts. Preserve the older 640x480 image and its matching
stage-2A tools as the recovery fallback while later stages add managed
surfaces and the drawing operations required by GemRB.

This repository does not ship an SDL renderer or scaling API; MiSTer-GemRB
has validated an external SDL2 renderer against this interface. Source-over
blending is available as BLIT_BLEND; batched draws add RGBA tint, mirroring,
SDL's standard modes and composed factor modes. Protocol 1.4 adds ordered
constant-source blended rectangles through BLEND_FILL, protocol 1.5 adds
the descriptor ring without changing draw results, and protocol 1.6 adds
ordered opaque fill batches. The render target is
800x600. The existing RBF's MiSTer ALSA reader and HDMI output consumed and
played a paced 48kHz stereo test tone; the protocol-1.4 image still requires
the same hardware audio check. The planned first consumer is GemRB v0.9.5
through SDL2 2.32.10; platform video ownership and software fallback
synchronization still need design work.
