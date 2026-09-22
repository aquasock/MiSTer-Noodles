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
| What DDR3 addresses are actually safe to write? | SURF component records | SURF-003 |
| What does a DDRAM_ADDR value actually target physically? | DDR component records | DDR-002 |
| Where does today's hardcoded test command come from? | CMDQ component records | CMDQ-002 |
| What surface does the OSD's Draw Test actually display? | OUT component records | OUT-003 |
| Is any address inside SURF-003's window actually unsafe? | SURF component records | SURF-004 |
| What are BLIT_COPY's exact fields? | BLIT component records | BLIT-003 |
| How does a read reach DDRAM_*? | DDR component records | DDR-003 |
| Does polling for LINK steal video scan-out bandwidth? | DDR component records | DDR-004 |
| Where does the ring buffer live in memory? | LINK component records | LINK-002 |
| How does CMDQ actually find and fetch a queued command? | LINK component records | LINK-003 |
| Why does a shared read port need a "who's mid-request" signal, not just rd_en? | DDR/LINK component records | DDR-005 |

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
SURF-003: "Safe FPGA-writable DDR3 window is Linux physical [0x20000000,0x40000000); the first 32MB of it is Main_MiSTer's own 'Core's fb' region"
DDR-002: "DDRAM_ADDR is a direct, unwindowed physical word address (word N = byte N*8) -- confirmed on hardware; word 0 is physical 0x0, not 0x20000000"
CMDQ-002: "'Draw Test' OSD button fires one hardcoded SOLID_FILL through CMDQ -- temporary stand-in for LINK's ring buffer"
OUT-003: "Draw Test's surface: 64x64, 32bpp, pitch 256, base 0x30000000; FB_EN gated on the fill having completed at least once"
SURF-004: "Physical 0x20000000 itself is unsafe -- MiSTer's own system video scaler uses it; 0x30000000 is the proven-safe address (per aquasock/MiSTer-Raster's hardware-learned fix)"
BLIT-003: "BLIT_COPY (opcode 2) reuses dst_addr/pitch/width/height, adds src_addr (word 6) and src_pitch (word 7) where SOLID_FILL had reserved words"
DDR-003: "Generic single-outstanding read port added to the DDRAM adapter (ddram_write_adapter.sv -> ddram_adapter.sv), muxed onto the shared physical bus alongside the write port"
DDR-004: "DDRAM_* (ram1) is a separate physical F2H SDRAM port from MISTER_FB's own vbuf scan-out port and ram2's audio/palette port -- no Avalon-level contention"
DDR-005: "A shared read-port mux must select on a REQ+WAIT-spanning signal (link_ring's new rd_active), not a requester's own rd_en, or it silently hands a pending response's byte-half-select to the wrong (idle) client -- found via a link-pushed dst_addr reading back as opcode's own value"
LINK-002: "64-slot ring buffer at phys 0x30020000 (header: write_ptr +0, read_ptr +8) / 0x30021000 (slots), reusing CMDQ-001's 32-byte slot format"
LINK-003: "link_ring.sv polls write_ptr only while CMDQ is idle (cmd_ready), fetches via 8 sequential reads, dispatches to CMDQ, writes back read_ptr"
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

- record_id: SURF-003
  kind: INTERFACE
  component_id: SURF
  title: "Safe DDR3 address window, confirmed from Main_MiSTer source"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "Read directly from the MiSTer-devel/Main_MiSTer source (shmem.h, video.cpp, and the load-address bounds checks in user_io.cpp/menu.cpp). The entire upper half of the board's DDR3, Linux physical address range [0x20000000,0x40000000) (512MB), is reserved for FPGA-side use -- shmem.h's `fpga_mem(x) = 0x20000000 | (x & 0x1FFFFFFF)` and every loader path in Main reject addresses outside it. Within that window, video.cpp's `FB_ADDR = 0x20000000 + 32MB` carries the comment '512mb + 32mb(Core's fb)': the first 32MB, physical 0x20000000-0x21FFFFFF, is explicitly set aside for a core's own use, distinct from Main's own wallpaper framebuffers which start at 0x22000000. This is independently corroborated by core.md's own hardware notes, which record Linux as seeing only ~492 MiB of the board's 1GB DDR3 -- consistent with Linux being capped below this reserved window."
  consequence: "SURF surfaces and LINK's future ring buffer belong inside the 32MB Core's-fb sub-window (physical 0x20000000-0x21FFFFFF), not just anywhere in the full 512MB FPGA-reserved range, to avoid ever colliding with Main's own framebuffer use above 0x22000000. This gives an exact, sourced address range for the first real hardware test, rather than a guess -- but see DDR-002 for what is still unconfirmed about how this Linux-side physical address relates to the FPGA-side DDRAM_ADDR value that actually needs to be programmed."

