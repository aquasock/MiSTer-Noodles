# PROJECT ARCHITECTURE REFERENCE

> **Project:** MiSTer-Noodles
> **Purpose:** The authoritative record of this project's own architecture and interface decisions for the FPGA-accelerated 2D graphics engine and its demo core.
> **Authority:** This project is not conforming to an external standard. A record in this file is authoritative because the project decided it, not because it cites an outside document. Once DECIDED, a record binds subsequent design and implementation until a later record supersedes it by name.

This file contains this project's own architecture decisions and interface contracts: how the engine is divided into components, how those components talk to each other, the HPS-FPGA command-list contract, register maps, pixel/surface formats, and the shape of the host-side API. It is deliberately limited to decisions and contracts. It does not contain project history, build status, test results, or the discussion that led to a decision -- see `core-log.md` for that.

---

## 1. AI operating rules

```yaml
schema_version: 1

record_kinds:
  - ARCHITECTURE   # how the system is divided into parts and how those parts relate
  - INTERFACE      # a concrete contract: register offset, command opcode, struct/buffer layout, timing
  - CONVENTION      # a naming, units, or formatting rule adopted for internal consistency

rules:
  - "Every record here is a decision this project made, not a citation of an external document. Do not invent or imply outside-standard conformance."
  - "Keep one decision or one interface contract per record."
  - "A record states the decision and its consequence, not the discussion, alternatives, or evidence that led to it. That belongs in core-log.md."
  - "Record only the contract other code depends on. Internal implementation details that can change without changing the interface do not get a record."
  - "Superseding a record: write a new record, mark the superseded record's status SUPERSEDED, and name the superseding record. Never rewrite a settled record's decision text in place."
  - "A PROPOSED record is not binding. Do not implement against it until it is promoted to DECIDED."
  - "Re-open a record when a later milestone changes its assumptions; note the change as a new record rather than editing history."
```

---

## 2. Component catalog

Component IDs are the `record_id` prefix for records that belong to that component. This catalog grows as the architecture is scoped; an entry here is a name reservation, not a design commitment.

```yaml
- component_id: CORE
  name: "Top-level core"
  description: "The standalone MiSTer core (Quartus/RTL) that hosts the 2D engine and the demo. Independent of every other MiSTer core -- not an overlay, not an extension of Menu or any other core."

- component_id: LINK
  name: "HPS-FPGA link"
  description: "The communication contract between Linux/ARM userland and the FPGA fabric: shared-memory command lists built by the host in HPS RAM and executed by the FPGA-side command processor via DMA."

- component_id: CMDQ
  name: "Command processor"
  description: "DMA-fetches the host's command list from HPS RAM, decodes opcodes, dispatches each command to BLIT, and reports completion back to the host."

- component_id: BLIT
  name: "Raster / draw unit"
  description: "Executes draw operations (fill, blit, and later color-key/alpha/scale) against surfaces in SDRAM."

- component_id: SURF
  name: "Surface memory model"
  description: "How pixel buffers are allocated and addressed in SDRAM."

- component_id: OUT
  name: "Display output"
  description: "Native MiSTer video timing generation and HDMI/VGA output, scanning out a surface to the screen."

- component_id: DDR
  name: "DDRAM_* physical bus adapter"
  description: "Translates BLIT's and CMDQ's generic byte-addressed ports onto the framework's real DDRAM_* pins (the F2H SDRAM Avalon-MM bridge into HPS DDR3). Separate from SURF, which is the logical addressing model (byte address + pitch); DDR is the physical wire protocol underneath it."
```

---

## 3. Active routing

| Question | Consult first | Fast records |
|---|---|---|
| Is this its own core or does it live inside an existing one? | CORE component records | CORE-001 |
| How does the host tell the FPGA what to draw? | LINK component records | LINK-001 |
| How does the picture get to the screen? | OUT component records | OUT-001 |
| Where do pixel buffers live and how are they addressed? | SURF component records | SURF-001 |
| What can the engine actually draw right now? | BLIT component records | BLIT-001 |
| What physical memory does a surface actually live in? | SURF component records | SURF-002 |
| How does a surface actually reach the screen? | OUT component records | OUT-002 |
| What does a command slot look like on the wire? | CMDQ component records | CMDQ-001 |
| What are SOLID_FILL's exact fields? | BLIT component records | BLIT-002 |
| How does a write actually reach DDRAM_*? | DDR component records | DDR-001 |

