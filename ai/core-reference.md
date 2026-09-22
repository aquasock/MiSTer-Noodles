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
```

---

## 3. Active routing

| Question | Consult first | Fast records |
|---|---|---|
| Is this its own core or does it live inside an existing one? | CORE component records | ARCH-001 |
| How does the host tell the FPGA what to draw? | LINK component records | ARCH-002 |

---

## 4. Fast lookup index

```yaml
ARCH-001: "2D engine and demo are a standalone, independent MiSTer core"
ARCH-002: "Host-to-FPGA communication is DMA'd shared-memory command lists, not per-operation registers"
```

---

## 5. Architecture records

```yaml
- record_id: ARCH-001
  kind: ARCHITECTURE
  component_id: CORE
  title: "Standalone MiSTer core"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "The FPGA-accelerated 2D graphics engine and its demo are implemented as their own independent MiSTer core, built with Quartus/RTL, and are not an overlay on the Linux framebuffer path, an extension of the Menu core, or dependent on any other core being loaded."
  consequence: "The project owns a full core build (top.v/sv, core-side HPS bridge instantiation, MiSTer framework integration) rather than only ARM-side userland. Earlier framebuffer-overlay work (src/spike_fb.c, fbterm_toggle.c, the F9/uinput toggle) is prior exploration, not the delivery path, and is superseded by this record for anything it conflicts with."

- record_id: ARCH-002
  kind: ARCHITECTURE
  component_id: LINK
  title: "Shared-memory command-list HPS-FPGA link"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "Linux/ARM userland communicates with the FPGA 2D engine by building command lists in HPS RAM. The FPGA-side command processor reads and executes those lists via DMA across the HPS-FPGA bridge, rather than the host issuing one register write per drawing operation."
  consequence: "The core needs a DMA-capable command processor and a defined command-list buffer format (ring buffer vs. discrete lists, head/tail signalling, completion notification) before any drawing command can be implemented. Register-level MMIO across the lightweight HPS-to-FPGA bridge is still needed for control/status (queue pointers, doorbell, engine status) even though drawing commands themselves are not per-register calls. The exact command encoding, buffer layout, and control-register map are not yet decided and need their own INTERFACE records before implementation starts."
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
