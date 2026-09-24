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

- component_id: SDR
  name: "SDRAM_* board controller"
  description: "Drives the framework's real SDRAM_* pins (the optional MiSTer SDRAM daughterboard/onboard chip, GPIO-wired to FPGA fabric only -- confirmed HPS-invisible, distinct from DDR's HPS-shared F2H DDR3 bridge). Shares the 100MHz clk_sys net under SDR-008. Provides an optional FPGA-owned memory path; production sprite reads remain on DDR3."
```

---

## 3. Active routing

| Question | Consult first | Fast records |
|---|---|---|
| Is this its own core or does it live inside an existing one? | CORE component records | CORE-001 |
| How does the host tell the FPGA what to draw? | LINK component records | LINK-001 |
| How does the picture get to the screen? | OUT component records | OUT-001 |
| Where do pixel buffers live and how are they addressed? | SURF component records | SURF-001 |
| What can the engine actually draw right now? | BLIT component records | BLIT-005 |
| What physical memory does a surface actually live in? | SURF component records | SURF-002 |
| How does a surface actually reach the screen? | OUT component records | OUT-002 |
| What does a command slot look like on the wire? | CMDQ component records | CMDQ-001 |
| What are SOLID_FILL's exact fields? | BLIT component records | BLIT-002 |
| How does a write actually reach DDRAM_*? | DDR component records | DDR-001 |
| What DDR3 addresses are actually safe to write? | SURF component records | SURF-003 |
| What does a DDRAM_ADDR value actually target physically? | DDR component records | DDR-002 |
| What surface does MISTER_FB scan-out actually display? | OUT component records | OUT-003 |
| How do I avoid tearing when drawing animated content? Which buffer do I draw into? | OUT component records | OUT-004 |
| Why were the OSD test buttons (Marker/Draw/Blit Copy Test) removed? | CMDQ component records | CMDQ-003 |
| Is any address inside SURF-003's window actually unsafe? | SURF component records | SURF-004 |
| What resolution are the surfaces, and where do they live now? | SURF component records | SURF-006 |
| What are BLIT_COPY's exact fields? | BLIT component records | BLIT-003 |
| How does a read reach DDRAM_*? | DDR component records | DDR-003 |
| Does polling for LINK steal video scan-out bandwidth? | DDR component records | DDR-004 |
| Where does the ring buffer live in memory? | LINK component records | LINK-002 |
| How does CMDQ actually find and fetch a queued command? | LINK component records | LINK-003 |
| Why does a shared read port need a "who's mid-request" signal, not just rd_en? | DDR/LINK component records | DDR-005 |
| How are mixed DDRAM reads and writes captured and retired? | DDR component records | DDR-006 |
| Why does the DDRAM read port only ever issue burstcnt=1 commands, and how was that fixed? | DDR component records | DDR-007 |
| How do I pack an R,G,B color into SOLID_FILL's color field? | BLIT component records | BLIT-004 |
| Why doesn't the engine have a third (noise-fill) op? | BLIT component records | BLIT-005 |
| How do I composite a sprite over a background without a bounding box? | BLIT component records | BLIT-006 |
| How does alpha blending work, and what exact arithmetic does it use? | BLIT component records | BLIT-007 |
| Which protocol version and capability bits does the core publish? | LINK component records | LINK-012 |
| What's the real host-side API for pushing commands, and does it tell me when a draw finished? | LINK component records | LINK-004 |
| How does the host know a specific command has actually finished, not just been dispatched? | LINK component records | LINK-005 |
| How does real image/asset data (not a SOLID_FILL rect) get into a surface? | LINK component records | LINK-006 |
| Is it safe to pipeline several commands (including a PRESENT) without fence-waiting each one individually? | LINK component records | LINK-007 |
| Does OUT-004's single-vblank-edge PRESENT margin actually hold under heavy per-frame draw load? | OUT component records | OUT-005 |
| When has ascal reached its output-domain frame retirement boundary? | OUT component records | OUT-007 |
| Does the FPGA's SDRAM board actually reach the HPS/Linux side at all? | SDR component records | SDR-001 |

---

## 4. Fast lookup index

```yaml
CORE-001: "2D engine and demo are a standalone, independent MiSTer core"
LINK-001: "Host-to-FPGA communication is DMA'd shared-memory command lists, not per-operation registers"
OUT-001: "CORE generates its own video timing and drives HDMI/VGA directly, like a normal MiSTer core"
SURF-001: "Surfaces live in SDRAM, addressed by raw byte address + pitch, no handle table in v1"
BLIT-001: "SUPERSEDED by BLIT-005 -- third op (Menu-static noise-fill) dropped, not built"
SURF-002: "Surfaces live in the HPS-shared DDR3 (DDRAM_*), not the dedicated low-latency SDRAM_* chip"
OUT-002: "Display output uses the template's built-in MISTER_FB DDRAM framebuffer scan-out, not a custom timing generator"
CMDQ-001: "v1 command slot is a fixed 32-byte / 256-bit record, plain uint32 fields, no bit-packing"
BLIT-002: "SOLID_FILL (opcode 1) fields: dst_addr, dst_pitch, width, height, color"
DDR-001: "DDRAM_* is a standard Avalon-MM master port; v1 adapter does single-word (burstcnt=1), write-only, 4-byte-into-8-byte-word transfers"
SURF-003: "Safe FPGA-writable DDR3 window is Linux physical [0x20000000,0x40000000); the first 32MB of it is Main_MiSTer's own 'Core's fb' region"
DDR-002: "DDRAM_ADDR is a direct, unwindowed physical word address (word N = byte N*8) -- confirmed on hardware; word 0 is physical 0x0, not 0x20000000"
CMDQ-002: "SUPERSEDED by CMDQ-003 -- 'Draw Test' OSD button and rtl/cmd_test_trigger.sv no longer exist"
OUT-003: "MISTER_FB surface: 64x64, 32bpp, pitch 256, base 0x30000000; FB_EN gated on a fill having completed at least once"
OUT-004: "PRESENT (opcode 4): vblank-synced double-buffer flip between BUFFER_A (0x30000000) and BUFFER_B (0x30008000); noodles_link_back_buffer()/noodles_present_and_wait() are the host API"
OUT-006: "SUPERSEDED by OUT-007 -- base-latch acknowledgement alone was insufficient"
OUT-007: "PRESENT waits for ascal's synchronized output-domain retirement acknowledgement, then one additional fresh FB_VBL edge before completing"
CMDQ-003: "OSD test scaffolding (Marker/Draw/Blit Copy Test) retired once LINK-004/LINK-005 proved the real ring-buffer path end to end; CMDQ's command front end is link_ring-only again"
SURF-004: "Physical 0x20000000 itself is unsafe -- MiSTer's own system video scaler uses it; 0x30000000 is the proven-safe address (per aquasock/MiSTer-Raster's hardware-learned fix)"
SURF-005: "Surfaces sized up to 640x480 (StarCraft/OpenBW-scale, was 64x64 bring-up size); BUFFER_A/BUFFER_B moved to 2MB-aligned slots at 0x31000000/0x31200000"
BLIT-003: "BLIT_COPY (opcode 2) reuses dst_addr/pitch/width/height, adds src_addr (word 6) and src_pitch (word 7) where SOLID_FILL had reserved words"
DDR-003: "Generic single-outstanding read port added to the DDRAM adapter (ddram_write_adapter.sv -> ddram_adapter.sv), muxed onto the shared physical bus alongside the write port"
DDR-004: "DDRAM_* (ram1) is a separate physical F2H SDRAM port from MISTER_FB's own vbuf scan-out port and ram2's audio/palette port -- no Avalon-level contention"
DDR-005: "A shared read-port mux must select on a REQ+WAIT-spanning signal (link_ring's new rd_active), not a requester's own rd_en, or it silently hands a pending response's byte-half-select to the wrong (idle) client -- found via a link-pushed dst_addr reading back as opcode's own value"
BLIT-004: "SOLID_FILL's color field is packed R | (G<<8) | (B<<16) -- R in the LOW byte -- matching FB_FORMAT's RGB memory order, not the 0xRRGGBB hex-literal reading"
BLIT-005: "BLIT-001's milestone met with 2 ops (SOLID_FILL, BLIT_COPY) -- the Menu-static noise-fill op dropped after abandoning the menu-integration concept, not deferred"
BLIT-006: "BLIT_COPY_KEY (opcode 3): colorkey transparency for sprite compositing -- skips source pixels matching a caller-chosen key, same blit_copy.sv engine as plain BLIT_COPY"
BLIT-007: "BLIT_BLEND (opcode 7): straight-alpha source-over with 8-bit alpha modulation in word 5, bit-exact to SDL 2.32.10's generic truncating /255 blend path"
LINK-012: "Protocol 1.1 (0x00010001) adds capability bit 7 for BLIT_BLEND; minor revisions are additive; supersedes LINK-011's fixed version/mask values only"
LINK-002: "64-slot ring buffer at phys 0x30020000 (header: write_ptr +0, read_ptr +8) / 0x30021000 (slots), reusing CMDQ-001's 32-byte slot format"
LINK-003: "link_ring.sv polls write_ptr only while CMDQ is idle (cmd_ready), fetches via 8 sequential reads, dispatches to CMDQ, writes back read_ptr"
LINK-004: "lib/noodles_link.{h,c} is the real host-side API (open/close, noodles_rgb, push_command/solid_fill/blit_copy) -- fire-and-forget, no completion signal by deliberate choice"
LINK-005: "rtl/link_fence.sv publishes a monotonic done-count to DRAM (HEADER_ADDR+12) on blit_done||copy_done; noodles_link_submitted_count()/done_count() let the host know when a specific command actually finished"
LINK-006: "noodles_link_upload() writes host asset data straight into DDR3 via mmap+memcpy at a caller-given address, bypassing the ring buffer and every BLIT engine entirely -- per DDR-002's direct physical addressing"
LINK-007: "Pipelining commands (pushing several without fence-waiting each one) is safe -- CMDQ dispatches the ring strictly FIFO -- but noodles_present_and_wait() must compare done_count() against PRESENT's own absolute fence position (done_baseline + submitted), not a pre-push delta, or it reports the flip done early once other commands are in flight ahead of it"
OUT-005: "OUT-004's single-fresh-vblank-edge PRESENT margin is not reliably sufficient once per-frame draw work spans more than ~1-2 vsync periods -- ascal's own internal buffering and avl_clk-domain fb_base latch (separate from FB_VBL) can desync from our flip, causing intermittent visible ghosting; root cause identified, no fix implemented yet"
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
  status: SUPERSEDED
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
  status: SUPERSEDED
  decided_date: 2026-09-21
  decision: "The OSD's 'Draw Test' button (Noodles.sv, rtl/cmd_test_trigger.sv) fires exactly one fixed SOLID_FILL command through CMDQ on each press, encoded per CMDQ-001's slot layout: opcode=1, dst_addr=0x30000000, dst_pitch=256, width=64, height=64, color=0x00FF00FF (magenta), reserved words zero. cmd_test_trigger is a generic one-shot 'present this fixed command to CMDQ until accepted' module, not specific to this command."
  consequence: "This is explicitly a stand-in for LINK-001's still-unbuilt ring buffer, not a step toward it architecturally -- CMDQ has no other way to receive a command today. Every field is hardcoded in Noodles.sv; changing what gets drawn means editing and resynthesizing the core, not sending a different command. sim/cmd_trigger_dut.sv and sim/tb_cmd_trigger.cpp verify this exact command end to end (CMDQ decode through BLIT's pixel writes) and must be kept identical to Noodles.sv's DRAW_TEST_COMMAND if either changes."