---

## 4. Fast lookup index

```yaml
CORE-001: "2D engine and demo are a standalone, independent MiSTer core"
LINK-001: "Host-to-FPGA communication is DMA'd shared-memory command lists, not per-operation registers"
OUT-001: "CORE generates its own video timing and drives HDMI/VGA directly, like a normal MiSTer core"
SURF-001: "Surfaces live in SDRAM, addressed by raw byte address + pitch, no handle table in v1"
BLIT-001: "First milestone op set: solid-fill, straight blit, hardware static/noise-fill"
SURF-002: "Surfaces live in the HPS-shared DDR3 (DDRAM_*), not the dedicated low-latency SDRAM_* chip"
OUT-002: "Display output uses the template's built-in MISTER_FB DDRAM framebuffer scan-out, not a custom timing generator"
CMDQ-001: "v1 command slot is a fixed 32-byte / 256-bit record, plain uint32 fields, no bit-packing"
BLIT-002: "SOLID_FILL (opcode 1) fields: dst_addr, dst_pitch, width, height, color"
DDR-001: "DDRAM_* is a standard Avalon-MM master port; v1 adapter does single-word (burstcnt=1), write-only, 4-byte-into-8-byte-word transfers"
```

---

## 5. Records

```yaml
- record_id: CORE-001
  kind: ARCHITECTURE
  component_id: CORE
  title: "Standalone MiSTer core"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "The FPGA-accelerated 2D graphics engine and its demo are implemented as their own independent MiSTer core, built with Quartus/RTL, and are not an overlay on the Linux framebuffer path, an extension of the Menu core, or dependent on any other core being loaded."
  consequence: "The project owns a full core build (top.v/sv, core-side HPS bridge instantiation, MiSTer framework integration) rather than only ARM-side userland. Earlier framebuffer-overlay work (src/spike_fb.c, fbterm_toggle.c, the F9/uinput toggle) is prior exploration, not the delivery path, and is superseded by this record for anything it conflicts with."

- record_id: LINK-001
  kind: ARCHITECTURE
  component_id: LINK
  title: "Shared-memory command-list HPS-FPGA link"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "Linux/ARM userland communicates with the FPGA 2D engine by building command lists in HPS RAM. The FPGA-side command processor reads and executes those lists via DMA across the HPS-FPGA bridge, rather than the host issuing one register write per drawing operation."
  consequence: "The core needs a DMA-capable command processor and a defined command-list buffer format (ring buffer vs. discrete lists, head/tail signalling, completion notification) before any drawing command can be implemented. Register-level MMIO across the lightweight HPS-to-FPGA bridge is still needed for control/status (queue pointers, doorbell, engine status) even though drawing commands themselves are not per-register calls. The exact command encoding, buffer layout, and control-register map are not yet decided and need their own INTERFACE records before implementation starts."

- record_id: OUT-001
  kind: ARCHITECTURE
  component_id: OUT
  title: "Native video output"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "CORE generates its own video timing and drives HDMI/VGA output directly, the same way a standard MiSTer core does, rather than presenting through the Linux framebuffer (/dev/fb0)."
  consequence: "CORE takes on standard MiSTer video-pipeline integration (sync/timing generation, scaler interface, video mode handling) as part of CORE/OUT. The Linux-framebuffer path explored in spike_fb.c and the F9/uinput toggle is not the presentation path for this engine, per CORE-001. Which SURF surface OUT scans out at any moment, and how that hand-off/flip is synchronized, needs its own INTERFACE record once the display timing is implemented."

- record_id: SURF-001
  kind: ARCHITECTURE
  component_id: SURF
  title: "SDRAM-resident, address+pitch surfaces"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "Surfaces (pixel buffers operated on by BLIT and scanned out by OUT) live in board SDRAM. Commands address a surface directly by its raw SDRAM byte address and row pitch; there is no surface-handle table or indirection layer in v1."
  consequence: "The host allocates and tracks surface addresses/pitches itself and encodes them literally into each command; the FPGA side does not validate surface existence or bounds beyond what BLIT needs to execute the op. A handle/indirection layer, if added later, is a superseding record, not a silent change, since it changes the command encoding."

- record_id: BLIT-001
  kind: ARCHITECTURE
  component_id: BLIT
  title: "First milestone op set"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "The first hardware-proof milestone implements exactly three BLIT operations: (1) solid-fill -- fill a destination rect in a surface with a constant color, (2) straight blit -- copy a source rect from one surface to a destination rect in another surface with no scaling or blending, (3) noise/static-fill -- fill a destination rect with the pet's procedural static pattern directly in hardware, ported from the same generator logic as the Menu core's static. No color-key, alpha blend, or scaling operations are in this milestone."
  consequence: "This scope directly targets the proven CPU bottleneck (full-1080p animated static could not hold frame rate in software -- 12 fps measured at 1920x1080, per README) as the milestone's proof point, while keeping the first CMDQ/BLIT implementation to the smallest op set that can show a hardware win. Color-key, alpha blending, and scaled blit are explicitly deferred to a later milestone and need their own records when scoped."

- record_id: SURF-002
  kind: INTERFACE
  component_id: SURF
  title: "Surfaces live in DDRAM, not the dedicated SDRAM_* chip"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "Template_MiSTer's sys/ framework exposes two distinct memories to a core: DDRAM_* (the HPS's own DDR3, high-latency, reached over the F2SDRAM bridge) and SDRAM_* (a dedicated lower-latency chip, present on boards with the MiSTer IO board). Only DDRAM_* is readable by the framework's built-in MISTER_FB scan-out path (sys/emu_ports.vh: 'Use framebuffer in DDRAM'). SURF-001's 'SDRAM' is therefore refined to mean DDRAM_*: surfaces live in HPS-shared DDR3, not the dedicated SDRAM_* chip."
  consequence: "BLIT's write port must ultimately drive DDRAM_ADDR/DDRAM_DIN/DDRAM_BE/DDRAM_WE (through an adapter -- DDRAM is a high-latency, burst-oriented, single-outstanding-request interface, not a simple one-cycle write port) rather than SDRAM_*. Because DDRAM is the same physical DDR3 the HPS/Linux side uses, the address space a surface lives in is reachable from both sides of LINK, which matters once LINK's own buffer needs to be told where a surface is. The dedicated SDRAM_* chip is tied off unused (see Noodles.sv) unless a future record claims it for something else."

- record_id: OUT-002
  kind: INTERFACE
  component_id: OUT
  title: "Use MISTER_FB DDRAM scan-out, not a custom raster timing generator"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "OUT uses Template_MiSTer's built-in MISTER_FB mechanism (FB_EN/FB_FORMAT/FB_WIDTH/FB_HEIGHT/FB_BASE/FB_STRIDE, gated by the MISTER_FB Verilog macro) to present a surface: CORE points FB_BASE/FB_STRIDE at a SURF surface in DDRAM and the framework's own video_mixer/scaler chain generates HDMI/VGA timing and reads that memory each frame. CORE does not implement its own HSync/VSync/pixel-clock raster generator, unlike Template.sv's default demo core."
  consequence: "This is still 'native video output' per OUT-001 -- CORE, not Linux and not another core, owns what FB_BASE points at -- but the low-level timing generation is shared framework code, which is normal for every MiSTer core, not unique to the FB path. The MISTER_FB macro is enabled project-wide in Noodles.qsf; Noodles.sv currently ties FB_EN=0 (blanked) since nothing writes a surface yet. Which surface is 'the display surface' and how a flip/swap is synchronized to FB_VBL still needs its own record once double-buffering is scoped."

- record_id: CMDQ-001
  kind: INTERFACE
  component_id: CMDQ
  title: "v1 command slot layout"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "A command is a fixed 32-byte (256-bit) slot, laid out as eight little-endian uint32 words with no sub-word bit-packing: word0 opcode (only [7:0] used), word1 dst_addr, word2 dst_pitch (only [15:0] used), word3 width (only [15:0] used), word4 height (only [15:0] used), word5 color, word6-word7 reserved (must be zero). CMDQ decodes exactly this layout; there is no variable-length or per-opcode-sized command in v1."
  consequence: "Every opcode, including future ones, is decoded against this same 32-byte slot until a record changes it -- an opcode needing more than 5 operand words is out of scope until superseded. Full-word fields (rather than tightly bit-packed ones) trade a few wasted bits for a slot a host-side C struct can populate with plain field assignment, no bitfields or shifts. rtl/cmdq.sv implements this layout; sim/tb_solid_fill.cpp's PackCommand() is the reference packing example."

- record_id: BLIT-002
  kind: INTERFACE
  component_id: BLIT
  title: "SOLID_FILL command semantics"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "Opcode 1 (SOLID_FILL) writes `color` into every pixel of a width x height rectangle whose top-left pixel is at byte address dst_addr, advancing dst_pitch bytes per row. Pixels are always 4 bytes; SOLID_FILL does not read dst_pitch or width/height in any unit other than pixels/bytes as stated, and performs no format conversion -- `color` is written verbatim as the destination surface's raw pixel bytes. width==0 or height==0 is a no-op (BLIT never asserts busy)."
  consequence: "The RTL (rtl/blit.sv) and its Verilator testbench (sim/tb_solid_fill.cpp) are the executable form of this record: one write per pixel on a generic byte-addressed port, row-major, address = dst_addr + row*dst_pitch + col*4. Fixed 4-byte pixels means BLIT-002 does not yet address the FB_FORMAT/pixel-format question (palette or 16-bit modes) -- that needs its own record before non-32bpp surfaces are supported. DDR-001's write adapter additionally requires dst_addr and dst_pitch to both be multiples of 4, so every pixel address stays 4-byte aligned; this is not yet enforced anywhere (neither host-side nor in BLIT) and should be before anything but hand-picked test values reaches it."

- record_id: DDR-001
  kind: INTERFACE
  component_id: DDR
  title: "DDRAM_* is Avalon-MM; v1 adapter is single-word, write-only"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "DDRAM_* is a standard Altera/Intel Avalon-MM master interface -- confirmed by reading sys/sys_top.v, which wires DDRAM_BUSY/DOUT_READY/RD/WE straight onto an f2h_sdram Avalon port's waitrequest/readdatavalid/read/write signals of the same name pattern. DDRAM_ADDR is a word address over a 64-bit (8-byte) data bus: word_addr = byte_addr[31:3]. A request (RD or WE asserted, ADDR/DIN/BE stable) is accepted on the clock edge DDRAM_BUSY is sampled low; the master must hold the request stable on every cycle DDRAM_BUSY is high. Read data returns asynchronously later, one DDRAM_DOUT_READY pulse per requested word. rtl/ddram_write_adapter.sv implements only single-word writes (DDRAM_BURSTCNT=1, DDRAM_RD tied low) -- no reads, no bursts, nothing for CMDQ's future DDR3 polling yet."
  consequence: "BLIT's existing generic wr_addr/wr_data/wr_en/wr_ready port (BLIT-002) needed no changes to work with this: its valid-held-until-ready convention already matches Avalon-MM's write/waitrequest semantics, so the adapter is purely combinational (DDRAM_WE=wr_en, DDRAM_ADDR=wr_addr[31:3], wr_ready=~DDRAM_BUSY). Because DDRAM_DIN is 8 bytes wide and BLIT writes 4-byte pixels, the adapter steers each write into the upper or lower half of DDRAM_DIN using wr_addr[2] and masks the other half off with DDRAM_BE -- correct only when wr_addr is 4-byte aligned (see BLIT-002's added consequence note). CMDQ's read path for LINK's ring buffer needs a second, read-capable adapter; this record and rtl/ddram_write_adapter.sv cover the write side only."
```

---

## 6. Record template

```yaml
- record_id: "<COMPONENT>-<NNN>"
  kind: ARCHITECTURE | INTERFACE | CONVENTION
  component_id: "<catalog ID>"
  title: "One atomic decision or contract"
  status: PROPOSED | DECIDED | SUPERSEDED
  decided_date: YYYY-MM-DD
  decision: "The decision or contract itself, stated exactly"
  consequence: "What this binds or rules out for subsequent design and implementation"
  supersedes: "<record_id>"   # only present on a record that supersedes an earlier one
```

---

## 7. Maintenance boundary

- Keep decisions, contracts, component identity, and their consequences here.
- Keep rationale, alternatives considered, timing results, tests, failures, and chronological history in `core-log.md`.
- Never invent a register offset, opcode, or buffer layout here ahead of it actually being decided -- an unscoped detail stays out of this file until it has a record.
- Component decomposition below CORE and LINK (e.g. blitter, compositor, format conversion, output/scaler interface) is intentionally unscoped until those milestones are approved; do not pre-load speculative components or records for them.

```yaml
last_reviewed: 2026-09-21
```