- record_id: DDR-002
  kind: INTERFACE
  component_id: DDR
  title: "DDRAM_ADDR is a direct, unwindowed physical word address"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "Checked on real hardware (QMTech MiSTer, DE10-Nano-compatible). The original working assumption -- that DDRAM_ADDR was window-relative, with word 0 corresponding to physical 0x20000000 -- was wrong. rtl/ddram_marker_test.sv, first built targeting DDRAM_ADDR=0 (byte address 0x0), wrote its marker word to physical 0x00000000: confirmed by a full 1GB /dev/mem scan (tools/ddram_marker_scan.c) that found the marker at exactly phys 0x0 and nowhere in the SURF-003 reserved region. DDRAM_ADDR is a direct physical word address with no base offset or window translation: word N corresponds to byte address N*8 in the same address space Linux itself uses, including its own live RAM. Main_MiSTer's fpga_mem(x) = 0x20000000 | (x & 0x1FFFFFFF) macro is purely a software convention for Main's own use of the reserved region -- it does not describe any hardware bridge address translation, and does not apply to a core's own DDRAM_ADDR value."
  consequence: "DDR-001's adapter math (word_addr = byte_addr>>3) was already correct and needed no change -- what was wrong was treating an address like 0x0 as safely inside the reserved window. Every address a core puts on DDRAM_ADDR, directly or via BLIT-002's dst_addr, must be a real absolute physical address already known to be safe (i.e. inside SURF-003's [0x20000000,0x40000000) window -- there is no offset that makes a small or zero-based address safe. SURF-004 later found that 0x20000000 itself, despite being inside this window, is not safe either -- see that record before picking an address from this one alone. ddram_marker_test now targets 0x20000000 directly; re-verified on hardware and tools/ddram_marker_check.c confirms PASS. One stray word was written to live physical address 0x0 during this discovery; the system remained stable, but a reboot before relying on this build for anything else is the clean way to clear that uncertainty rather than assume it was harmless."

- record_id: CMDQ-002
  kind: INTERFACE
  component_id: CMDQ
  title: "Draw Test hardcoded command"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "The OSD's 'Draw Test' button (Noodles.sv, rtl/cmd_test_trigger.sv) fires exactly one fixed SOLID_FILL command through CMDQ on each press, encoded per CMDQ-001's slot layout: opcode=1, dst_addr=0x30000000, dst_pitch=256, width=64, height=64, color=0x00FF00FF (magenta), reserved words zero. cmd_test_trigger is a generic one-shot 'present this fixed command to CMDQ until accepted' module, not specific to this command."
  consequence: "This is explicitly a stand-in for LINK-001's still-unbuilt ring buffer, not a step toward it architecturally -- CMDQ has no other way to receive a command today. Every field is hardcoded in Noodles.sv; changing what gets drawn means editing and resynthesizing the core, not sending a different command. sim/cmd_trigger_dut.sv and sim/tb_cmd_trigger.cpp verify this exact command end to end (CMDQ decode through BLIT's pixel writes) and must be kept identical to Noodles.sv's DRAW_TEST_COMMAND if either changes."