- record_id: CMDQ-003
  kind: ARCHITECTURE
  component_id: CMDQ
  title: "OSD test scaffolding retired -- CMDQ-002's rtl/cmd_test_trigger.sv, ddram_marker_test.sv, and their OSD buttons removed"
  status: DECIDED
  decided_date: 2026-09-22
  supersedes: "CMDQ-002"
  decision: "Marker Test (status[1]), Draw Test (status[2], CMDQ-002), and Blit Copy Test (status[3]) -- the three OSD buttons that fed CMDQ hardcoded commands or wrote a fixed diagnostic word directly -- are removed, along with rtl/cmd_test_trigger.sv, rtl/ddram_marker_test.sv, tools/ddram_marker_check.c, tools/ddram_marker_scan.c, and the OSD CONF_STR entries. They existed as a known-good fallback while LINK-001's ring buffer was still being brought up and hardware-debugged (DDR-002 through DDR-005's history in core-log.md); LINK-004/LINK-005 proved the real host-driven path correct end to end on real hardware, including completion signaling, removing the reason to keep a second, hardcoded command path alive. CMDQ's command front end is back down to a single real client (link_ring, no mux); the write-port mux dropped from 5-way to 4-way (blit_copy, link_ring, blit, link_fence). sim/cmd_trigger_dut.sv+tb_cmd_trigger.cpp were deleted outright (sim/tb_solid_fill.cpp already covers CMDQ+BLIT without a trigger wrapper); sim/marker_test_dut.sv+tb_marker_test.cpp were deleted outright (nothing else tested ddram_marker_test specifically, and it no longer exists to test). sim/cmd_copy_trigger_dut.sv+tb_cmd_copy_trigger.cpp were NOT simply deleted -- they were the only coverage for CMDQ+blit_copy+ddram_adapter's read AND write sides together, a real, still-live path (BLIT_COPY remains a real opcode LINK can dispatch); replaced with sim/engine_copy_dut.sv+tb_blit_copy.cpp, same coverage, cmd_valid/cmd_data driven directly by the testbench instead of through cmd_test_trigger."
  consequence: "OUT-003's surface parameters (64x64, 32bpp, base 0x30000000, stride 256, FB_EN gated on a fill having completed) remain accurate and unchanged -- only its prose's 'Draw Test' framing is now historical, since FB_EN's gate was already keyed on blit_done generically (any command source), not on that specific button, before this record. CMDQ-002 is SUPERSEDED by this record: the module and command it named no longer exist in the build. Anyone needing a quick, no-host, single-button way to fire a test command no longer has one -- link-push (LINK-004) is now the only way to exercise CMDQ, which is by design (it is the real path), not an accidental loss of a debugging convenience nothing currently needs."

- record_id: OUT-003
  kind: INTERFACE
  component_id: OUT
  title: "Draw Test's MISTER_FB surface and FB_EN gating"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "FB_FORMAT/FB_WIDTH/FB_HEIGHT/FB_BASE/FB_STRIDE are hardcoded in Noodles.sv to match CMDQ-002's command exactly: 64x64, 32bpp (FB_FORMAT[2:0]=3'b110), base 0x30000000, stride 256. FB_EN and FB_FORCE_BLANK are gated on a 'draw ever completed' latch (set the first time the Draw Test command's BLIT fill finishes) rather than tied on unconditionally, so the display stays blank until a real fill has happened at least once instead of showing whatever was previously in memory at that address."
  consequence: "The surface parameters here are not derived from CMDQ-002's command at elaboration time -- they are separately hardcoded and must be kept in sync by hand; a future record should make BLIT/CMDQ and OUT share one source of truth for surface geometry before this becomes a real API. CE_PIXEL, previously tied to constant 0, was also changed to a real toggling signal as part of this record's bring-up -- the framework's OSD/mixer chain needs it regardless of whether the picture comes from MISTER_FB or a core's own raster output; see the comment in Noodles.sv for what was checked."

- record_id: OUT-004
  kind: INTERFACE
  component_id: OUT
  title: "Double buffering: PRESENT (opcode 4), vblank-synced front/back flip between two fixed surfaces"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "Until this record, every draw command wrote directly into the SAME surface MISTER_FB was scanning out live -- fine for one-shot test fills, but any real-time animated content (the sprite-compositing target set in BLIT-006) would tear visibly. Adds a second fixed 64x64/32bpp surface (NOODLES_BUFFER_B_ADDR=0x30008000, 32KB past BUFFER_A=0x30000000, clear of its 16KB footprint and of the 0x30010000+ region several host tools use as scratch) and a new module, rtl/present.sv, that owns a single front_sel register selecting which of the two FB_BASE currently points at. PRESENT (opcode 4) is CMDQ's third dispatch target (cmdq.sv's active_copy became a 3-way active_engine selector: blit/copy/present) -- on dispatch it waits for a FRESH rising edge of FB_VBL (the framework's vblank level signal), not just 'currently in blank', before flipping front_sel, so a flip request arriving mid-blank still waits for the NEXT blanking interval rather than risking a change too close to when active video resumes; this is deliberately conservative (worst case ~2 frames' latency) in exchange for not depending on undocumented assumptions about ascal's own prefetch timing. FB_VBL needs no cross-clock synchronizer despite nominally being a clk_vid-domain signal: Noodles.sv ties CLK_VIDEO to clk_sys, and CLK_VIDEO is literally what sys_top.v uses to generate FB_VBL in the first place, so they're already the same clock domain. present_done_ever (renamed from draw_done_ever) now gates FB_EN/FB_FORCE_BLANK on the FIRST PRESENT completing, not the first draw -- a completed draw only changes the back buffer; nothing should appear until that buffer has actually been presented. Host API: noodles_link_back_buffer() (which fixed address to draw into right now) and noodles_present_and_wait() (push PRESENT, block until LINK-005's fence confirms the flip, update the handle's tracking) -- the host computes which buffer is back purely from its own count of CONFIRMED presents, no new DRAM-published state was needed beyond the existing fence."
  consequence: "Any future draw call must target noodles_link_back_buffer()'s current return value, not a hardcoded surface address -- code written against LINK-004/BLIT-006's examples (which all drew directly at NOODLES_BUFFER_A_ADDR) needs updating to the double-buffered pattern: draw at back_buffer(), then present_and_wait(), then re-read back_buffer() for the next frame. Calling noodles_present_and_wait() blocks for up to roughly one frame (vblank-synced) -- fine for the host's own frame pacing, but a host wanting to prepare next-frame draws during that wait can still push them into the ring (LINK-002's 64-slot depth), they just won't start executing until the flip completes, since CMDQ reports not-ready for the whole wait. Verified in simulation (sim/tb_present.cpp: reset state, a fresh-edge flip, the specific 'started mid-blank must wait for a NEW edge' case, and repeated correct toggling) and on real hardware (tools/present_demo.c cycles 6 solid colors through alternating buffers; buffer address alternates correctly every flip and the sequence displayed cleanly with no visible tearing, confirmed visually by the user across two separate runs)."

