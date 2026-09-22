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

## 11 COMMIT Unreleased 6d1396a 2026-09-22T06:44:12-07:00

#### Coming From:

Unreleased a8d2f21

#### Purpose:

Find and fix why LINK-001's real command path visibly ran (LED_POWER/LED_USER both lit) but never produced any visible or memory-verifiable write.

#### Outcome:

Extended the LED-bisection technique further: LED_DISK was repurposed several times in sequence to test successive hypotheses (blit_start reached, blit_done reached, dst_addr correctness, then specific wrong-value candidates), each requiring a full rebuild/redeploy/test round trip run directly over SSH. Along the way, added tools/link_slot_dump.c (raw ring-slot readback bypassing the FPGA's own reconstruction) and tools/mem_scan.c (parameterized memory scan, generalizing ddram_marker_scan.c's hardcoded value), both promoted into the repo. Two false leads were chased and ruled out before finding the real bug: a raw multiply inside link_ring's indexed part-select (`word_idx*32`) was defensively rewritten as an explicit concatenation matching the file's own established style, and a 32-cycle DRAIN state was added between the last command-slot read and dispatch to test a real-DDR3-settling-time hypothesis -- neither changed the symptom, and DRAIN was reverted. A wide `mem_scan` across the FPGA-reserved 512MB window found what first looked like the fill landing at the wrong address (0x22be1000), but a follow-up push with a distinct, unique color proved that match was coincidental pre-existing content, unrelated to anything this project ever wrote -- a reminder that a single matching scan result is not proof of causation without a differential test. Direct LED instrumentation of blit_dst_addr itself (comparing CMDQ's actual output to candidate wrong values) found the real bug: dst_addr reached BLIT as literally 1, opcode's own raw value. Traced to Noodles.sv's link_ring/blit_copy read-port mux selecting on `link_rd_en` (high only during link_ring's REQ states) instead of a signal spanning the full REQ+WAIT lifetime of a pending read -- during the WAIT window the mux fell through to blit_copy's idle address, making ddram_adapter's byte-half-select pick the wrong half of the shared 64-bit DDRAM word at the exact moment link_ring's response arrived. Fixed by adding a new `rd_active` output to link_ring (mirroring rd_addr's own existing REQ+WAIT pinning) and using it as the mux selector (DDR-005). Verified end to end on real hardware: a link-pushed SOLID_FILL now correctly writes its color to 0x30000000, confirmed by direct `/dev/mem` readback (not just LEDs) and by the user seeing the display change. `make sim` passes all six testbenches; `quartus_sh --flow compile Noodles` completed with 0 errors each iteration.

#### Next Steps:

LINK-001 is now proven working end to end on real hardware, not just on paper -- the OSD test triggers (Marker Test, Draw Test, Blit Copy Test) become real candidates for removal per the plan already recorded in an earlier entry, now that LINK no longer needs them as a known-good fallback during its own bring-up. The read-port mux's failure mode (a shared-bus selector keyed on a requester's one-shot rd_en instead of a REQ+WAIT-spanning signal) is now documented in DDR-005 as a pattern to avoid for any future third reader on ddram_adapter; no testbench currently exercises the mux itself (sim/link_ring_dut.sv wires link_ring directly to its own adapter instance with no second client), which is why this bug shipped past `make sim` -- worth a dedicated mux-contention testbench before this class of bug can recur silently again. The displayed fill color also did not visually match the pushed color exactly (reported as yellow, not the cyan link_push.c requests) even though the correct raw bytes are confirmed in memory -- likely an FB_FORMAT channel-order detail, not a data-path bug, but not yet investigated. BLIT-001's third op (hardware noise/static-fill) and a real host-side API/library remain open.

#### Files Modified:

- Noodles.sv
- rtl/link_ring.sv
- sim/link_ring_dut.sv
- tools/link_slot_dump.c
- tools/mem_scan.c
- Makefile
- scripts/deploy.sh

#### Status:

- [x] Built
- [x] Passed

---

## 12 COMMIT Unreleased 3929105 2026-09-22T06:48:57-07:00

#### Coming From:

Unreleased 6d1396a

#### Purpose:

Investigate and fix the previous entry's open loose end: a link-pushed cyan fill displayed as yellow despite correct raw bytes in memory.

#### Outcome:

Not a data-path bug -- BLIT-002 already establishes `color` is written verbatim with no format conversion, so the question was purely which byte order FB_FORMAT expects. emu_ports.vh documents FB_FORMAT bit[4]=0 as RGB byte order in ascending memory address, and since both DDRAM_DIN and the ARM host's uint32_t are little-endian, that puts R in the LOW byte of the 32-bit color word, not the high byte a 0xRRGGBB hex literal suggests. tools/link_push.c's cyan (0x0000FFFF) was R=0xFF,G=0xFF,B=0x00 under this order -- yellow, exactly what was observed. The OSD "Draw Test" button's magenta (0x00FF00FF) never exposed this because R=0xFF,G=0x00,B=0xFF is palindromic under an R/B swap, so it displays correctly regardless of which byte-order assumption is used -- pure coincidence, not evidence the format was ever verified. Documented as BLIT-004 in core-reference.md. Corrected link_push.c's cyan to 0x00FFFF00 and verified on real hardware: memory readback shows the corrected raw bytes and the user confirmed the display now shows true cyan.

#### Next Steps:

LINK-001 is now proven correct end to end on real hardware, including color, closing out the loose end from the previous entry. No host-side color-packing helper exists yet (BLIT-004's consequence) -- worth adding once a real host-side API/library is started, so callers stop needing to hand-derive this byte order themselves. BLIT-001's third op (hardware noise/static-fill) and that host-side API/library remain the two open items from BLIT-001's original milestone.

#### Files Modified:

- tools/link_push.c

#### Status:

- [x] Built
- [x] Passed

---

## 13 COMMIT Unreleased b301df4 2026-09-22T07:08:09-07:00

#### Coming From:

Unreleased 3929105

#### Purpose:

Build the real ARM-side host API (LINK-004) so a caller no longer needs to hand-roll /dev/mem mmap code to push a command, and prove it on hardware in one build cycle before considering an FPGA-side completion counter.

#### Outcome:

Added lib/noodles_link.h/.c: open/close the ring's DDR3 mapping, noodles_rgb (BLIT-004's color byte order), a generic 8-word command push, and typed noodles_push_solid_fill/noodles_push_blit_copy wrappers. Discussed whether to also add RTL-side completion signaling (CMDQ already knows engine_done; nothing currently publishes it to DRAM) against just shipping the ARM library, and deferred the RTL side deliberately -- no current feature needs readback or safe BLIT_COPY source-reuse, and it would mean touching link_ring.sv's FSM again right after the previous entries' hardware debugging cycle, for a capability nothing yet uses. Documented as LINK-004's consequence rather than a silent gap. tools/link_push.c was refactored onto the library rather than left duplicating its old inline mmap code, then rebuilt and pushed on real hardware: the library-based push landed the correct cyan at 0x30000000, confirmed by direct memory readback (matching the exact raw bytes the pre-library version produced) and by the user seeing the display change. `make sim` still passes all six testbenches (no RTL touched this entry).

#### Next Steps:

Per the plan agreed with the user, the next milestone is the FPGA-side completion counter LINK-004 deferred -- a new DRAM-visible field CMDQ/link_ring writes once engine_done fires, giving the host a real fence instead of only dispatch-time read_ptr advancement. That will need its own sim testbench coverage and hardware verification cycle, same discipline as DDR-005. Beyond that, BLIT-001's third op (hardware noise/static-fill) and retiring the OSD test triggers (Marker Test, Draw Test, Blit Copy Test -- now genuinely unnecessary since LINK no longer needs them as a bring-up fallback) remain open.

#### Files Modified:

- lib/noodles_link.h
- lib/noodles_link.c
- tools/link_push.c
- Makefile

#### Status:

- [x] Built
- [x] Passed

---

## 14 COMMIT Unreleased 9b4f0a8 2026-09-22T07:26:08-07:00

#### Coming From:

Unreleased b301df4

#### Purpose:

Build the FPGA-side completion counter LINK-004 deliberately deferred, so the host can finally know when a specific command has actually finished executing, not just been dispatched.

#### Outcome:

Added rtl/link_fence.sv: a small, separate module (not folded into link_ring.sv's own FSM) that watches blit_done||copy_done -- already exposed at Noodles.sv's top level, so cmdq.sv/blit.sv/blit_copy.sv/link_ring.sv needed no changes at all -- and publishes a monotonic completion count to a new DRAM field at HEADER_ADDR+12, as CMDQ's fifth write-mux client (lowest priority, since its writes are never time-critical). tb_link_fence.cpp caught a real bug before it ever reached hardware: the first design combinationally tied wr_en to a state that `reset` forced entry into asynchronously, meaning wr_en would go high while reset itself was still asserted, since the write mux/adapter have no reset input of their own to gate against -- the same class of hazard DDR-002/LINK-003 already had to learn to avoid, just caught in simulation this time. Fixed by folding the "publish an initial 0" behavior into the pending-write condition instead of a distinct INIT state, so reset lands in a non-writing IDLE. lib/noodles_link.{h,c} gained noodles_link_submitted_count() (per-handle push count) and noodles_link_done_count() (reads the fence); the header now documents a real footgun found while proving this on hardware -- comparing a per-handle submitted count against the FPGA's session-lifetime done_count is only valid within one long-lived handle, not across separate short-lived processes each opening their own (an old, already-satisfied done_count can make a brand new command look done before it was even pushed). tools/link_push.c was fixed to check done_count strictly advancing past its own pre-push reading instead, and reverified across three separate invocations on real hardware: fence count 3->4, 4->5, 5->6, one genuine increment per completed command. `make sim` passes all seven testbenches; `quartus_sh --flow compile Noodles` completed with 0 errors (6,383 ALMs, +48 over the previous build, matching link_fence's small footprint).

#### Next Steps:

LINK-001 through LINK-005 now form a complete, hardware-proven host-driven command path: submit, dispatch, execute, and confirm completion. BLIT-001's third op (hardware noise/static-fill) and retiring the OSD test triggers (Marker Test, Draw Test, Blit Copy Test -- genuinely unnecessary now that LINK no longer needs them as a bring-up fallback) remain the open items from earlier entries. A concrete next use for the fence itself -- surface readback (e.g. a screenshot tool) or safe BLIT_COPY source reuse -- would be a good forcing function to exercise it beyond this session's own demonstration.

#### Files Modified:

- rtl/link_fence.sv
- Noodles.sv
- sim/link_fence_dut.sv
- sim/tb_link_fence.cpp
- lib/noodles_link.h
- lib/noodles_link.c
- tools/link_push.c
- Makefile
- files.qip

#### Status:

- [x] Built
- [x] Passed

---

## 15 COMMIT Unreleased 9c88aa7 2026-09-22T07:44:56-07:00

#### Coming From:

Unreleased 9b4f0a8

#### Purpose:

Retire the three OSD test buttons (Marker Test, Draw Test, Blit Copy Test) now that LINK-004/LINK-005 prove the real host-driven command path correct end to end, including completion signaling.

#### Outcome:

Deleted rtl/cmd_test_trigger.sv, rtl/ddram_marker_test.sv, tools/ddram_marker_check.c, and tools/ddram_marker_scan.c (the latter two existed only to verify ddram_marker_test's specific behavior; mem_scan.c already supersedes ddram_marker_scan's functionality). Noodles.sv's CMDQ command front end is back to a single real client (link_ring, no mux); the write-port mux dropped from 5-way to 4-way (blit_copy, link_ring, blit, link_fence). CONF_STR lost its three test-button entries. Test coverage was handled per-testbench rather than deleted wholesale: sim/cmd_trigger_dut.sv+tb_cmd_trigger.cpp and sim/marker_test_dut.sv+tb_marker_test.cpp were deleted outright since tb_solid_fill.cpp already covers CMDQ+BLIT without a trigger wrapper and nothing else tested ddram_marker_test specifically, but sim/cmd_copy_trigger_dut.sv+tb_cmd_copy_trigger.cpp were the ONLY coverage for CMDQ+blit_copy+ddram_adapter's read and write sides together -- a real, still-live path, since BLIT_COPY remains a real opcode LINK can dispatch -- so they were adapted rather than dropped: renamed to sim/engine_copy_dut.sv+tb_blit_copy.cpp, same coverage, cmd_valid/cmd_data driven directly by the testbench instead of through cmd_test_trigger. Documented as CMDQ-003 in core-reference.md, superseding CMDQ-002 (whose decision text named a module that no longer exists); OUT-003's surface parameters remain accurate and unchanged, only its "Draw Test" framing is now historical. Verified via make sim (5/5 testbenches), quartus_sh --flow compile Noodles (0 errors, 6,376 ALMs, down slightly from 6,383), and on real hardware: the OSD buttons are confirmed gone and link-push still works end to end (dispatch, fill, fence) on the cleaned-up core.

#### Next Steps:

The only item left from BLIT-001's original three-op milestone is the third op (hardware noise/static-fill, ported from the Menu core's procedural static generator) -- not started. LINK-001 through LINK-005 and this cleanup together mean the core's real, permanent shape is now what's actually in Noodles.sv, not a bring-up-era mix of real and scaffolding paths.

#### Files Modified:

- Noodles.sv
- files.qip
- Makefile
- scripts/deploy.sh
- sim/engine_copy_dut.sv
- sim/tb_blit_copy.cpp

#### Status:

- [x] Built
- [x] Passed

---

## 16 COMMIT Unreleased 9cf69fa 2026-09-22T07:50:58-07:00

#### Coming From:

Unreleased 9c88aa7

#### Purpose:

Prove BLIT_COPY over the real LINK ring-buffer path, which until now had only ever been exercised via the retired OSD button and simulation.

#### Outcome:

Added tools/blit_copy_push.c: pushes a SOLID_FILL to fill an out-of-view source rect with a caller-chosen color, waits for LINK-005's fence to confirm it landed, then pushes a BLIT_COPY of that region into the visible surface and waits for the fence again. Color is a command-line argument rather than hardcoded, at the user's request, specifically so a repeated run can be told apart from a stale leftover frame at a glance rather than by guessing. No RTL changes were needed -- purely ARM-side, built on the existing lib/noodles_link.h library. Verified on real hardware across two separate runs with different colors: fence advanced twice per run (source fill, then copy) and the visible surface showed the correct color both times -- purple (r=0x80,g=0x00,b=0xff) on the first run, teal (r=0x00,g=0xff,b=0xaa) on the second, confirming the copy tracks live source content rather than some cached or coincidental result. No core-reference.md changes: this is a verification event, not a new decision or contract -- BLIT-003 and LINK-004/LINK-005 already covered the semantics being confirmed here.

#### Next Steps:

Both items proposed as "what's next" after the OSD cleanup are now resolved in the cheaper-first order the user chose: BLIT_COPY is proven over LINK, and BLIT-001's third op (hardware noise/static-fill, ported from the Menu core's procedural static generator) remains the one open item from that milestone's original three-op scope.