- record_id: OUT-003
  kind: INTERFACE
  component_id: OUT
  title: "Draw Test's MISTER_FB surface and FB_EN gating"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "FB_FORMAT/FB_WIDTH/FB_HEIGHT/FB_BASE/FB_STRIDE are hardcoded in Noodles.sv to match CMDQ-002's command exactly: 64x64, 32bpp (FB_FORMAT[2:0]=3'b110), base 0x30000000, stride 256. FB_EN and FB_FORCE_BLANK are gated on a 'draw ever completed' latch (set the first time the Draw Test command's BLIT fill finishes) rather than tied on unconditionally, so the display stays blank until a real fill has happened at least once instead of showing whatever was previously in memory at that address."
  consequence: "The surface parameters here are not derived from CMDQ-002's command at elaboration time -- they are separately hardcoded and must be kept in sync by hand; a future record should make BLIT/CMDQ and OUT share one source of truth for surface geometry before this becomes a real API. CE_PIXEL, previously tied to constant 0, was also changed to a real toggling signal as part of this record's bring-up -- the framework's OSD/mixer chain needs it regardless of whether the picture comes from MISTER_FB or a core's own raster output; see the comment in Noodles.sv for what was checked."

- record_id: SURF-004
  kind: INTERFACE
  component_id: SURF
  title: "Physical 0x20000000 itself is unsafe -- MiSTer's system video scaler owns it"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "Physical byte address 0x20000000 -- the very start of SURF-003's [0x20000000,0x40000000) FPGA-reserved window, and this project's first choice of surface/marker address -- is not actually free for a core to use. It is MiSTer's own system video scaler's RAM base. This is not inferred: it is a direct, hardware-learned lesson from the aquasock/MiSTer-Raster project (a much more mature sibling MiSTer core, same author), whose commit 53f322905 ('Move H262 frame store out of scaler DDR region') states plainly: 'MiSTer's system video scaler uses physical DDR byte address 0x20000000 as its RAM base.' That project originally placed its own DDR3 picture store at word address 0x04000000 (= physical 0x20000000, the same value this project's SURF-003 treated as safe) and moved it to word address 0x06000000 (= physical 0x30000000) after hitting a real collision. Every subsequent hardware-accepted release of that project (through v0.9.5, per its changelog) has used 0x30000000+ without incident."
  consequence: "This project's marker test, Draw Test command, and FB_BASE were all originally pointed at 0x20000000 and have been moved to 0x30000000 as a result, before ever enabling FB_EN or displaying anything from that address (SURF-003's DECIDED status and its 'Core's fb' sub-window language are not wrong about Linux's own reservation, just incomplete about a second, FPGA-side consumer within it -- treat SURF-003 plus this record together, not SURF-003 alone, when picking an address). This is also a standing reminder to consult aquasock/MiSTer-Raster before re-deriving platform facts this project may already have hard-won answers for (recorded separately in this session's persistent memory, not in this file)."

- record_id: BLIT-003
  kind: INTERFACE
  component_id: BLIT
  title: "BLIT_COPY command semantics"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "Opcode 2 (BLIT_COPY), the second of BLIT-001's three milestone ops, copies a width x height rectangle from a source surface to a destination surface with no scaling, blending or format conversion, 4 bytes/pixel like SOLID_FILL. It reuses CMDQ-001's existing 32-byte slot without changing the layout: dst_addr/dst_pitch/width/height keep their SOLID_FILL positions (words 1-4), color (word 5) is unused for this opcode, and the two words CMDQ-001 called 'reserved, must be zero' become src_addr (word 6) and src_pitch (word 7) instead -- reserved words are zero only for opcodes that do not define them, not universally; CMDQ-001's slot positions are unchanged, only which opcodes assign meaning to which words grows. Implemented as a separate module, rtl/blit_copy.sv, dispatched by CMDQ alongside rtl/blit.sv (SOLID_FILL) rather than merging the two engines -- keeps the already-proven fill FSM untouched."
  consequence: "BLIT_COPY needs a read port for the first time -- see DDR-003. Per-pixel it issues a read at src_addr+row*src_pitch+col*4, waits for that one word, then writes it to dst_addr+row*dst_pitch+col*4 before advancing; exactly one outstanding read at a time, never a second read issued before the first is consumed. Source and destination rectangles are not checked for overlap; an overlapping copy's result is whatever row-major read-then-write order produces, not a defined semantic."