- record_id: SURF-004
  kind: INTERFACE
  component_id: SURF
  title: "Physical 0x20000000 itself is unsafe -- MiSTer's system video scaler owns it"
  status: DECIDED
  decided_date: 2026-09-21
  decision: "Physical byte address 0x20000000 -- the very start of SURF-003's [0x20000000,0x40000000) FPGA-reserved window, and this project's first choice of surface/marker address -- is not actually free for a core to use. It is MiSTer's own system video scaler's RAM base. This is not inferred: it is a direct, hardware-learned lesson from the aquasock/MiSTer-Raster project (a much more mature sibling MiSTer core, same author), whose commit 53f322905 ('Move H262 frame store out of scaler DDR region') states plainly: 'MiSTer's system video scaler uses physical DDR byte address 0x20000000 as its RAM base.' That project originally placed its own DDR3 picture store at word address 0x04000000 (= physical 0x20000000, the same value this project's SURF-003 treated as safe) and moved it to word address 0x06000000 (= physical 0x30000000) after hitting a real collision. Every subsequent hardware-accepted release of that project (through v0.9.5, per its changelog) has used 0x30000000+ without incident."
  consequence: "This project's marker test, Draw Test command, and FB_BASE were all originally pointed at 0x20000000 and have been moved to 0x30000000 as a result, before ever enabling FB_EN or displaying anything from that address (SURF-003's DECIDED status and its 'Core's fb' sub-window language are not wrong about Linux's own reservation, just incomplete about a second, FPGA-side consumer within it -- treat SURF-003 plus this record together, not SURF-003 alone, when picking an address). This is also a standing reminder to consult aquasock/MiSTer-Raster before re-deriving platform facts this project may already have hard-won answers for (recorded separately in this session's persistent memory, not in this file)."

- record_id: SURF-005
  kind: INTERFACE
  component_id: SURF
  title: "Surfaces sized up from 64x64 bring-up to 640x480 (StarCraft/OpenBW-scale); double-buffer addresses moved to 2MB-aligned slots"
  status: SUPERSEDED
  decided_date: 2026-09-22
  decision: "The 64x64 surface was always a bring-up size, chosen to keep early hardware debugging simple, not a real target. Sized up to 640x480 (exactly 4:3, matching VIDEO_ARX/VIDEO_ARY's existing setting) -- large enough to be a plausible target for the kind of sprite-based game (Petz/Dogz-style, StarCraft/OpenBW-style) this engine's rendering capability is being built toward, per BLIT-006 and OUT-004. Each 640x480x4B buffer is ~1.17MB, far larger than the old 64x64 surface's 16KB, so OUT-004's tight 32KB buffer spacing no longer fits -- BUFFER_A/BUFFER_B moved to their own 2MB-aligned slots (0x31000000/0x31200000), comfortably clear of each other and of LINK-002's ring (a few KB at 0x30020000+), still well inside SURF-003's confirmed-safe [0x20000000,0x40000000) window and clear of SURF-004's 0x20000000 collision. Host-side scratch regions used by demo tools that need an off-screen source (blit_copy_push.c, blit_copy_key_push.c, bench.c) moved to their own 2MB slot (0x31400000) for the same reason -- the old 0x30010000 scratch address would now fall inside the ring header's neighborhood once a full-size source region is needed. lib/noodles_link.h's NOODLES_BUFFER_WIDTH/HEIGHT/PITCH/A_ADDR/B_ADDR constants updated to match; every tool that drew directly into a hardcoded single-buffer address was updated to use noodles_link_back_buffer() + noodles_present_and_wait() instead, since OUT-004 already made that the correct pattern and these tools hadn't caught up yet."
  consequence: "A full-surface SOLID_FILL now costs ~15ms (640*480 pixels at BLIT-001/bench's measured ~1 cycle/pixel, vs ~205us at 64x64) and a full-surface BLIT_COPY ~126ms (~8.2 cycles/pixel) -- still comfortably within a single vsync-paced frame, but tools polling the completion fence needed longer timeouts than the old 64x64-era 200ms (bumped to 2s in blit_copy_push.c/blit_copy_key_push.c). The write-mux/read-mux/DDRAM adapter designs are unaffected -- nothing here is a new architecture concern, only larger addresses and more pixels per command. Verified on real hardware: present_demo.c's color cycle and blit_copy_key_push.c's sprite composite both confirmed visually correct at the new resolution and buffer addresses (0x31000000/0x31200000 observed alternating correctly in present_demo.c's own output)."

- record_id: SURF-006
  kind: INTERFACE
  component_id: SURF
  title: "800x600 framebuffer geometry in the existing two DDR3 slots"
  status: DECIDED
  decided_date: 2026-09-23
  supersedes: "SURF-005"
  decision: "The standard render framebuffer is 800x600, 32 bits per pixel, with a 3200-byte row pitch and unchanged RGB byte order. Buffer A remains at physical DDR3 byte address 0x31000000 and buffer B at 0x31200000; each occupies 1920000 bytes within its reserved 2MiB slot. The source image remains 4:3 and the MiSTer scaler selects/scales to the independently configured HDMI output mode. The GPU clock stays 100MHz. The core FB_WIDTH/FB_HEIGHT/FB_STRIDE and host NOODLES_BUFFER_WIDTH/HEIGHT/PITCH must agree."
  consequence: "Host applications must be rebuilt for this geometry and paired with the matching core because the current interface has no runtime geometry discovery. Command layouts, buffer selection, PRESENT retirement, production DDR3 sprite routing and scratch base 0x31400000 are unchanged. This supersedes SURF-005's geometry, not the historical 640x480 image's qualification; acceptance of a new bitstream is recorded separately in core-log.md."

- record_id: BLIT-003
  kind: INTERFACE
  component_id: BLIT
  title: "BLIT_COPY command semantics"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "Opcode 2 (BLIT_COPY), the second of BLIT-001's three milestone ops, copies a width x height rectangle from a source surface to a destination surface with no scaling, blending or format conversion, 4 bytes/pixel like SOLID_FILL. It reuses CMDQ-001's existing 32-byte slot without changing the layout: dst_addr/dst_pitch/width/height keep their SOLID_FILL positions (words 1-4), color (word 5) is unused for this opcode, and the two words CMDQ-001 called 'reserved, must be zero' become src_addr (word 6) and src_pitch (word 7) instead -- reserved words are zero only for opcodes that do not define them, not universally; CMDQ-001's slot positions are unchanged, only which opcodes assign meaning to which words grows. Implemented as a separate module, rtl/blit_copy.sv, dispatched by CMDQ alongside rtl/blit.sv (SOLID_FILL) rather than merging the two engines -- keeps the already-proven fill FSM untouched."
  consequence: "BLIT_COPY needs a read port for the first time -- see DDR-003. Per-pixel it issues a read at src_addr+row*src_pitch+col*4, waits for that one word, then writes it to dst_addr+row*dst_pitch+col*4 before advancing; exactly one outstanding read at a time, never a second read issued before the first is consumed. Source and destination rectangles are not checked for overlap; an overlapping copy's result is whatever row-major read-then-write order produces, not a defined semantic."

- record_id: BLIT-004
  kind: CONVENTION
  component_id: BLIT
  title: "SOLID_FILL's color field byte order matches FB_FORMAT's RGB memory layout -- R is the low byte, not the high byte"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "BLIT-002 already establishes that `color` is written verbatim as raw pixel bytes with no format conversion. This record pins down what byte order those raw bytes need to be in to actually display as the intended color, given this project's FB_FORMAT=5'b00110 (32bpp, bit[4]=0=RGB per emu_ports.vh). Per emu_ports.vh's own [4]=0=RGB/1=BGR comment, the pixel's bytes in ascending memory-address order are R, G, B, (unused). Since DDRAM_DIN/DDRAM_DOUT and every uint32_t on the ARM host side are little-endian, a 32-bit `color` value's LOWEST byte (bits [7:0]) lands at the LOWEST memory address -- i.e. bits[7:0]=R, bits[15:8]=G, bits[23:16]=B, bits[31:24]=unused. This is the reverse of the 'obvious' 0x00RRGGBB hex-literal reading most people reach for first. Found on real hardware: tools/link_push.c's SOLID_FILL used color=0x0000FFFF intending cyan (R=0,G=255,B=255) and instead displayed yellow (R=255,G=255,B=0) -- exactly what 0x0000FFFF produces under this byte order (low byte 0xFF=R, next byte 0xFF=G, next byte 0x00=B). The OSD 'Draw Test' button's magenta (0x00FF00FF, BLIT-001's original test command) never exposed this because R=0xFF,G=0x00,B=0xFF is palindromic under an R/B swap -- it looks correct under either byte-order assumption, which is why the bug went unnoticed until a non-palindromic color (cyan) was tried."
  consequence: "Any host-side code choosing a `color` value must construct it as `R | (G<<8) | (B<<16)`, not the naive `(R<<16) | (G<<8) | B` a 0xRRGGBB hex literal implies. tools/link_push.c's cyan constant is corrected to 0x00FFFF00 accordingly. This only applies while FB_FORMAT keeps bit[4]=0 (RGB) and bit[2:0]=3'b110 (32bpp) as OUT-002 set them; if a future record changes either, this byte-order mapping must be re-derived, not assumed to carry over. No record yet defines a host-side color-packing helper -- until one exists, every caller must independently apply this byte order or repeat this same mistake."

