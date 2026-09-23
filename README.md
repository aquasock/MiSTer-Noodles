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
- **SURF** -- the surface memory model. Currently one fixed 64x64, 32bpp
  surface at a hardcoded physical address, scanned out over HDMI via
  `MISTER_FB`.

Every decision behind this shape -- the ring buffer's memory layout, the
command slot format, the DDRAM addressing quirks that had to be found on
real hardware, the host API -- is recorded in
[ai/core-reference.md](ai/core-reference.md). That file is the
authoritative source for anything that looks like an interface contract;
[ai/core-log.md](ai/core-log.md) has the build-by-build history of how it
got there.

## Host-side API

`lib/noodles_link.h`/`.c` is the real ARM-side library: open the ring,
push a `SOLID_FILL` or `BLIT_COPY`, pack a color (note: the byte order is
R in the low byte, not the `0xRRGGBB` reading a hex literal suggests --
see BLIT-004), and check `noodles_link_done_count()` against a value read
before the push to know when a specific command actually finished.

## Build

    make          # cross-build the ARM-side host tools (static, armv7/Cortex-A9)
    make host     # native build of the same tools, for testing off-device
    make sim      # Verilator simulation of the RTL (CMDQ/BLIT/LINK)
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
    sys/                  vendored Template_MiSTer framework, unmodified
    ai/                   core.md / core-reference.md / core-log.md -- this
                           project's own architecture-decision and build log