- record_id: DDR-003
  kind: INTERFACE
  component_id: DDR
  title: "Generic read port, single-outstanding, added to the DDRAM adapter"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "rtl/ddram_write_adapter.sv is replaced by rtl/ddram_adapter.sv, which adds a generic read port (rd_addr/rd_en/rd_ready/rd_data/rd_valid) alongside the existing write port, muxed onto the one physical DDRAM_* bus (ADDR/BURSTCNT/RD/WE are shared fields -- only one of a read or a write request can be presented in a given cycle). Read protocol mirrors the write side's Avalon-MM shape: rd_en/rd_addr held stable until rd_ready is sampled (word_addr=byte_addr>>3, same as writes), then some cycles later rd_valid pulses once with rd_data holding the selected 32-bit half of the 64-bit DDRAM_DOUT word (addr[2] selects half, same convention as DDRAM_BE on writes). This is deliberately simpler than aquasock/MiSTer-Raster's DDR arbiter (mpeg2_h262_ddram_arbiter.sv), which tracks multiple concurrent outstanding reads per client with a descriptor queue tagging each response's owner -- this project has exactly one reader (BLIT-003's copy engine) with exactly one outstanding read at a time, so no response-ownership tracking is needed yet."
  consequence: "If a second concurrent DDR3 reader is ever added (e.g. a future BLIT op needing two source reads in flight, or LINK's CMDQ polling running concurrently with an in-flight BLIT read), this single-outstanding assumption breaks and the descriptor-queue pattern from MiSTer-Raster's arbiter is the proven design to reuse rather than re-deriving response-ownership tracking from scratch. Read and write requests share one mux into the adapter; today's only clients (marker_test, blit's fill writes, blit_copy's read+write) never contend for it simultaneously by construction of their own FSMs, not because the adapter enforces it -- a future concurrent client would need real arbitration, not just another mux input."

- record_id: DDR-004
  kind: INTERFACE
  component_id: DDR
  title: "DDRAM_* is a separate physical port from MISTER_FB's own scan-out"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "Read from sys/sys_top.v: sysmem_lite exposes three independent physical DDR3 access ports -- ram1 (64-bit, mapped straight to the core's own DDRAM_* pins, what this project's adapter uses), ram2 (64-bit, driven by ddr_svc for ALSA audio and the 8bpp palette), and vbuf (128-bit, wider, feeding the framework's own HDMI framebuffer/ascal scan-out). These are separate Avalon-MM ports into the memory controller, not one shared bus this core's own reads/writes contend with at the Avalon level."
  consequence: "CMDQ's future ring-buffer polling (LINK-003) does not need to be throttled to protect MISTER_FB's video scan-out bandwidth -- they are different hardware ports, so the earlier concern (raised before OUT-002/OUT-003 were ever tested) does not apply. The underlying DDR3 chip and its controller are still shared by all three ports plus HPS/Linux, so this is not a claim of zero contention at the physical DRAM level, only that there is no Avalon-level arbitration this core's polling needs to cooperate with."