- record_id: BLIT-005
  kind: ARCHITECTURE
  component_id: BLIT
  title: "BLIT-001's milestone is met with two ops -- the third (Menu-static noise-fill) is dropped, not deferred"
  status: DECIDED
  decided_date: 2026-09-22
  supersedes: "BLIT-001"
  decision: "The project has abandoned the Menu-integration concept this repository originally started from (a pet character composited over the Menu core's own static via a Linux-framebuffer overlay -- see CORE-001's consequence and the now-removed src/spike_fb.c). MiSTer-Noodles is a standalone core with no relationship to the Menu core's video or the Linux framebuffer path. BLIT-001's third milestone op -- noise/static-fill 'ported from the same generator logic as the Menu core's static' -- was scoped specifically to prove hardware could beat a measured software bottleneck from THAT abandoned concept (redrawing Menu's static in the Linux framebuffer at 1080p measured 12fps on the Cortex-A9, per the old README). With the menu-integration goal gone, that bottleneck no longer describes anything this project does, and porting Menu's specific static algorithm (its exact LFSR/cosine-table bit-twiddling) buys nothing this project needs. BLIT-001's milestone is therefore considered met with its first two ops -- SOLID_FILL (BLIT-002) and BLIT_COPY (BLIT-003) -- both proven end to end on real hardware over the real LINK path (LINK-004/LINK-005), not just simulation or the retired OSD buttons (CMDQ-003)."
  consequence: "No third BLIT op exists or is planned as a direct continuation of BLIT-001. A future procedural-fill op (e.g. a simple LFSR-based noise pattern, for demonstrating 'hardware generates content, not just copies it') is not ruled out, but would need its own record scoped to an actual current need, not inherited scope from the abandoned Menu-integration concept -- Menu-algorithm fidelity specifically is no longer a requirement for anything. src/spike_fb.c, src/fbterm_toggle.c, docs/mister-framebuffer.md, install/user-startup.sh.example, scripts/stage.sh, and scripts/hw-test.sh -- all built around that abandoned Linux-framebuffer-overlay approach -- are removed from the repository, not just architecturally superseded as CORE-001/OUT-001 already noted; README.md is rewritten to describe the actual current project."

- record_id: BLIT-006
  kind: INTERFACE
  component_id: BLIT
  title: "BLIT_COPY_KEY (opcode 3): colorkey transparency, for sprite compositing"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "The user's actual target for this engine's rendering capability, given directly (Dogz, the mid-90s P.F. Magic virtual pet game): a sprite character animated and composited over a background, built to be easy to port for someone coming from SDL. Multi-frame animation needs no new hardware -- the host just issues a new BLIT_COPY-family command with a different source frame each tick, which LINK already supports. The missing piece was transparency: plain BLIT_COPY (BLIT-003) is strictly opaque, so a sprite carries a solid rectangle around it. BLIT_COPY_KEY adds colorkey transparency (SDL_SetColorKey's model, not full alpha blending -- cheaper, and what sprite games of that era actually used): any source pixel exactly equal to a caller-chosen colorkey value is skipped, leaving the destination pixel underneath untouched, instead of being overwritten. Implemented as opcode 3 dispatched to the SAME rtl/blit_copy.sv engine as plain BLIT_COPY (opcode 2) -- not a separate module -- since the two are structurally identical (read source pixel, conditionally write destination pixel); blit_copy.sv gained key_enable/key_value inputs that CMDQ sets based on which opcode it decoded (key_enable=0 for opcode 2, key_enable=1 with key_value=the command's color field -- word 5, unused by plain BLIT_COPY -- for opcode 3). A keyed-out pixel is still READ (every source pixel must be inspected to check it against the key) but not WRITTEN. Host API: noodles_push_blit_copy_key(dst, src, w, h, colorkey), colorkey packed via noodles_rgb per BLIT-004's byte order."
  consequence: "Sprite compositing -- draw a character over an existing background without a bounding box -- is now possible over the real LINK path, using only fills and colorkeyed copies the host already knows how to push. True alpha blending (per-pixel blend, not just skip-or-copy) is explicitly not implemented and would be a separately-scoped, more expensive feature (needs a destination read plus a per-channel multiply, not just a compare) if ever needed -- colorkey is deliberately the cheaper, historically-accurate mechanism for this milestone. Verified two ways: tb_blit_copy.cpp's second test (a 4x4 checkerboard, half key-colored) checks bit-exact behavior in simulation -- correct read count (16, every pixel inspected), correct write count (8, keyed pixels skipped), and correct final destination content. On real hardware, tools/blit_copy_key_push.c built a minimal sprite purely from SOLID_FILLs (a colorkey-colored region with a smaller solid square filled inside it) and BLIT_COPY_KEY'd it onto a differently-colored background; the visible surface showed the background color with a clean sprite square on it and no trace of the colorkey border, confirmed visually."

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

- record_id: DDR-006
  kind: ARCHITECTURE
  component_id: DDR
  title: "DDRAM requests are captured in independent registered queues before physical-bus arbitration"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "rtl/ddram_adapter.sv captures scalar and 64-bit write requests in a registered write queue and read requests in a registered read queue. A registered response-metadata queue preserves read order, 32-bit half selection, and 64-bit response type. The physical DDRAM port issues one captured transaction at a time, prioritizing a queued read when response capacity is available and otherwise issuing a queued write. Client ready signals describe queue capacity, not DDRAM_BUSY or the current physical grant, so a client request remains a valid handshake independent of physical-bus backpressure."
  consequence: "New DDRAM clients must use the queue handshake and must not infer physical acceptance from DDRAM_BUSY. CMDQ command retirement waits for both the engine completion pulse and the adapter's idle signal, which includes queued and outstanding transactions. Replacing this with a combinational phase scheduler or grant-dependent ready logic is not permitted without a new interface decision and mixed-traffic simulation coverage."

