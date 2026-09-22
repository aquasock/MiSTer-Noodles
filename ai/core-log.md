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

## 5 COMMIT Unreleased 1c39477 2026-09-21T23:59:22-07:00

#### Coming From:

Unreleased 2fee444

#### Purpose:

Wire a real SOLID_FILL command end to end (CMDQ->BLIT->DDRAM_*->MISTER_FB->HDMI) and check a sibling project for platform knowledge before deploying.

#### Outcome:

Added rtl/cmd_test_trigger.sv (CMDQ-002), a generic one-shot "present this fixed command to CMDQ until accepted" module, same shape as ddram_marker_test but through CMDQ's real command interface. Wired it into Noodles.sv as a new "Draw Test" OSD button firing one hardcoded SOLID_FILL (64x64, 32bpp, magenta) through CMDQ->BLIT, with FB_EN/FB_BASE/FB_STRIDE/FB_WIDTH/FB_HEIGHT/FB_FORMAT (OUT-003) scanning that surface out via MISTER_FB, gated on a "draw ever completed" latch. Also fixed CE_PIXEL, previously hardcoded to 0 -- checking sys/sys_top.v and sys/video_mixer.sv showed the framework's OSD/mixer chain needs a real toggling pixel enable regardless of whether the picture comes from MISTER_FB or a core's own raster output. Verified the whole trigger-to-pixel path in simulation first (sim/tb_cmd_trigger.cpp); `make sim` passes all four testbenches.

Before deploying, per the user's request checked aquasock/MiSTer-Raster -- a much more mature sibling MiSTer core, same author, with real hardware-accepted releases -- rather than re-deriving platform facts from scratch. That project's own hardware history (commit 53f322905, "Move H262 frame store out of scaler DDR region") showed physical byte address 0x20000000, which SURF-003 had treated as the safe start of the FPGA-reserved window and which this project had already used for the marker test, the Draw Test surface, and FB_BASE, actually collides with MiSTer's own system video scaler RAM base. That project moved to 0x30000000 after hitting this collision and has used it safely across many subsequent hardware-accepted releases (through v0.9.5). Recorded as SURF-004 and fixed everywhere in this project before the corrected build was ever deployed with FB_EN enabled -- the earlier build with FB_EN=0 (entry 4) never actually displayed anything from 0x20000000, so no visible corruption occurred, but continuing to that address would have been a real risk once FB_EN went live. `quartus_sh --flow compile Noodles` completed cleanly with the corrected addresses: 0 errors, 57 warnings, and unlike the previous two builds, no "Timing requirements not met" critical warning this time (all positive slack, including the pll_hdmi internal node that was marginally negative before). Deployed to the QMTech MiSTer as Noodles_20260921d.rbf; not yet tested on hardware.

Saved two persistent-memory records (mister-raster-sibling, check-prior-projects-first) so future sessions check the user's prior MiSTer projects for hard-won platform facts before re-deriving them.

#### Next Steps:

Load Noodles_20260921d.rbf, press "Draw Test," and confirm both that the disk LED / screen actually shows a 64x64 magenta square (proving MISTER_FB scan-out works end to end for the first time) and that ddram_marker_check (now targeting 0x30000000) reports PASS. If the picture doesn't appear, the likely suspects are CE_PIXEL's untuned rate, FB_STRIDE/FB_FORMAT byte-order assumptions (never confirmed against MISTER_FB specifically, only inferred from the old /dev/fb0 spike work), or video mode negotiation. LINK-001's ring buffer remains unbuilt; CMDQ-002's hardcoded command is still the only way to reach CMDQ.

#### Files Modified:

- Noodles.sv
- rtl/cmd_test_trigger.sv
- sim/cmd_trigger_dut.sv
- sim/tb_cmd_trigger.cpp
- tools/ddram_marker_check.c
- Makefile
- files.qip

#### Status:

- [x] Built
- [ ] Passed

---

## 6 COMMIT Unreleased 1c39477 2026-09-22T00:02:24-07:00

#### Coming From:

Unreleased 1c39477

#### Purpose:

Record hardware confirmation of entry 5's build: the engine's first real picture on screen.

#### Outcome:

The user loaded Noodles_20260921d.rbf and pressed "Draw Test." The whole screen filled solid magenta -- correct, not a bug: FB_WIDTH/FB_HEIGHT are only 64x64, so MiSTer's scaler upscales the buffer to fill the display, and since the entire buffer was filled one color, a full-screen result is exactly what a correctly working pipeline produces. This is the first pixel this engine has ever put on a real display: CMDQ decoded CMDQ-002's command, BLIT wrote all 4096 pixels through the DDR-001 adapter, and MISTER_FB (OUT-002/OUT-003) scanned it out correctly. tools/ddram_marker_check.c also reported PASS at physical 0x30000000, confirming SURF-004's corrected address end to end on real hardware, not just in the abstract.

#### Next Steps:

BLIT-001's milestone still calls for straight blit and hardware noise/static-fill, neither implemented yet -- solid-fill is the only proven operation. LINK-001's ring buffer remains the biggest architectural gap: CMDQ-002's hardcoded single command is still the only way anything reaches CMDQ. Worth considering next: a second, differently-positioned/colored fill to prove BLIT's address math beyond a buffer-filling rectangle, before moving on to straight blit or LINK.

#### Files Modified:

None.

#### Status:

- [x] Built
- [x] Passed

---

## 7 COMMIT Unreleased 285b3cd 2026-09-22T00:21:22-07:00

#### Coming From:

Unreleased 1c39477

#### Purpose:

Implement BLIT_COPY (BLIT-001's straight-blit op) end to end and check MiSTer-Raster again before building the read path.

#### Outcome:

Before writing any RTL, checked aquasock/MiSTer-Raster on two questions: whether its DDR arbiter had a reusable pattern for adding DDR3 reads (yes -- a descriptor queue tagging outstanding reads by owner, useful once this project has more than one concurrent reader, though not needed yet since BLIT_COPY only ever has one outstanding read), and whether it had already solved LINK's host-command-delivery problem (no -- its host channel is the standard MiSTer mounted-file sector-read protocol, built for streaming a big file in, not for a live process pushing small draw commands; doesn't change LINK's plan). Implemented rtl/blit_copy.sv (BLIT-003) as a separate module from the proven rtl/blit.sv fill engine, reusing CMDQ-001's slot layout by giving meaning to the two words SOLID_FILL left reserved (src_addr, src_pitch). Replaced rtl/ddram_write_adapter.sv with rtl/ddram_adapter.sv (DDR-003), adding a generic single-outstanding read port. cmdq.sv now decodes opcode 2 and dispatches to whichever engine is active via a new latch. Verified with a new Verilator testbench against a read+write Avalon-MM memory model, independently-misaligned source and destination addresses, different pitches; caught and fixed a testbench-only bug (cmd_test_trigger's busy/done reflect CMDQ accepting the command, not the engine finishing -- same mistake as an earlier cycle, same fix: wait for the actual write count). `make sim` passes all five testbenches. Wired a "Blit Copy Test" OSD button into Noodles.sv, sharing CMDQ with "Draw Test" through a small priority mux. `quartus_sh --flow compile Noodles` completed with 0 errors, no timing violations. Deployed as Noodles_20260922a.rbf; not yet tested on hardware.

#### Next Steps:

Get user confirmation that "Blit Copy Test" actually shows a distinct 8x8 square in the corner of the magenta surface (content will look like arbitrary DDR3 noise, not a chosen color, by design) and that nothing else broke. BLIT-001's third op, hardware noise/static-fill, is still unimplemented. After that, per the user's stated plan, move to LINK-001: the ring buffer is now the only piece standing between this project and a real host-driven command stream, and every OSD-button trigger built so far (marker test, draw test, blit copy test) is scaffolding LINK will replace, not extend.

#### Files Modified:

- Noodles.sv
- rtl/blit_copy.sv
- rtl/ddram_adapter.sv
- rtl/cmdq.sv
- sim/cmd_copy_trigger_dut.sv
- sim/tb_cmd_copy_trigger.cpp
- sim/cmd_trigger_dut.sv
- sim/engine_dut.sv
- sim/engine_ddram_dut.sv
- Makefile
- files.qip

#### Status:

- [x] Built
- [ ] Passed

---

## 8 COMMIT Unreleased 285b3cd 2026-09-22T00:23:19-07:00

#### Coming From:

Unreleased 285b3cd

#### Purpose:

Record hardware confirmation of entry 7's build: BLIT_COPY proven end to end on real hardware.

#### Outcome:

The user loaded Noodles_20260922a.rbf, pressed "Draw Test" then "Blit Copy Test," and saw a black 8x8 square appear in the corner of the magenta surface. Black is a perfectly reasonable result for 0x30010000's actual content -- untouched DDR3 commonly reads as all-zero after boot-time scrubbing -- and a visibly distinct square from the surrounding magenta is exactly the evidence needed: the copy engine read real data from the source address and wrote it to the destination, both through the real DDRAM_* bus, not a stub. BLIT-003 and DDR-003 are now hardware-confirmed, not just simulated.

#### Next Steps:

Move to LINK-001, per the user's stated plan (blit then link). Every OSD-button test command built so far (marker test, draw test, blit copy test) is scaffolding to be replaced, not extended -- LINK's ring buffer is the real host-to-FPGA command path. BLIT-001's third op (hardware noise/static-fill) remains unimplemented and is lower priority than LINK.

#### Files Modified:

None.

#### Status:

- [x] Built
- [x] Passed

---

## 9 COMMIT Unreleased 3c7180d 2026-09-22T03:37:36-07:00

#### Coming From:

Unreleased 285b3cd

#### Purpose:

Implement LINK-001: a real host-driven ring buffer command path, replacing the OSD test triggers as CMDQ's real source.

#### Outcome:

Implemented rtl/link_ring.sv (LINK-002/LINK-003): a 64-slot ring in shared DDR3, polled only while CMDQ is idle so it never actually contends with blit_copy's reads, self-initializing write_ptr/read_ptr to 0/0 on reset since DRAM isn't cleared by an FPGA reset and stale content could otherwise be misread as a valid pointer -- a real bug this project's own testing caught partway through, not a hypothetical worry. Verified with a new Verilator testbench acting as the host (writing commands and write_ptr directly into a behavioral memory model, exactly as an ARM process would via /dev/mem) across 5 commands on a 4-slot ring, forcing a wraparound. That test caught a second real bug: rd_addr was only pinned to the polled header address while state==POLL_REQ, so once the requester moved to POLL_WAIT to await the response, the combinational address fell through to a stale slot-fetch address left over from the previous fetch, making the adapter's byte-half-select pick the wrong half of the response. Fixed by holding rd_addr across the REQ/WAIT pair together. Also found and fixed a latent dead-code bug in this test's own memory model (and cmd_copy_trigger's, same copy-paste origin): `words_[addr]` inserts a zero-valued entry via operator[] before a `find()==end()` check could ever see a missing key, so a "start from the fill pattern" branch never actually ran -- harmless where it was already used, but worth fixing before it hides something real. `make sim` passes all six testbenches now.

Added tools/link_push.c: the first real host-driven command this project has ever issued, an ARM process writing a SOLID_FILL (cyan, distinct from the OSD "Draw Test" button's magenta) directly into shared DDR3 via /dev/mem, refusing to push if the ring is full. Wired link_ring into Noodles.sv as a third CMDQ command source and a second DDRAM read client alongside blit_copy, both muxes extended with the same tie-breaker-not-arbitration caveat as before. `quartus_sh --flow compile Noodles` completed with 0 errors, no timing violations. Deployed as Noodles_20260922b.rbf; not yet tested on hardware.

#### Next Steps:

Get hardware confirmation: load Noodles_20260922b.rbf, press "Draw Test" (magenta baseline), then run link-push on the MiSTer and confirm the surface turns cyan -- proof the ring buffer genuinely works end to end, not just in simulation. If it does, LINK-001 can be marked DECIDED-and-proven rather than DECIDED-on-paper, and the OSD test triggers become candidates for removal rather than permanent fixtures. BLIT-001's third op (hardware noise/static-fill) and a real host-side API/library (link_push.c is a one-shot diagnostic, not something a "game" would use) remain open.

#### Files Modified:

- Noodles.sv
- rtl/link_ring.sv
- sim/link_ring_dut.sv
- sim/tb_link_ring.cpp
- sim/tb_cmd_copy_trigger.cpp
- tools/link_push.c
- Makefile
- files.qip
- scripts/deploy.sh

#### Status:

- [x] Built
- [ ] Passed

---

## 10 COMMIT Unreleased 0e408fe 2026-09-22T05:31:37-07:00

#### Coming From:

Unreleased 3c7180d

#### Purpose:

Add hardware observability for LINK-001's first real test, after it silently failed to produce any visible change.

#### Outcome:

The user ran link-push on Noodles_20260922b.rbf: it reported success (write_ptr 0->1) but the surface stayed magenta instead of turning cyan. link_ring passed simulation thoroughly, including a wraparound case, but only in isolation against a dedicated adapter instance -- never integrated with the other three write-mux clients (marker_test, blit, blit_copy) actually contending for the bus in Noodles.sv, which is a real difference between the tested configuration and the deployed one. Rather than guess further, added the same LED-bisection technique that found DDR-002's address bug: LED_POWER now latches solid once link_ring has actually dispatched a command to CMDQ, using the post-mux link_cmd_valid/link_cmd_ready signals specifically so the result reflects what the mux actually granted, not just what link_ring itself believes it sent. Also corrected LED_DISK/LED_POWER to take full manual LED control (bit[1]=1 per emu_ports.vh) rather than leaving them OR'd with system status, which the earlier marker_done_ever wiring had never done correctly either. `quartus_sh --flow compile Noodles` completed with 0 errors, no timing violations. Deployed as Noodles_20260922c.rbf; not yet tested on hardware.

#### Next Steps:

Get the LED result: load Noodles_20260922c.rbf, run link-push again, and report whether LED_POWER lit. If it didn't light, the fault is inside link_ring (init sequence, write-mux access for INIT/writeback, polling, read-mux access, or fetch) and needs its own isolated hardware test akin to the marker test. If it did light, the fault is downstream in this specific CMDQ/BLIT mux integration despite that path being separately proven by Draw Test and Blit Copy Test, meaning something about having a third command source changes CMDQ's or the write-mux's behavior in a way simulation didn't catch.

#### Files Modified:

- Noodles.sv

#### Status:

- [x] Built
- [ ] Passed

---