- record_id: DDR-005
  kind: INTERFACE
  component_id: DDR
  title: "A shared read-port mux must track who has a response pending, not just who is currently requesting"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "Noodles.sv's 2-way read-port mux (link_ring vs blit_copy, feeding the one shared ddram_adapter per DDR-003) originally keyed its selector on rd_en alone (`rd_sel_link = link_rd_en`). rd_en is a requester's one-shot REQ-phase pulse -- link_ring's own rd_en is (state==POLL_REQ)||(state==FETCH_REQ), dropping the instant a request is accepted and the requester moves to its WAIT phase. But the response (rd_valid/rd_data) arrives during that WAIT phase, sometimes many cycles later. With rd_en as the selector, the mux fell through to the OTHER client's (idle, address 0) signals for the entire WAIT window, so by the time rd_valid actually pulsed, ddram_adapter's byte-half-select (`rd_addr[2] ? dout[63:32] : dout[31:0]`) used the wrong client's (idle) address bit instead of the real requester's pinned one. Found on real hardware: a link-pushed SOLID_FILL's dst_addr field (word_idx=1, upper half of the same aligned DDRAM word as word_idx=0/opcode) consistently read back as opcode's own raw value (1) -- the lower half of that same word -- because copy_rd_addr's idle value (0, bit[2]=0) selected the wrong half at the moment link_ring's response landed. CMDQ/BLIT never saw this as an error: blit_start still fired (a valid-looking, just wrong, dst_addr) and blit_done still fired (once width/height happened to also read correctly), so the failure was silent -- no busy/stuck state, no dropped command, just a write that landed at physical address 1 instead of 0x30000000 and was never found by a memory scan of the address it was expected at. Fixed by giving link_ring a new rd_active output (POLL_REQ||POLL_WAIT||FETCH_REQ||FETCH_WAIT -- the same REQ+WAIT span rd_addr itself was already pinned across) and using that, not rd_en, as the mux selector."
  consequence: "Any future shared-port mux between two request/response clients on this DDRAM adapter must select on a signal spanning the full REQ+WAIT lifetime of a pending transaction, never on the requester's own rd_en/wr_en (which by design only pulses during the REQ phase). This bug was invisible to `make sim`'s link_ring testbench (sim/link_ring_dut.sv) because that DUT wires link_ring directly to its own ddram_adapter instance with no second client and no mux at all -- it never exercised the failure mode that only exists once a real mux with an idle-but-present second client is in the loop. Simulation coverage for shared-bus arbitration bugs requires a testbench that actually includes the mux and a plausible idle second client, not just the module in isolation; no such testbench exists yet for this specific mux, so this class of bug could recur for BLIT-003's own read requests if ddram_adapter ever gains a third client without the same rd_active-style pattern."

- record_id: LINK-002
  kind: INTERFACE
  component_id: LINK
  title: "Ring buffer memory layout"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "LINK-001's command list is a fixed-size ring of 64 slots, each CMDQ-001's existing 32-byte format, unchanged. Header at physical 0x30020000: write_ptr (host-writable slot index, FPGA reads) at +0, read_ptr (FPGA-writable slot index, host reads) at +8 -- a different 8-byte DDRAM word than write_ptr, so the two fields never share a read/write hazard on the same word. The slot array starts at physical 0x30021000 (4KB past the header, generously aligned), 64*32=2048 bytes. Both pointers are plain slot indices 0-63, wrapping mod 64 (a power of 2, so wrap is a 6-bit mask, not a compare)."
  consequence: "A full ring (write_ptr catching up to read_ptr from behind) is indistinguishable from an empty one (write_ptr==read_ptr) with this design -- the host must never let write_ptr advance to equal read_ptr except when genuinely empty, i.e. must track its own count and stop producing at 63 outstanding commands, not 64. No record yet defines the host-side API that enforces this; it is a real constraint whoever writes that API must respect, not something CMDQ can protect itself against from the FPGA side."

- record_id: LINK-003
  kind: INTERFACE
  component_id: LINK
  title: "Polling and dispatch protocol"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "rtl/link_ring.sv polls LINK-002's write_ptr continuously whenever CMDQ's cmd_ready is asserted (CMDQ idle, no engine busy) -- DDR-004 established this does not contend with video scan-out bandwidth, so no throttling is applied. On a mismatch with its own registered read_ptr, it fetches the 32-byte slot at slot_base+read_ptr*32 via 8 sequential 4-byte reads over the shared read port (DDR-003), presents the assembled 256 bits to CMDQ exactly as the OSD test triggers already do (cmd_valid/cmd_data, held until cmd_ready), then on acceptance advances read_ptr mod 64 and writes it back to the header before resuming polling. Gating all polling/fetching on cmd_ready -- not polling continuously regardless of engine state -- keeps DDR-003's single-outstanding-read assumption valid without needing real arbitration between blit_copy's reads and link_ring's: whenever an engine is busy (mid-copy, potentially mid-read), cmd_ready is low and link_ring issues no reads at all."
  consequence: "This makes LINK's own dispatch latency depend entirely on how long the currently-running command takes -- a slow future BLIT op would delay LINK from even checking for the next command, not just from starting it. That is an acceptable v1 tradeoff for a simple, provably-non-contending design, not a permanent limit; a future record can revisit if it becomes a real bottleneck. rtl/link_ring.sv is CMDQ's third command source, joining (and eventually replacing) the OSD test triggers through the same priority-mux pattern already used for draw_test/copy_test."
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