- record_id: DDR-007
  kind: ARCHITECTURE
  component_id: DDR
  title: "Explicit-length burst reads for the 64-bit port; read/write fairness to prevent burst-induced write starvation"
  status: DECIDED
  decided_date: 2026-09-22
  supersedes: "DDR-003"
  decision: "DDR-003's read port only ever issued burstcnt=1 (single-word) Avalon commands, even for blit_copy64/sprite_batch's sequentially-addressed pixel-pair reads -- BLIT_COPY's actual hot path -- paying full DDR3 row-activate/CAS overhead per word instead of amortizing it across a burst. The fix adds an explicit-length descriptor to the adapter's 64-bit read port (a new rd64_len input, 1-DEPTH words) rather than inferring a burst from already-queued contiguous requests after the fact: the latter was tried first and found architecturally broken, because the adapter's combinational issue logic drains a newly-queued single-word request faster than a one-request-per-cycle producer can ever let a multi-entry run build up to discover. blit_copy64 now computes and declares its own desired burst length up front each request -- bounded by its FIFO's free capacity (a new reserved_count register, distinct from the existing response-tracking pair_count) and by the pairs remaining in the current source row, so a burst never crosses a row-pitch boundary -- and issues ONE rd64_en acceptance for that whole length; the adapter dequeues one descriptor at a time and drives ddram_burstcnt directly from its declared length, reserving that many response-queue slots atomically. This mirrors the proven descriptor-queue pattern from aquasock/MiSTer-Raster's mpeg2_h262_ddram_arbiter.sv, already cited approvingly by DDR-003. A second, independent bug surfaced once bursting was working: blit_copy64's continuous FIFO refilling keeps the adapter's read queue non-empty far more of the time than the old one-word-at-a-time behavior did, and the adapter's original write arbitration (`write_issue = wr_count!=0 && !read_issue`) gave reads absolute, unconditional priority whenever any read was queued -- under sustained burst traffic this starves writes indefinitely (a queued write sits in wr_addr_q/wr_data_q forever, never reaching DDRAM_WE/DDRAM_DIN). Fixed with a free-running rr toggle: read_issue and write_issue only both consult rr when both want the bus this cycle, alternating which side wins, guaranteeing every queued write is issued within a bounded number of cycles regardless of how continuously reads are requested. A third bug (not adapter-related) was blit_copy64's own completion check, which used `pairs_issued==total_pairs && pair_count==0` -- valid only when accepted requests complete almost immediately, which stopped being true once a burst's pairs_issued increments the moment it is ACCEPTED, potentially many cycles before its data actually arrives (especially now that fairness can delay a queued read's issuance behind a write). Fixed by gating completion on pairs_done (incremented once per pair actually WRITTEN) instead. Verified in Verilator simulation (sim/tb_blit_copy64.cpp, a new burst-aware behavioral Avalon memory model that streams N sequential words back after a single accepted command, honoring DDRAM_BURSTCNT): both a plain multi-row copy and a BLIT_COPY_KEY-style checkerboard run pass pixel-exact, and max observed burstcnt was 4 (row width 8 => 4 pairs/row), confirming real multi-word bursts form and are consumed correctly. Full Quartus compile succeeded with 0 errors and positive worst-case setup slack (+0.508ns). On hardware, the 64-sprite stress-demo workload improved from a consistent ~15fps baseline to a consistent ~18.7-19fps average across three runs (18.7/18.7/19.0), visually confirmed smoother with no flicker or stutter -- a real, repeatable throughput gain, though the present-probe-dump retirement-stall pattern (retire_wait_cyc cycling through the same ~83ms/167ms/250ms values, same missed_boundaries pattern) was unchanged, meaning the underlying periodic ascal retirement stall investigated earlier this session is not caused by blit_copy64's read burst inefficiency and remains a separate, still-open question."
  consequence: "The scalar (32-bit) read/write ports and blit_copy.sv (the non-hot-path CMDQ opcode 2/3 engine) are unaffected -- they always declare length 1, exercising the same code paths as before this change, and their existing sim coverage (solid_fill, ddram_adapter, blit_copy, link_ring, link_fence, present, cmdq_batch) passed unchanged. Any future producer wanting a multi-word burst must declare its length explicitly up front via the same len-field pattern (rd64_len for the 64-bit port) -- opportunistic post-hoc contiguity detection over an already-queued run is a proven dead end for a combinationally-draining queue like this adapter's, not a viable alternative approach to revisit. The read/write fairness toggle (rr) is now load-bearing for any workload that keeps queued reads and writes both non-empty for extended periods -- removing it, or reintroducing an unconditional read-priority scheme, reopens the write-starvation hazard this record fixes. The FPS ceiling (present-probe-dump's retirement stall pattern) remains unexplained by this fix and needs its own fresh diagnostic thread if revisited; do not assume DDRAM read-burst inefficiency is the cause of that specific symptom going forward -- this record's own hardware measurement rules it out."

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

- record_id: LINK-004
  kind: INTERFACE
  component_id: LINK
  title: "Host-side library API (lib/noodles_link.{h,c}), fire-and-forget, no completion signal"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "lib/noodles_link.h/.c is the real ARM/Linux-side API for LINK-001, replacing hand-rolled /dev/mem mmap code that every caller (starting with tools/link_push.c) previously duplicated. Surface: noodles_link_open/close manage the mmap of LINK-002's header+slot region; noodles_rgb packs an R,G,B triple per BLIT-004's byte order; noodles_push_command writes a raw 8-word slot and publishes write_ptr; noodles_push_solid_fill and noodles_push_blit_copy are typed wrappers over it for CMDQ-001's two current opcodes. noodles_link_t tracks write_ptr locally after syncing once at open() (only the host ever writes it, so no need to re-read DRAM every push), but always reads read_ptr fresh from DRAM (the FPGA owns it) to check ring fullness. Deliberately no completion signal: a successful push means the command was written into the ring and published, not that the FPGA has started or finished executing it -- callers get exactly the fire-and-forget semantics LINK-003's serial CMDQ already implies today, nothing stronger. tools/link_push.c was refactored onto this library (not left duplicating the old inline code) and reverified on real hardware: a library-pushed SOLID_FILL lands the correct color at the correct address, identically to the pre-library version."
  consequence: "Any caller needing to know when a specific command has actually finished executing (before reading back a surface, or before reusing a BLIT_COPY's source region) has no way to do that today -- this was a deliberate scope decision, not an oversight, made after weighing an RTL completion-counter addition (CMDQ already knows engine_done; the gap is that nothing publishes it to DRAM) against shipping the ARM-side library alone. The RTL option was deferred: no current feature needs it, and it would mean touching link_ring.sv's FSM again immediately after DDR-005's hardware debugging cycle, with its own new sim testbench and hardware verification round trip. If a future milestone needs readback or safe source-reuse, that is the concrete trigger to revisit this and add a fence/counter field to LINK-002's header -- not before."

- record_id: LINK-005
  kind: INTERFACE
  component_id: LINK
  title: "Completion fence: rtl/link_fence.sv publishes a done-count to DRAM; noodles_link_submitted_count/done_count expose it"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "Adds the completion signal LINK-004 deliberately deferred, once BLIT-001's third op and readback-style features made it worth building. A new DRAM field at HEADER_ADDR+12 (word index 3 of the header, sharing the same 8-byte DDRAM word as read_ptr's upper half -- fine for writes, which are never subject to the read-response byte-half-select hazard DDR-005 found) holds a monotonic uint32 count of commands that have ACTUALLY finished executing. rtl/link_fence.sv (new module, not folded into link_ring.sv's own FSM) owns it: it watches Noodles.sv's `blit_done || copy_done` (CMDQ's own completion signals, already exposed at the top level -- no changes needed to cmdq.sv, blit.sv, blit_copy.sv, or link_ring.sv), increments an internal free-running counter on every pulse, and republishes it to DRAM whenever the published value falls behind, converging even under back-to-back completions. It is CMDQ's fifth write-mux client (Noodles.sv), given the LOWEST priority since its writes are never time-critical and the engine that just triggered it has always already stopped writing by the time it wants a turn. On the host side, noodles_link_t gained a `submitted` field (count of pushes made through this handle since open(), exposed via noodles_link_submitted_count()) and noodles_link_done_count() reads the fence directly. A command is done once done_count() >= the submitted_count() value observed right after that command's push returned."
  consequence: "Like write_ptr/read_ptr, DRAM isn't cleared by an FPGA reset, so link_fence publishes an initial 0 before ever reflecting a real completion -- implemented as an `initialized` flag folded into its own pending-write condition, deliberately NOT a separate INIT state, because a separate state whose entry is forced by `reset` (as link_ring's own INIT_WPTR originally was) would combinationally assert wr_en while reset is still asserted, since the write mux and ddram_adapter downstream have no reset input of their own to gate against -- caught by tb_link_fence.cpp before ever reaching hardware, not found on real hardware this time. noodles_link_submitted_count() is per-handle, not an absolute cross-session count -- only meaningful when the handle has been open since a fresh core load, same lifetime assumption as the fence's own INIT-to-0 behavior. Verified via make sim (rtl/link_fence.sv's own testbench: INIT-to-0, single-pulse, spaced-out sequence, and back-to-back-pulse convergence, all under intermittent write backpressure) and on real hardware: a link-pushed SOLID_FILL's fence count is observed to catch up to the submitted count within milliseconds of the push call returning."

- record_id: LINK-006
  kind: INTERFACE
  component_id: LINK
  title: "Asset upload: noodles_link_upload() writes host data directly into DDR3, bypassing the ring and every BLIT engine"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "Every demo before this one built its pixel content out of SOLID_FILL rects issued over LINK -- nothing had ever gotten real decoded image data (a photo, a sprite sheet) into a surface. DDR-002 already established DDRAM_* addresses are direct, unwindowed physical addresses, so loading an asset needs no new command, no new opcode, and no FPGA-side change at all: noodles_link_upload(link, dst_addr, data, size_bytes) mmaps dst_addr (page-aligned internally via sysconf(_SC_PAGESIZE), rounding the span up to cover an unaligned dst_addr/size_bytes) through the SAME /dev/mem fd noodles_link_open() already holds, memcpy's the caller's buffer straight in, and unmaps. dst_addr does not need to be page- or 4-byte-aligned on the caller's part; the function handles both. Once uploaded, the data is used exactly like any other BLIT_COPY/BLIT_COPY_KEY source region -- decoding an asset (e.g. parsing a BMP) is inherently host-side work, this function only owns getting the decoded bytes into DDR3."
  consequence: "This is the first LINK-family operation that touches DRAM outside the ring/fence protocol entirely -- there is no completion signal to wait for (a plain memcpy is synchronous from the host's point of view) and no CMDQ/BLIT involvement, so LINK-004/LINK-005's fence semantics do not apply to it. Proven with tools/load_bmp.c, a minimal uncompressed-24-bit-BMP-only loader (chosen over PNG/JPEG specifically because it needs zero decoding dependencies) that uploads a converted BGR->packed-RGB (BLIT-004 byte order) image to the shared 0x31400000 scratch slot (SURF-005), then BLIT_COPYs it onto the back buffer and presents -- verified end to end on real hardware: a genuine 320x240 generated test image (sky/sun/ground/house scene) uploaded and displayed centered on a black 640x480 background, confirmed visually by the user as a perfect match against the source file. A general asset pipeline (sprite sheets with frame metadata, non-BMP formats, an on-FPGA decoder) is out of scope here -- this record covers only the upload primitive and BMP as its first, simplest proof."