#### Files Modified:

- tools/blit_copy_push.c
- Makefile
- scripts/deploy.sh

#### Status:

- [x] Built
- [x] Passed

---

## 17 COMMIT Unreleased a8cdcac 2026-09-22T08:38:47-07:00

#### Coming From:

Unreleased 9cf69fa

#### Purpose:

Add a general-purpose SOLID_FILL push tool and demo it by filling a red square into the top-right corner of the visible surface, at the user's request.

#### Outcome:

Added tools/solid_fill_push.c: pushes one SOLID_FILL anywhere, any size/color, over the real LINK path, as a general complement to link_push.c (fixed full-surface fill) and blit_copy_push.c (needs a source to copy). Verified on real hardware: a 16x16 red square filled at 0x300000c0 (top-right corner, 64x64 surface, pitch 256) landed exactly as expected, confirmed via a video capture card screenshot -- correct size, correct position, the rest of the surface (teal, left over from the previous test) untouched. Mid-task the user asked why the project was porting the Menu core's specific static-noise algorithm for BLIT-001's still-unbuilt third op, and after tracing the requirement back through BLIT-001's own consequence text and the README, confirmed it traced to the project's original, different premise (a pet character composited over the Menu core's static via a Linux-framebuffer overlay) rather than the current standalone-core direction. The user confirmed that premise is abandoned. This entry's commit ended up also carrying the resulting file deletions (src/spike_fb.c, src/fbterm_toggle.c, docs/mister-framebuffer.md, install/user-startup.sh.example, scripts/stage.sh, scripts/hw-test.sh) due to a staging mix-up, not by design -- the next entry covers the rest of that cleanup.

#### Next Steps:

Finish the menu-integration-abandonment cleanup: Makefile/deploy.sh/README.md still reference or build the now-removed spike/fbterm-toggle tools, and BLIT-001's third op needs a real decision (drop vs. redefine generically) recorded in core-reference.md.

#### Files Modified:

- tools/solid_fill_push.c

#### Status:

- [x] Built
- [x] Passed

---

## 18 COMMIT Unreleased 7421ae7 2026-09-22T08:38:47-07:00

#### Coming From:

Unreleased a8cdcac

#### Purpose:

Finish abandoning the menu-integration concept: update the build/deploy scripts, rewrite README.md, and record BLIT-001's third op as dropped rather than deferred.

#### Outcome:

Makefile no longer builds misterpet-spike/fbterm-toggle (ARMBIN/ARMTOG/HOSTBIN targets and their rules removed); deploy.sh's BINS list and usage hints updated to match. README.md is rewritten from scratch -- the old one was almost entirely about the abandoned pet-on-menu-background premise (Linux fbdev overlay, F9/uinput handling, VT switching); the new one describes the actual current project: LINK/CMDQ/BLIT architecture, the host API, build instructions, pointing to core-reference.md/core-log.md as the authoritative sources rather than duplicating their content. core-reference.md gained BLIT-005, marking BLIT-001 SUPERSEDED: the milestone is considered met with its first two ops (SOLID_FILL, BLIT_COPY, both proven over the real LINK path) rather than blocked on a third op whose whole justification (a measured 12fps software bottleneck redrawing Menu's static in the Linux framebuffer) no longer describes anything this project does. Also fixed, incidentally, a real pre-existing formatting bug in core-reference.md found while editing nearby: DDR-003's own "- record_id: DDR-003" line had been lost in an earlier session's edit, making it read as a continuation of BLIT-004's YAML mapping instead of its own record -- record/kind/decision/consequence/status counts now all match (27 each). `make`/`make host`/`make sim` all verified clean after the removal; no RTL changed, so no new Quartus build was needed.

#### Next Steps:

The project's control file, ai/core.md, still carries the old premise in its own title ("# MiSTer-Pet") and Purpose line ("MiSTer-Noodles is tamagochi style pet for the MiSTer FPGA") -- core.md is RESTRICTED per its own Agent Recovery Policy and was not touched here; flagged to the user directly rather than edited. With BLIT-001's milestone now considered complete, the project has no single obvious "next" item from prior scope -- next steps are open pending user direction.

#### Files Modified:

- Makefile
- scripts/deploy.sh
- README.md

#### Status:

- [x] Built
- [x] Passed

---
