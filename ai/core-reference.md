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

---

## 4. Fast lookup index

```yaml
CORE-001: "2D engine and demo are a standalone, independent MiSTer core"
LINK-001: "Host-to-FPGA communication is DMA'd shared-memory command lists, not per-operation registers"
OUT-001: "CORE generates its own video timing and drives HDMI/VGA directly, like a normal MiSTer core"
SURF-001: "Surfaces live in SDRAM, addressed by raw byte address + pitch, no handle table in v1"
BLIT-001: "First milestone op set: solid-fill, straight blit, hardware static/noise-fill"
```

---

## 5. Architecture records

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
