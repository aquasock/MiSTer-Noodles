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
layouts, pixel format, ownership and limitations for the planned GemRB
integration. It describes today's interface, not an implemented SDL renderer.
The standard configuration is 800x600 at 100MHz, using hardware-accepted
seed7. The older accepted 640x480 image remains a recovery fallback.

## Host-side API

`libnoodles.a` is the ARM-side static SDK: open the device,
push a `SOLID_FILL` or `BLIT_COPY`, pack a color (note: the byte order is
R in the low byte, not the `0xRRGGBB` reading a hex literal suggests --
see BLIT-004). After a successful push, capture
`noodles_link_last_fence(device)` and use `noodles_link_poll()` or the
deadline-based `noodles_link_wait()` to check completion.

Use an opaque handle from `noodles_link_open_legacy(&device, 0)`, with
serialized calls and a matching initialized, idle SVGA core. Hardware identity
is explicitly **unverified**. Cooperative process locking and a dirty-session
marker prevent another SDK producer from silently taking over unfinished work.
Bounded close drains and frees the handle; failure does not cancel FPGA work.
Reset during a handle's lifetime remains unsupported and undetectable.
See [docs/SDK.md](docs/SDK.md) for installation, lifecycle, errors and recovery.

`noodles_push_sprite_batch()` protects the fixed descriptor table until the
previous batch completes. It returns `-1` with `errno == EAGAIN` when the table
is busy or the ring is full, without modifying descriptors or publishing a
command. Retry later; other failures should be reported rather than retried.
Raw batch commands also acquire ownership, and overlapping
`noodles_link_upload()` calls are blocked while the table is owned.
Direct memory writes bypass this protection.

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
