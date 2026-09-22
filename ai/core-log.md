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