- record_id: LINK-007
  kind: INTERFACE
  component_id: LINK
  title: "Pipelining is safe; noodles_present_and_wait() must target its own absolute fence position, not a pre-push delta"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "Every caller before this one fence-waited each pushed command individually before pushing the next -- a real but unstated constraint, not a documented requirement. The user asked for a multi-sprite stress test (tools/stress_demo.c); fence-waiting after each of up to 64 per-frame blits capped throughput on host-side round-trip overhead (measured 10fps at count=64) rather than actual hardware throughput, since LINK-003's dispatch already processes the ring strictly FIFO -- there is no correctness reason to wait between pushes, only LINK-002's 63-outstanding-command ring capacity forces a wait, and only once the ring is actually full. Rewriting stress_demo.c to push commands back-to-back (retrying only on an actual ring-full return) exposed a real bug in noodles_present_and_wait(): it sampled done_count() once before pushing PRESENT, then returned success as soon as done_count() advanced by ANY amount. That is only correct when nothing else is in flight (true for every caller before this one) -- once other commands are pipelined ahead of PRESENT, an ordinary blit's own completion satisfies that check, so the function reports the flip done before PRESENT itself has even been dispatched, let alone completed its vblank-synced flip. Fixed by comparing done_count() against PRESENT's own absolute position in the fence's numbering: noodles_link_t gained a done_baseline field (the fence's value read at noodles_link_open() time), and the target is done_baseline + link->submitted (captured right after the PRESENT push, so it includes PRESENT's own increment) -- this converts the per-handle-relative submitted count into the same absolute space done_count() lives in, matching LINK-005's already-documented contract ('done once done_count() >= the submitted_count() value observed right after push') instead of the weaker delta check the original implementation actually used."
  consequence: "Callers may now pipeline draw commands without fence-waiting each one -- push as many as needed, letting push_command's own ring-full return (-1) be the only reason to block -- and noodles_present_and_wait() correctly waits for the ACTUAL flip regardless of what else is queued around it. Any future code that manually compares noodles_link_submitted_count() against noodles_link_done_count() (bypassing present_and_wait's internal handling) still needs its own baseline adjustment if the handle didn't open at a fresh core load with done_count()==0 -- done_baseline is a noodles_link_t-internal field, not exposed via a public accessor, so a caller doing this comparison itself must either open a fresh handle right after a core load or derive its own baseline the same way. This bug was real but latent for the whole project's history until stress_demo.c became the first caller to pipeline; verified fixed on real hardware (present's own reported success now tracks the true flip), though see OUT-005 for a SEPARATE, deeper timing issue this fix does not resolve."

- record_id: DDR-008
  kind: ARCHITECTURE
  component_id: DDR
  title: "Shared write ingress reserves queue capacity before registered slot commit"
  status: DECIDED
  decided_date: 2026-09-23
  decision: "Scalar and paired DDR3 writes enter one registered payload stage before committing into the write queue using registered one-hot slot enables. The sixteen-write admission limit includes the ingress reservation, and idle remains false until all accepted writes issue and the existing read/busy conditions clear. A pending ingress write cannot issue before queue commit. Consecutive acceptance, commit and issue can overlap at one write per cycle. When both input lanes request simultaneously, paired writes win and scalar ready is deasserted; no unaccepted scalar request is silently discarded."
  consequence: "Producer arithmetic and scalar/paired selection stop at ingress registers instead of driving wide queue entries directly. Register-to-register slot control replaces binary-tail decode at the queue write enables. First-write latency increases one cycle without increasing accepted capacity or changing ordered retirement, command/fence interfaces, read-response accounting or bridge-busy-independent payload selection."

- record_id: LINK-008
  kind: INTERFACE
  component_id: LINK
  title: "Host library retains fixed sprite-descriptor ownership until completion"
  status: DECIDED
  decided_date: 2026-09-23
  decision: "With one serialized producer/handle opened on a quiescent ring, an accepted SPRITE_BATCH owns the fixed 2KiB descriptor table until its baseline-adjusted completion fence retires. noodles_push_sprite_batch returns -1 with errno EAGAIN before any descriptor upload when that table is busy or the ring is full; invalid pointer/count returns EINVAL and upload failures publish no command. Raw opcode-5 submissions also acquire ownership, and library uploads overlapping the reserved table return EAGAIN while it is owned. Non-batch commands may still pipeline. Completion checks use modulo-2^31 arithmetic excluding front-buffer parity, with targets less than 2^30 completions away. Descriptor and slot writes are ordered before command publication."
  consequence: "Callers retry EAGAIN without needing their own per-batch wait to prevent descriptor corruption. Explicit waits remain necessary when measuring completed work or reusing other in-flight resources. Open only after prior work drains or a fresh core load, finish work before close, and do not reset the core during a handle's lifetime. Concurrent producers, abandoned in-flight work across reopen, direct-memory writes and commands that overwrite the reserved table are not protected by this host-side contract. No RTL, opcode layout or timing constraints change."

- record_id: OUT-005
  kind: INTERFACE
  component_id: OUT
  title: "OUT-004's single-vblank-edge PRESENT margin is not reliably sufficient under heavy per-frame draw load -- ascal's own buffering can desync from our flip"
  status: DECIDED
  decided_date: 2026-09-22
  decision: "Investigated after the user's stress test (tools/stress_demo.c, N sprites bouncing simultaneously) showed intermittent visible ghosting/flicker -- images from a sprite's previous position bleeding into the current frame -- that persisted even after LINK-007's real present_and_wait() bug was fixed. Threshold-tested on real hardware at count=10,30,50,64 (multiple runs each): 30 sprites (draws complete within ~1-2 vsync periods, 20fps=60/3Hz) ran clean across the samples taken; 50 and 64 sprites (draws span ~3-4 vsync periods, 15fps=60/4Hz and ~14.3fps) flickered intermittently, roughly half of repeated runs; even a single 10-sprite run (normally clean at 30fps=60/2Hz) flickered once. The intermittency (not deterministic per sprite count) ruled out a simple logic bug in rtl/present.sv, whose front_sel-flip-on-fresh-FB_VBL-edge logic was re-read and confirmed correct in isolation. Root cause identified by reading the vendored scaler IP directly (sys/ascal.vhd): ascal does NOT latch a new fb_base on our core's FB_VBL edge (the signal rtl/present.sv actually watches) -- it latches avl_o_offset0/avl_o_offset1 from o_fb_base only on the rising edge of avl_o_vs (ascal.vhd ~line 1714-1717), ascal's OWN internally-generated output vsync, synchronized into a SEPARATE Avalon memory clock domain (avl_clk) via a 2-stage synchronizer, explicitly marked <ASYNC> in the source. ascal additionally has its own internal double-buffering (o_obuf0/o_obuf1, ascal.vhd ~line 1940-1967) governing when it actually re-fetches frame data, decoupled from FB_VBL entirely. There is therefore no guaranteed timing relationship between 'rtl/present.sv flipped front_sel on a fresh FB_VBL edge' and 'ascal actually started reading pixels from the new address' -- the phase relationship between our FB_VBL and ascal's independent avl_o_vs/internal buffer state can drift, and when it drifts unfavorably, the host can start drawing the next frame into a buffer ascal has not yet finished consuming as the (logically) old front buffer, producing visible ghosting. This is exactly the uncertainty OUT-004's own decision text already flagged as accepted risk ('not depending on undocumented assumptions about ascal's own prefetch timing') -- this record confirms that risk is real and measurable, not just theoretical."
  consequence: "OUT-004's mechanism (front_sel, vblank-gated flip) is not wrong, but its margin (wait for exactly one fresh FB_VBL edge) is insufficient once per-frame draw work grows large enough to span multiple vsync periods -- which any real multi-sprite scene will do past a low sprite count on this hardware today (BLIT_COPY's DDR-003 throughput gap is the reason draw work takes as long as it does; a future throughput fix would raise the sprite count before this margin problem starts, not eliminate the underlying margin gap itself). No fix is implemented yet. Two directions were identified but not attempted: (1) empirical mitigation -- have rtl/present.sv wait for multiple fresh FB_VBL edges (not just one) before considering a flip's prior frame fully retired, trading latency for margin against ascal's drift, cheap to try but not root-cause-verified; (2) deeper study of ascal's configuration (RAMBASE/RAMSIZE, buffering/low-latency mode parameters passed to it in sys_top.v) to find an actually-guaranteed-safe relationship between FB_VBL and avl_o_vs, or a different synchronization signal this core could watch instead. Whoever picks this up next should start from ascal.vhd's o_run/o_vsv/avl_o_vs signal chain (grep'd and referenced above) rather than re-deriving it from scratch. Safe-today guidance: draw workloads that complete within roughly 1-2 vsync periods (empirically ~30 sprites at this project's 48x48 sprite size and BLIT_COPY_KEY cost) have not shown this artifact in testing; heavier workloads may, intermittently."

