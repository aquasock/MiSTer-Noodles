# Noodles integration baseline

This is the consumer-facing description of the 100MHz core, not
a new GPU ABI or an SDL implementation. Architecture decisions remain in
[ai/core-reference.md](../ai/core-reference.md); later records override
earlier bring-up assumptions. Relevant records include CMDQ-001,
BLIT-003/004/006, SURF-003/004/006, LINK-002/005/008/011 and SDR-008.

## Standard configuration: 800x600

Current source renders 800x600 with a 3200-byte pitch (SURF-006), retaining
the 100MHz GPU, 4:3 aspect ratio and existing buffer addresses. Each buffer
uses 1920000 bytes and still fits its reserved 2MiB slot. The HDMI mode is
independent: MiSTer's scaler scales this framebuffer to its configured output.
Seed7 passes all four timing corners and the user accepted its visible
hardware run. Its RBF SHA-256 is
`a020e304aa6903e06e55c2efdba15d1513fb3aa4db9494840b6028a3ba43a47a`.
It was built from `37d21c9` with only SEED changed to 7, pinned in source
`4cd38a7207e74771ca94351c6d7b94d307c69211`. Independent clean-rebuild verification was waived, not
completed. See [QUALIFICATION.md](QUALIFICATION.md) for provenance and results.

Build the host library/tools from the same source as the loaded core.
Geometry remains compile-time in FPGA logic, but protocol 1.0 reports and
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
| `[0x30022000, 0x30022800)` | 64 sprite descriptors, 32 bytes each. |
| `[0x31000000, 0x311d4c00)` | 800x600 buffer A pixels; within its fixed 2MiB slot beginning at `0x31000000`. |
| `[0x31200000, 0x313d4c00)` | 800x600 buffer B pixels; within its fixed 2MiB slot beginning at `0x31200000`. |
| `0x31400000` and tool-specific addresses | Demo scratch/assets, not an allocator or a promise of available capacity. |

Leave the control-memory neighborhood and both 2MiB scanout slots reserved;
do not treat gaps or demo addresses as a shared allocator. Run only one
producer/application and no concurrent memory-writing diagnostic tools.
The later managed-surface stage must establish its own bounded arena and
exclude all platform/control/scanout uses before allocating textures.

Pixels occupy four bytes, with increasing-address bytes **R, G, B, unused**.
`noodles_rgb(r,g,b)` produces `r | (g << 8) | (b << 16)` with a zero high byte.
This is not yet an RGBA blending contract. Copies preserve all 32 bits and
color-key comparisons compare the entire 32-bit pixel; initialize the high
byte consistently. Scanout uses `FB_FORMAT=00110`, pitch 3200 bytes in
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
| 5 | SPRITE_BATCH | Word 3 is descriptor count, 1-64. Library writes word 1 as `0x30022000`; hardware always fetches from that fixed base, not a relocatable list pointer. Other words zero. |
| 6 | LOAD_SDRAM | Word 1 is board-SDRAM destination, word 5 byte length, word 6 DDR3 source; others zero. Destination aligned to 1024 bytes; loader copies complete pages, so source/destination backing storage must cover the rounded-up length. |

Bytes beyond the requested length in the last SDRAM page are not valid
copied data; the loader can flush stale page-buffer contents there.

A sprite descriptor has eight 32-bit words in this order:
`dst_addr, dst_pitch, width, height, colorkey, src_addr, src_pitch, flags`.
Pitch/dimension fields use their low 16 bits. Flags bit 0 enables color
keying; all other flag bits are reserved and must be zero. Descriptors run
in list order using the existing copy engine; batching is not parallel
sprite composition.

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
| `+0x14` | FPGA | Protocol version `0x00010000`. |
| `+0x18` | FPGA | Opcode capability mask `0x0000007e`. |
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

Keep all source pixels alive and unchanged until their last consumer
completes. Wait before CPU access to unfinished GPU destinations. Only the
fixed descriptor table has library-managed ownership today:
`noodles_push_sprite_batch()` returns `-1/EAGAIN` before any descriptor
write when that table is busy or the ring is full. Raw opcode-5 submissions
also claim it; overlapping library uploads are blocked until completion.
Direct `/dev/mem` writes bypass this protection; the SDK rejects
draw commands targeting the control region. It is not general texture
lifetime management.

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

There is currently no SDL renderer, texture allocator, alpha blending,
tint, scaling or flipping API. The new render target is 800x600 and core audio is
silent. The planned first consumer is GemRB v0.9.5 through SDL2 2.32.10;
platform video/audio ownership and software fallback synchronization still
need design work. These are explicit future requirements, not advertised
capabilities of the accepted core.
