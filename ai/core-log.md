## 1 COMMIT Unreleased 466cd9b 2026-09-21T22:32:51-07:00

#### Coming From:

Unreleased c641627

#### Purpose:

Stand up the standalone FPGA core from Template_MiSTer and implement/verify the SOLID_FILL command path in RTL simulation.

#### Outcome:

Vendored Template_MiSTer's sys/ framework and Quartus project files as Noodles.qpf/qsf/sdc/srf per CORE-001, and wrote a minimal Noodles.sv top-level that boots to a blank screen with hps_io and the PLL wired; MISTER_FB is enabled at the project level for the eventual DDRAM scan-out path but is not driven yet. `quartus_map Noodles` (Analysis & Synthesis only, Quartus Prime 17.0.2 Lite) completed with 0 errors, 56 informational warnings, confirming the vendored framework plus the new top-level elaborates and synthesizes cleanly. Implemented rtl/cmdq.sv and rtl/blit.sv against the new CMDQ-001 command-slot layout and BLIT-002 SOLID_FILL semantics, and verified them with a Verilator testbench that issues one SOLID_FILL command against a modelled byte-addressed memory under intermittent write-port backpressure, then checks every pixel address, value, and the destination rectangle's boundary; `make sim` passes. Along the way, discovered that Template_MiSTer's built-in framebuffer scan-out (MISTER_FB) only reads from the HPS-shared DDR3 (DDRAM_*), not the dedicated low-latency SDRAM_* chip, which sharpened SURF-001's generic "SDRAM" into the concrete SURF-002/OUT-002 records committed to core-reference.md this cycle.

#### Next Steps:

Wire CMDQ and BLIT into Noodles.sv for real: design and implement the DDRAM write-arbiter adapter that BLIT's generic write port needs to actually reach DDRAM_*, drive FB_EN/FB_BASE/FB_STRIDE from a real surface once BLIT can write one, and get a solid-filled rectangle onto the real HDMI output. LINK-001's actual host-to-FPGA command delivery is still unimplemented -- cmd_valid/cmd_data are only driven by the Verilator testbench today -- and needs its own interface record before hardware bring-up can use anything but a hardcoded test command. Once that's wired, run a full Quartus compile (fit and timing, not just Analysis & Synthesis) and attempt a first on-hardware solid-fill test on the QMTech MiSTer.

#### Files Modified:

- Noodles.sv
- Noodles.qpf
- Noodles.qsf
- Noodles.sdc
- Noodles.srf
- files.qip
- rtl/cmdq.sv
- rtl/blit.sv
- rtl/pll.v, rtl/pll.qip, rtl/pll/ (vendored PLL IP from Template_MiSTer, unmodified)
- sim/engine_dut.sv
- sim/tb_solid_fill.cpp
- sys/ (vendored from MiSTer-devel/Template_MiSTer, unmodified)
- Makefile
- .gitignore
- LICENSE
- clean.bat

#### Status:

- [x] Built
- [ ] Passed

---

## 2 COMMIT Unreleased ecadd93 2026-09-21T23:04:52-07:00

#### Coming From:

Unreleased 466cd9b

#### Purpose:

Wire CMDQ and BLIT into the real core against the actual DDRAM_* pins, closing the gap Next Steps left open last entry.

#### Outcome:

Implemented rtl/ddram_write_adapter.sv, which translates BLIT's generic byte-addressed write port onto DDRAM_*. Reading sys/sys_top.v showed DDRAM_* is a standard Avalon-MM master interface (its BUSY/DOUT_READY/RD/WE signals wire straight onto an f2h_sdram port's waitrequest/readdatavalid/read/write), which is now recorded as DDR-001: word-addressed 8-byte-wide words, and BLIT's existing valid-held-until-ready write port turned out to map onto Avalon-MM write/waitrequest semantics with no changes needed. The adapter steers each 4-byte pixel into the correct half of the 64-bit DDRAM word via DDRAM_BE. A new Verilator testbench (sim/tb_ddram_adapter.cpp) checks this against a behavioral Avalon-MM memory model; it initially failed on a case where two adjacent pixels share one DDRAM word, which turned out to be a bug in the test's verification logic, not the adapter -- fixed by replaying the expected per-pixel half-word writes into a shadow model instead of assuming each word is touched by only one pixel. Both Verilator testbenches pass. CMDQ, BLIT and the adapter are now instantiated in Noodles.sv and drive the real DDRAM_* pins; `quartus_fit Noodles` (full place and route, not just Analysis & Synthesis) completed with 0 errors, 16 warnings, all pre-existing and about tri-stated SDRAM_DQ/USER_IO pins from this core's own unused-pin tie-offs. cmd_valid is deliberately tied to 0 and FB_EN stays 0: this project has not yet confirmed what DDR3 address range is actually safe for the FPGA to write into given Linux owns most of the same physical memory, so no trigger was wired that could fire a write on real hardware.

#### Next Steps:

