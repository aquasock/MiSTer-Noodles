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