- record_id: OUT-006
  kind: INTERFACE
  component_id: OUT
  title: "PRESENT completion is acknowledged by ascal's framebuffer-base latch, with one post-ack retirement boundary"
  status: DECIDED
  decided_date: 2026-09-22
  supersedes: "OUT-005"
  decision: "rtl/present.sv still flips front_sel only on a fresh rising edge of FB_VBL, but it no longer treats a fixed count of FB_VBL edges as evidence that scanout accepted the new surface. sys/ascal.vhd toggles an acknowledgement in its avl_clk domain at the existing assignment of avl_o_offset0/avl_o_offset1 from o_fb_base; sys/sys_top.v synchronizes that toggle into clk_sys and exposes it to the core as FB_BASE_LATCHED. PRESENT captures the acknowledgement level when it starts, waits for the level to change after flipping front_sel, and then waits one additional fresh FB_VBL edge before pulsing done. The post-ack edge is retained because accepting the new base and retiring all outstanding output-buffer activity are distinct events until hardware proves otherwise."
  consequence: "The host-side PRESENT fence now cannot complete before the scaler has observed the requested framebuffer base, eliminating the previous fixed-delay assumption while retaining a conservative two-buffer design. FB_EN remains asserted from reset while FB_FORCE_BLANK keeps output hidden until the first PRESENT completes; this is required because ascal only latches o_fb_base while framebuffer mode is enabled. FB_BASE_LATCHED is a synchronized toggle-level indication, not a pulse; future scanout handshakes must preserve the same phase-safe cross-clock pattern. Simulation must cover acknowledgement before and after FB_VBL, arbitrary phase, and repeated toggles; hardware validation remains required to determine whether the one-edge post-ack margin is sufficient for OUT-005's ghosting workload."

- record_id: OUT-007
  kind: INTERFACE
  component_id: OUT
  title: "PRESENT waits for ascal's output-domain frame retirement acknowledgement"
  status: DECIDED
  decided_date: 2026-09-22
  supersedes: "OUT-006"
  decision: "sys/ascal.vhd exports a toggle from its output-clock process at the internal output VS boundary where buffered scanout advances to the next frame. sys/sys_top.v synchronizes that toggle into clk_sys and exposes it as FB_RETIRED. rtl/present.sv flips front_sel only on a fresh FB_VBL edge, captures the synchronized retirement level, waits for it to change, and then waits one additional fresh FB_VBL edge before pulsing done. The earlier FB_BASE_LATCHED acknowledgement remains wired for diagnosis but is not used for PRESENT completion."
  consequence: "PRESENT completion now follows ascal's output-domain frame boundary rather than the Avalon-domain base-latch event, while retaining two-buffer operation and a conservative post-ack interval. FB_RETIRED is a synchronized toggle-level indication, not a pulse. Hardware validation remains required to determine whether this output-domain boundary is late enough to prevent OUT-005 ghosting."

- record_id: OUT-008
  kind: INTERFACE
  component_id: OUT
  title: "PRESENT retirement acknowledgement waits for ascal's output read and copy pipelines to become idle"
  status: DECIDED
  decided_date: 2026-09-22
  supersedes: "OUT-007"
  decision: "sys/ascal.vhd records the output-domain frame boundary as pending and toggles FB_RETIRED only after the boundary has passed and both o_readlev and o_copylev are zero in the idle display state. This keeps the existing synchronized toggle interface and two-buffer ownership model while preventing the unconditional VS-boundary acknowledgement from claiming retirement early."
  consequence: "PRESENT no longer completes from the raw output VS boundary alone. The condition is still limited by ascal's counter semantics: because the output process resets these counters at VS, delayed Avalon responses may remain unrepresented, so hardware validation and any further instrumentation must establish whether this is sufficient."

- record_id: OUT-009
  kind: INTERFACE
  component_id: OUT
  title: "PRESENT retirement acknowledgement accounts for outstanding Avalon framebuffer bursts"
  status: DECIDED
  decided_date: 2026-09-22
  supersedes: "OUT-008"
  decision: "sys/ascal.vhd synchronizes the output-domain frame-boundary toggle into avl_clk, tracks each accepted framebuffer read until its final avl_readdatavalid beat, and toggles FB_RETIRED only after the boundary has been observed with no Avalon response outstanding."
  consequence: "The retirement handshake now covers delayed memory responses that are invisible to the output-domain read and copy counters. It remains a two-buffer design and retains the existing synchronized toggle interface; hardware validation must determine whether ascal's internal buffer transition introduces any additional ownership interval."

- record_id: OUT-010
  kind: INTERFACE
  component_id: OUT
  title: "PRESENT retirement tracks every outstanding Avalon framebuffer burst"
  status: DECIDED
  decided_date: 2026-09-22
  supersedes: "OUT-009"
  decision: "sys/ascal.vhd maintains an outstanding-read count in avl_clk, incrementing for each accepted framebuffer read and decrementing only on the final avl_readdatavalid beat, with simultaneous acceptance and completion treated as a net-zero count change. FB_RETIRED is emitted only after the synchronized output boundary and a zero outstanding-read count."
  consequence: "A first completed burst can no longer clear a shared busy bit while later bursts remain outstanding. The interface and two-buffer model are unchanged; hardware validation remains required."

- record_id: OUT-011
  kind: INTERFACE
  component_id: OUT
  title: "PRESENT retirement requires post-boundary framebuffer-base acceptance"
  status: DECIDED
  decided_date: 2026-09-22
  supersedes: "OUT-010"
  decision: "sys/ascal.vhd records the output-domain frame boundary, then requires the next synchronized Avalon-domain o_fb_base latch before FB_RETIRED can toggle. The existing outstanding-read counter must also be zero and the Avalon reader idle."
  consequence: "The retirement acknowledgement cannot complete in the phase gap where output VS has advanced but the Avalon reader still uses the prior framebuffer base. Two-buffer operation and the public FB_RETIRED toggle interface remain unchanged."

- record_id: OUT-012
  kind: INTERFACE
  component_id: OUT
  title: "Host buffer parity is published by the FPGA completion fence"
  status: DECIDED
  decided_date: 2026-09-22
  supersedes: "OUT-011"
  decision: "rtl/link_fence.sv publishes the completion count in bits 30:0 and the persistent front_sel parity in bit 31 of the existing fence word. lib/noodles_link.c masks the count and initializes each handle's back-buffer parity from the published front bit, so process restarts do not assume buffer A is front."
  consequence: "A host process can safely reopen the shared link after prior PRESENT commands without drawing into the current scanout surface solely because its local present counter restarted. The completion-count capacity is reduced to 31 bits."

- record_id: SDR-001
  kind: ARCHITECTURE
  component_id: SDR
  title: "The optional SDRAM board is FPGA-fabric-only; the HPS/Linux side has no path to it"
  status: SUPERSEDED
  decided_date: 2026-09-23
  decision: "The MiSTer SDRAM daughterboard (or onboard-soldered equivalent on some clone boards) is wired to GPIO pins that only reach FPGA fabric logic -- there is no HPS/ARM-side address path to it at all, unlike DDRAM_* (DDR component records), which is HPS-owned DDR3 shared with the FPGA over the F2H bridge. rtl/sdram.sv (vendored from MiSTer-devel/NeoGeo_MiSTer's rtl/sdram.sv) is driven entirely from a dedicated ~100MHz clk_sdram PLL domain (see rtl/pll.v's outclk_1) and its own SDRAM_* pins; nothing about it is visible to lib/noodles_link.c or any other host-side code, and it never will be without new FPGA-side bridging logic that does not exist."
  consequence: "Any data this project puts in SDRAM must be written there BY THE FPGA, not by the host -- the host can only ever write into DDR3 (as it already does today). This rules out using SDRAM for anything the host needs to update every frame (e.g. sprite_batch.sv's descriptor table, which the host uploads fresh each frame): that data structurally must stay on DDR3. SDRAM is only useful for host-write-once/FPGA-read-many data, e.g. a sprite source bitmap uploaded once at load time then read every frame thereafter by a copy engine -- the FPGA can copy such data from its one-time DDR3 upload location into SDRAM itself, after which only SDRAM is read for that data going forward. This record scopes entry 61/62's SDRAM plan down to sprite-source-bitmap reads only; the descriptor-table read path stays on DDR3 and gets its own separate improvement path (a staging-buffer bulk read, not a memory-technology change) if pursued."
