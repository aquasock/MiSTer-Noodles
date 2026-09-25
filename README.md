# MiSTer-Noodles

A FPGA-accelerated 2D graphics engine for MiSTer, in the same vein as SDL:
an ARM/Linux host process handles game logic and drives a content-agnostic
2D "GPU" running in the FPGA fabric through a generic draw-command stream.
It builds and runs as its own standalone MiSTer core -- independent of any
other core, loaded and run the same way an emulator core is, not an overlay
or extension of Menu.

## Architecture

- **LINK** -- the host/FPGA transport. A host process writes draw commands
  into a 64-slot ring buffer in shared DDR3; `rtl/link_ring.sv` polls,
  fetches, and dispatches them to CMDQ. A completion fence
  (`rtl/link_fence.sv`) publishes back to DRAM once a command actually
  finishes, not just once it's accepted.
- **CMDQ** (`rtl/cmdq.sv`) -- decodes each 32-byte command slot and
  dispatches it to the matching engine.
- **BLIT** -- the draw engines. `rtl/blit.sv` implements `SOLID_FILL`;
  `rtl/blit_copy.sv` implements `BLIT_COPY` (straight rect copy, no
  scale/blend/format conversion). Both drive the real `DDRAM_*` pins
  through `rtl/ddram_adapter.sv`.
- **SURF** -- two fixed 800x600, 32bpp DDR3 scanout surfaces, flipped by
  `PRESENT` and displayed through `MISTER_FB`. Production sprite sources
  also use DDR3; board SDRAM is a separate, optional memory path.

Every decision behind this shape -- the ring buffer's memory layout, the
command slot format, the DDRAM addressing quirks that had to be found on
real hardware, the host API -- is recorded in
[ai/core-reference.md](ai/core-reference.md). That file is the
authoritative source for anything that looks like an interface contract;
[ai/core-log.md](ai/core-log.md) has the build-by-build history of how it
got there.

For the current consumer-facing baseline, start with
[docs/INTEGRATION.md](docs/INTEGRATION.md): memory reservations, command
layouts, pixel format, ownership and limitations for consumers. It describes
the core interface; the validated SDL2 renderer lives in MiSTer-GemRB.
Current source is the accepted protocol 1.6 fill-batch core at 800x600 and 100MHz.
It reuses the bounded descriptor-table ring to submit up to 64 ordered opaque
fills with one command. Protocol 1.5 seed 13, protocol 1.4 and the older
accepted 640x480 image remain recovery fallbacks.

## Host-side API

`libnoodles.a` is the ARM-side static SDK: open the device,
push a `SOLID_FILL` or `BLIT_COPY`, pack a color (note: the byte order is
R in the low byte, not the `0xRRGGBB` reading a hex literal suggests --
see BLIT-004). After a successful push, capture
`noodles_link_last_fence(device)` and use `noodles_link_poll()` or the
deadline-based `noodles_link_wait()` to check completion.

Use an opaque handle from `noodles_link_open(&device)`. The stage-2B core
publishes protocol, capability and geometry information, then enables its
command ring only after echoing a fresh 64-bit host session token. Completion
checks include a live challenge, so reset/reload faults the handle with
`ESTALE` instead of accepting a reset fence. Cooperative process locking and
a dirty-session marker remain in addition to the hardware session. Bounded
close drains, disarms and frees the handle; failure does not cancel FPGA work.
`noodles_link_open_legacy()` remains only for preserved pre-2B core images.
See [docs/SDK.md](docs/SDK.md) for installation, lifecycle, errors and recovery.

On protocol 1.5 and newer, `noodles_push_sprite_batch()` rotates through 64 protected
descriptor tables, allowing batches to queue up to the command-ring limit.
It returns `-1` with `errno == EAGAIN` when every table or the command ring is
busy, without modifying descriptors or publishing a command. SDK 0.9 retains
the single protected table when attached to protocol 1.4 and older cores. Raw
sprite and fill batch commands acquire ownership of their selected table, and overlapping
`noodles_link_upload()` calls are blocked until that table's fence completes.
Direct memory writes bypass this protection.

Protocol 1.6 and SDK 0.10 add `noodles_push_fill_batch()` and
`noodles_surface_fill_batch()`. A batch contains up to 64 clipped opaque
rectangles, executes strictly in descriptor order and retires as one fence.
SDK 0.11 adds `noodles_link_wait_progress()`, which lets a consumer retry
transient ring or descriptor pressure after one verified completion instead of
draining every later command.

The SDK permits one pending `PRESENT` while the next frame's commands queue
behind it. `noodles_link_back_buffer()` predicts the post-flip writable buffer
during that interval, managed-surface transfers synchronize against the
surface's own last use, and descriptor ownership still prevents table reuse.
A second `PRESENT`, arbitrary raw uploads and direct CPU back-buffer transfers
remain blocked until the pending flip retires.

## Build

    make          # cross-build the ARM-side host tools (static, armv7/Cortex-A9)
    make host     # native build of the same tools, for testing off-device
    make sim      # Verilator simulation of the RTL (CMDQ/BLIT/LINK)
    make test-host # native host-library regression; no MiSTer or /dev/mem needed
    make test-sdk-install # independent installed C/C++ and ARM consumers
    make install-sdk SDK_TARGET=arm PREFIX=/usr DESTDIR="$PWD/build/stage"
    make deploy HOST=192.168.1.42   # scp the tools to /media/fat/pet (root / "1")
    make clean

The FPGA bitstream itself is a normal Quartus project (`Noodles.qpf`);
`quartus_sh --flow compile Noodles` produces `output_files/Noodles.rbf` to
load via the OSD or `/dev/MiSTer_cmd`'s `load_core`. See
[docs/BUILD.md](docs/BUILD.md) for the full build/reproduction procedure and
[docs/QUALIFICATION.md](docs/QUALIFICATION.md) for what has been validated,
including a bit-for-bit reproducibility check.

## Try the host tools

Once the core is loaded on real hardware:

    build/arm/link-push                       # pushes one SOLID_FILL (cyan)
    build/arm/blit-copy-push 80 00 ff         # fills a source rect, then BLIT_COPYs it into view
    build/arm/solid-fill-push <addr> <pitch> <w> <h> <r> <g> <b>   # fill an arbitrary rect

`link-slot-dump` and `mem-scan` are raw diagnostics for reading the ring
buffer and scanning physical memory directly, useful when something isn't
landing where expected.

## Layout

    Noodles.sv            top-level core glue (sys/ framework <-> the engine)
    rtl/                  CMDQ, BLIT, BLIT_COPY, LINK, the DDRAM adapter
    sim/                  Verilator testbenches for the RTL above
    lib/                  noodles_link: the real ARM-side host API
    tools/                host-side CLI tools built on lib/noodles_link
    sys/                  Template_MiSTer framework with project adaptations
    ai/                   core.md / core-reference.md / core-log.md -- this
                           project's own architecture-decision and build log