Confirm the safe DDR3 address range for FPGA-side writes (Linux's reserved memory boundary / MiSTer's own framebuffer convention, building on docs/mister-framebuffer.md's FB_ADDR research) before wiring any live trigger or enabling FB_EN with a real address -- this is a safety prerequisite, not just an engineering task. Once an address is confirmed safe, add a hardcoded/OSD-triggered SOLID_FILL test command, drive FB_EN/FB_BASE/FB_STRIDE from that surface, and attempt a first on-hardware solid-fill test on the QMTech MiSTer. Separately, LINK-001's actual host-to-FPGA ring buffer (the poll-based shared-DDR3 design discussed with the user) still has no interface record or implementation.

#### Files Modified:

- Noodles.sv
- files.qip
- rtl/ddram_write_adapter.sv
- sim/engine_ddram_dut.sv
- sim/tb_ddram_adapter.cpp
- Makefile

#### Status:

- [x] Built
- [ ] Passed

---

## 3 COMMIT Unreleased bc86ab0 2026-09-21T23:13:57-07:00

#### Coming From:

Unreleased ecadd93

#### Purpose:

Check MiSTer-devel/Main_MiSTer's own source for the safe DDR3 address window, then build the one-shot marker-word test DDR-002 already called for.

#### Outcome:

Cloned Main_MiSTer and confirmed, from its own source, that Linux physical [0x20000000,0x40000000) (512MB) is reserved for FPGA-side use -- shmem.h's fpga_mem() macro and every loader's bounds check agree -- and that the first 32MB of it, 0x20000000-0x21FFFFFF, is explicitly commented in video.cpp as a core's own "Core's fb" region, separate from Main's own wallpaper buffers at 0x22000000+. This is independently consistent with core.md's own hardware notes (~492 MiB Linux-visible out of 1GB DDR3). Committed as SURF-003. What that source can't answer is whether DDRAM_ADDR=0 on our own RTL actually corresponds to that physical address -- recorded as DDR-002, deliberately left PROPOSED rather than DECIDED. Built the executable check for it: rtl/ddram_marker_test.sv writes one fixed word to DDRAM_ADDR=0 on a single trigger edge and never repeats while the trigger is held, verified in sim/tb_marker_test.cpp (edge-only firing, exactly one write per edge). Wired it into Noodles.sv behind a new, dedicated "Marker Test" OSD option, muxed into the existing ddram_write_adapter next to BLIT's still-permanently-idle port. tools/ddram_marker_check.c is the Linux-side half: reads physical 0x20000000 via /dev/mem, reports match or mismatch. `make sim` passes all three testbenches now; `quartus_fit Noodles` completes with 0 errors, same 16 pre-existing warnings as last cycle. FB_EN and CMDQ's cmd_valid are still tied off -- this only proves the marker path, not a display path.

#### Next Steps:

Get this built and flashed, press "Marker Test" once, and run tools/ddram_marker_check.c as root on the MiSTer to actually resolve DDR-002. If it matches, promote DDR-002 to DECIDED and move on to wiring a real SOLID_FILL trigger and FB_EN/FB_BASE against the confirmed 0x20000000-0x21FFFFFF window. If it doesn't match, the mismatch itself is data -- probably means DDRAM_ADDR needs an offset or a different relationship to Linux physical addresses than assumed, to be worked out before anything else touches DDRAM_*. LINK-001's ring buffer is still unbuilt regardless of which way this lands.

#### Files Modified:

- Noodles.sv
- files.qip
- rtl/ddram_marker_test.sv
- sim/marker_test_dut.sv
- sim/tb_marker_test.cpp
- tools/ddram_marker_check.c
- Makefile
- scripts/deploy.sh

#### Status:

- [x] Built
- [ ] Passed

---

## 4 COMMIT Unreleased 2fee444 2026-09-21T23:42:30-07:00

#### Coming From:

Unreleased bc86ab0

#### Purpose:

Test bc86ab0's DDRAM marker path on real hardware, and fix what it revealed about DDR-002's address mapping.

#### Outcome:

Deployed bc86ab0 to the QMTech MiSTer over SSH and pressed "Marker Test." tools/ddram_marker_check.c reported NO MATCH at physical 0x20000000. Rather than guess, wired LED_DISK to a latched "write ever completed" flag, independent of where it landed; it lit, ruling out a stuck DDRAM_BUSY handshake and confirming the write itself was accepted by the bus. Built tools/ddram_marker_scan.c (configurable base/size) and scanned outward: nothing in the 32MB Core's-fb window, nothing in the full 513MB kernel-reserved region read from /proc/cmdline's memmap=, but a full 1GB read-only /dev/mem scan found the marker sitting at physical 0x00000000. That settled it: DDRAM_ADDR is a direct, unwindowed physical word address (word N = byte N*8) in the same address space as everything else, including live Linux memory -- not offset from the reserved window as DDR-002 had assumed based on Main_MiSTer's fpga_mem() software convention, which turned out to describe only Main's own addressing, not the hardware bridge. Fixed by retargeting ddram_marker_test to 0x20000000 directly (a parameter override in Noodles.sv); DDR-001's adapter math needed no change. Promoted DDR-002 to DECIDED with the corrected model. Redeployed, pressed "Marker Test" again, and ddram_marker_check now reports PASS -- marker found at exactly physical 0x20000000. Also fixed a stale success message in ddram_marker_check.c that still described the original wrong hypothesis (0dab2da). One stray marker word remains at physical 0x0 from the first attempt; the system stayed stable throughout, but that address was never intended to be touched.

#### Next Steps:

Reboot the board to clear the stray word at physical 0x0 before relying on it for anything else. With DDR-002 settled, wire a real SOLID_FILL trigger in place of cmd_valid tied to 0, targeting the confirmed-safe 0x20000000 window, drive FB_EN/FB_BASE/FB_STRIDE from that surface, and get an actual picture on HDMI for the first time. LINK-001's ring buffer is still unbuilt; the marker test's one-shot OSD trigger is a reasonable stand-in for CMDQ's eventual trigger until LINK exists.

#### Files Modified:

- Noodles.sv
- tools/ddram_marker_check.c
- tools/ddram_marker_scan.c
- Makefile
- scripts/deploy.sh

#### Status:

- [x] Built
- [x] Passed

---