- record_id: SDR-008
  kind: ARCHITECTURE
  component_id: SDR
  title: "Core and FPGA-only SDRAM share one 100MHz clock net"
  status: DECIDED
  decided_date: 2026-09-23
  supersedes: "SDR-001"
  decision: "The optional board SDRAM remains FPGA-fabric-only and physically separate from HPS-shared DDR3. The core PLL has one 100MHz zero-phase output, clk_sys, driving the GPU, DDRAM adapter, SDRAM controller, read adapter, loader, page buffer and refresh counter. The SDRAM adapter and loader use the common core reset; the controller retains its separate PLL-lock-driven initialization. Per-word reads and per-page handoff use synchronous sequencers without sdram_cdc. Framework HDMI and audio clocks are unchanged."
  consequence: "No core-to-SDRAM clock-crossing exceptions or secondary reset-domain bridge are needed. Page buffering remains necessary to feed uninterrupted SDRAM copy bursts from variable-latency DDR3 reads. Host code still cannot address board SDRAM directly; OP_LOAD_SDRAM remains the FPGA-mediated load path. Production sprite reads, descriptors and destination writes remain on DDR3; clock unification does not select the optional SDRAM sprite-source path or establish timing closure."

- record_id: LINK-009
  kind: INTERFACE
  component_id: LINK
  title: "Host SDK legacy-mode lifecycle and opaque handles"
  status: DECIDED
  decided_date: 2026-09-23
  decision: "The host SDK exposes opaque noodles_link_t handles through noodles_link_open_legacy, explicitly requiring the caller to guarantee an initialized, quiescent, matching SVGA core. Information queries report compiled-in assumptions and hardware_verified=0, not live capabilities. Cooperating producers use an exclusive nonblocking flock on /run/noodles.lock with a persistent-per-boot dirty marker from open until successful drained close. Dirty sessions require explicit external core reload before an acknowledgement flag permits reopening. APIs return 0 or -1 with errno; submissions remain nonblocking with EAGAIN. Completion tokens use the existing 31-bit fence with a less-than-2^30 distance requirement. Polling is nonblocking; waiting and draining use monotonic deadlines. Timeout or clock/sleep failure faults the handle without cancelling work. Close always releases the handle and reports failure rather than claiming completion. All calls require caller serialization."
  consequence: "The public C API replaces stack handles and caller baseline arithmetic; tools and consumers must migrate together. Raw and typed PRESENT submission block further submissions/uploads until poll/wait observes retirement and updates back-buffer tracking. SDK version 0.1.0 identifies the host package, not a hardware protocol revision. The static library, public header and pkg-config metadata are installable independently of demos. No reset detection, ready handshake, automatic recovery, multi-client scheduling or protection from noncooperating memory writers is implied; these limitations remain explicit in docs/SDK.md."

- record_id: LINK-010
  kind: INTERFACE
  component_id: LINK
  title: "Conservative validation envelope for legacy SDK submissions"
  status: DECIDED
  decided_date: 2026-09-23
  decision: "The legacy SDK admits only implemented opcode encodings with zero reserved bits/words, nonzero valid dimensions/counts, four-byte-aligned pixel addresses and pitches, sufficient row pitch and overflow-safe spans. DDR3 accesses are restricted to [0x30000000,0x40000000), excluding the control neighborhood [0x30020000,0x30022800); direct uploads wholly inside the fixed descriptor table are allowed under LINK-008 ownership. Typed sprite batches validate each descriptor; raw batches validate the command but leave manually uploaded descriptor contents to the caller. LOAD_SDRAM requires a 1024-byte-aligned board-SDRAM destination, an eight-byte-aligned DDR3 source and rounded-page backing storage within bounds."
  consequence: "This host validation policy leaves the FPGA command layouts unchanged and is stricter than raw hardware behavior for malformed or zero-size commands. The admitted address envelope is not an allocation grant, exclusive arena or sandbox; callers still own resource lifetimes, nonoverlap and scanout safety. Raw diagnostic tools remain outside the SDK policy. Surface allocation and clipping remain separate work."

- record_id: LINK-011
  kind: INTERFACE
  component_id: LINK
  title: "Live protocol identity and reset-disarming host sessions"
  status: SUPERSEDED
  decided_date: 2026-09-23
  decision: "Protocol 1.0 reserves little-endian 32-bit control words at 0x30020010 through 0x30020040. FPGA-owned words publish magic 0x4e444c53 at +0x10, protocol 0x00010000 at +0x14, opcode capability mask 0x0000007e at +0x18, width:height 800:600 at +0x1c and pitch 3200 at +0x20. Host-owned request token low/high words are +0x28/+0x2c and request sequence is +0x30; FPGA response token low/high words are +0x38/+0x3c and response sequence is +0x40. Reset disables link_ring, clears request/response sequences, initializes ring pointers and publishes magic last. A nonzero 64-bit token with claim sequence 0x434c414d is accepted only after ring initialization; exact token/sequence echo enables the ring. While active, only changed nonzero non-claim sequences carrying the claimed token are echoed. Request sequence zero disarms the session and clears the response sequence."
  consequence: "Static DDR3 contents cannot identify a live instance because DDR3 survives FPGA reload. SDK 0.2 noodles_link_open validates the fixed protocol/capabilities/geometry and requires the live claim; a reached fence is reported complete only after a subsequent challenge echo. Reset clears and disarms the response so a stale handle fails with ESTALE instead of trusting the reset fence. The ring cannot consume host commands until a verified claim and cannot be rearmed by a stale post-reset ping. Cooperative flock and the dirty marker remain separate non-security mechanisms. noodles_link_open_legacy remains an explicitly unverified API for preserved pre-protocol cores and is not accepted on a detected protocol-1.0 core. Draw opcodes, ring slots, fence encoding, framebuffer addresses and clocks are unchanged."

- record_id: BLIT-007
  kind: INTERFACE
  component_id: BLIT
  title: "BLIT_BLEND (opcode 7): straight-alpha source-over blending with per-command alpha modulation"
  status: DECIDED
  decided_date: 2026-09-23
  decision: "Opcode 7 uses BLIT_COPY's fields (dst_addr word 1, dst_pitch word 2, width word 3, height word 4, src_addr word 6, src_pitch word 7) and carries an 8-bit alpha modulation m in word 5 bits 7:0, with word 5 bits 31:8 zero. Pixels are four bytes at increasing addresses R, G, B, A, i.e. bits 7:0 R, 15:8 G, 23:16 B, 31:24 A, with A being straight (non-premultiplied) coverage. Every division below is truncating integer division, D(x) = floor(x / 255), matching SDL 2.32.10's generic SDL_COPY_BLEND path (SDL_blit_auto.c and SDL_blit_slow.c with SDL_COPY_MODULATE_ALPHA). For each pixel: a = D(srcA * m); for each colour channel c' = D(srcC * a); outC = c' + D((255 - a) * dstC); outA = a + D((255 - a) * dstA). The source and destination rectangles must not overlap. A pixel whose effective alpha a is zero leaves the destination unchanged, which the formula itself guarantees, and the engine may skip that pixel's write."
  consequence: "Blending is bit-exact against a C reference model of this formula, so SDL2 ports get SDL's own generic-path arithmetic; SDL's unmodulated BlitRGBtoRGBPixelAlpha fast path uses a >>8 approximation and may differ from it by rounding. a = 255 reproduces a straight copy including outA = 255, and m = 255 disables modulation exactly. Hosts must now initialize the A byte meaningfully for blended sources; noodles_rgb's zero high byte is fully transparent under BLIT_BLEND, while BLIT_COPY, BLIT_COPY_KEY and scanout are unaffected. The blend reads the destination, so its DDR3 traffic per pixel exceeds a copy's. Additive, modulate and multiply modes, colour modulation, blending inside SPRITE_BATCH and destination-read skipping are not part of this record."

- record_id: LINK-012
  kind: INTERFACE
  component_id: LINK
  title: "Protocol 1.1 adds the BLIT_BLEND capability"
  status: DECIDED
  decided_date: 2026-09-23
  decision: "A core implementing BLIT-007 publishes protocol 0x00010001 and opcode capability mask 0x000000fe, where bit N advertises opcode N and bit 7 is BLIT_BLEND. Every other LINK-011 control word, address, claim, challenge and disarm rule is unchanged. Minor protocol revisions are additive: a host accepting protocol major 1 requires minor at least 0, requires capability bits 1 through 6, and enables optional operations only when their capability bit is set."
  consequence: "The SDK attaches to protocol 1.0 and 1.1 cores alike and fails a blend request on a core without capability bit 7 with ENOTSUP before publishing anything. A future major version, not a minor one, is needed for any incompatible control-block change."
  supersedes: "LINK-011"

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
# DDR-005: Paired full-word SOLID_FILL writes

- status: DECIDED
- component: DDR / BLIT
- decision: "SOLID_FILL may use an aligned 64-bit DDRAM write containing two identical 32-bit pixels when the destination span permits it. The generic 32-bit half-word write remains the fallback for misaligned starts and odd tails. The physical adapter still uses burst count 1; this optimization changes write width, not transaction ordering or framebuffer ownership."
- consequence: "A full-width 640-pixel framebuffer clear can use one accepted DDRAM write for every two pixels. All existing command fields, fence completion semantics, PRESENT retirement behavior, and two-buffer constraints remain unchanged. The adapter must preserve read priority and steer full-word writes with byte-enable 0xff."
