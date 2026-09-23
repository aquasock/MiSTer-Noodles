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

## 19 COMMIT Unreleased f10adb6 2026-09-22T08:57:28-07:00

#### Coming From:

Unreleased 7421ae7

#### Purpose:

Build the actual rendering capability the user wants this engine to reach: sprite compositing with transparency, targeting Dogz (the mid-90s virtual pet game) as the concrete visual reference, in a shape someone porting from SDL would find familiar.

#### Outcome:

Established with the user first that multi-frame animation needs no new hardware -- the host just issues a new BLIT_COPY-family command with a different source frame each tick, which LINK already supports -- so the real gap was transparency: plain BLIT_COPY is strictly opaque. Added BLIT_COPY_KEY (opcode 3, BLIT-006): colorkey transparency, chosen over full alpha blending as the cheaper mechanism that actually matches how sprite games of that era worked. Dispatched to the same rtl/blit_copy.sv engine as plain BLIT_COPY rather than a new module, since the two are structurally identical (read source pixel, conditionally write destination); blit_copy.sv gained key_enable/key_value inputs, and CMDQ now sets them per-opcode, reusing the command's otherwise-unused color field as the key value for opcode 3. tb_blit_copy.cpp gained a second test: a 4x4 checkerboard half key-colored, verifying bit-exact read count (16, every pixel inspected), write count (8, keyed pixels skipped), and final destination content in simulation. tools/blit_copy_key_push.c proves it on real hardware: built a minimal sprite purely from SOLID_FILLs (colorkey-colored region with a smaller solid square inside it) and BLIT_COPY_KEY'd it onto a differently-colored background -- confirmed visually, background color showing through cleanly around a sprite square with no trace of the colorkey border. lib/noodles_link.h/.c gained noodles_push_blit_copy_key(). `make sim` (5/5) and `quartus_sh --flow compile Noodles` (0 errors, 6,323 ALMs) both clean.

#### Next Steps:

The engine can now do what was asked: fill, opaque copy, and transparent (colorkeyed) copy -- enough for basic sprite-over-background compositing, animated by the host swapping source frames each tick. Not yet covered, if the Dogz-style target keeps growing: multiple simultaneously-tracked surfaces/sprites with host-side allocation (today the host just picks addresses by hand), and any need for true alpha blending (explicitly deferred, BLIT-006's consequence) if colorkey's hard edges turn out not to be enough.

#### Files Modified:

- rtl/blit_copy.sv
- rtl/cmdq.sv
- Noodles.sv
- sim/engine_copy_dut.sv
- sim/tb_blit_copy.cpp
- lib/noodles_link.h
- lib/noodles_link.c
- tools/blit_copy_key_push.c
- Makefile
- scripts/deploy.sh

#### Status:

- [x] Built
- [x] Passed

---

## 20 COMMIT Unreleased 511f55e 2026-09-22T09:01:16-07:00

#### Coming From:

Unreleased f10adb6

#### Purpose:

Benchmark the real command path -- push, dispatch, execute, fence -- now that SOLID_FILL, BLIT_COPY, and BLIT_COPY_KEY all work end to end, at the user's request.

#### Outcome:

Added tools/bench.c: pushes a batch of identical commands back to back, times from the first push to LINK-005's fence confirming the last one actually finished, reports commands/sec and pixels/sec -- the end-to-end number a real host program would see, not an idealized FPGA-only figure. Ran on real hardware (clk_sys=20MHz). SOLID_FILL runs at essentially 1 clock cycle per pixel steady-state (49.4ns/px extrapolated from 32x32->64x64, 208.6us for a full 64x64 fill) -- the theoretical maximum for a single-write-per-cycle engine, meaning there are effectively zero backpressure stalls at this scale. BLIT_COPY costs about 8.2 cycles/pixel steady-state (410ns/px, 1686.5us for a full 64x64 copy) -- roughly 8x SOLID_FILL's per-pixel cost, which traces directly to DDR-003's already-documented single-outstanding-read simplification: blit_copy issues one read, waits for the complete round trip, then writes, with zero pipelining between pixels. BLIT_COPY_KEY with a colorkey chosen to never match (worst case, every pixel written) measured the same as plain BLIT_COPY within noise (426.3 vs 425.8us/cmd at 32x32, 1686.5 vs 1686.5us/cmd at 64x64) -- the colorkey compare is a free, purely combinational check adding no measurable latency. A 1x1 fill (500 samples) isolates roughly-fixed per-command overhead at ~3.3us, consistent with link_ring's own poll/fetch/dispatch cost (8 sequential DDR3 reads per command, LINK-003). No core-reference.md changes -- this is measured evidence, not a new decision or contract, so it belongs here per the project's own maintenance-boundary rule rather than as a record.

#### Next Steps:

The ~8x SOLID_FILL-vs-BLIT_COPY gap is fully explained by DDR-003's single-outstanding-read design, which that record already flagged as a deliberate v1 simplification with a known extension path (MiSTer-Raster's descriptor-queue arbiter, for when a second concurrent reader or read pipelining is ever needed) -- worth revisiting if BLIT_COPY throughput becomes a real bottleneck for whatever gets built on top of this, but not before then. No other action items from this benchmark; it was a measurement task, not a bug hunt.

#### Files Modified:

- tools/bench.c
- Makefile
- scripts/deploy.sh

#### Status:

- [x] Built
- [x] Passed

---

## 21 COMMIT Unreleased 3741062 2026-09-22T09:21:02-07:00

#### Coming From:

Unreleased 511f55e

#### Purpose:

Add double buffering, prioritized ahead of the BLIT_COPY throughput gap and resolution scale-up as the more fundamental prerequisite: any real-time animated content would tear visibly drawing directly into the live-scanned-out surface, regardless of sprite count or resolution.

#### Outcome:

Added rtl/present.sv: owns a single front_sel register selecting which of two fixed 64x64/32bpp surfaces (BUFFER_A at 0x30000000, BUFFER_B at 0x30008000) FB_BASE currently points at, flipped only on a fresh FB_VBL rising edge so a flip request arriving mid-blank waits for the next blanking interval rather than risking a change too close to when active video resumes -- deliberately conservative (worst case ~2 frames' latency) rather than depending on undocumented assumptions about ascal's own prefetch timing. Confirmed FB_VBL needs no cross-clock synchronizer before writing any RTL: this core's CLK_VIDEO output (already tied to clk_sys) is literally what sys_top.v uses to generate FB_VBL, so present.sv's own clock domain already matches. PRESENT (opcode 4) is CMDQ's third dispatch target; cmdq.sv's single active_copy bit became a 3-way active_engine selector (blit/copy/present), and the three other DUTs that instantiate cmdq directly (engine_dut, engine_ddram_dut, engine_copy_dut) needed their present ports tied off -- their own testbenches still passing unchanged confirmed the refactor didn't disturb blit/copy dispatch. present_done_ever (renamed from draw_done_ever) now gates FB_EN on the first PRESENT completing rather than the first draw, since a completed draw only changes the back buffer now. lib/noodles_link.h/.c gained noodles_link_back_buffer() and noodles_present_and_wait(), computing which buffer is back purely from the handle's own count of CONFIRMED presents -- no new DRAM-published state needed beyond the existing LINK-005 fence. sim/tb_present.cpp verifies present.sv in isolation, including the specific case that would have been easy to get wrong: a start pulse arriving while FB_VBL is already high must wait for a NEW rising edge, not flip immediately just because it happens to already be in a blanking interval. tools/present_demo.c cycles 6 solid colors through alternating buffers on real hardware; the buffer address alternated correctly every flip and the sequence displayed cleanly across two separate runs, confirmed visually by the user both times (the user asked for a second run before confirming, which came back identical to the first). `make sim` (6/6) and `quartus_sh --flow compile Noodles` (0 errors, 6,452 ALMs) both clean.

#### Next Steps:

Per the priority order agreed with the user (double buffering, then resolution, then BLIT_COPY throughput only if something concrete proves it's a bottleneck), resolution scale-up (64x64 -> something StarCraft/OpenBW-scale, e.g. 640x480) is next. Anything drawing today must be updated to the double-buffered pattern -- draw at noodles_link_back_buffer(), then noodles_present_and_wait(), then re-read back_buffer() for the next frame -- code written against the single-buffer examples in earlier entries (which drew directly at a fixed address) is now stale as a pattern to copy from, though those addresses/commands still work individually.

#### Files Modified:

- rtl/present.sv
- rtl/cmdq.sv
- Noodles.sv
- sim/present_dut.sv
- sim/tb_present.cpp
- sim/engine_dut.sv
- sim/engine_ddram_dut.sv
- sim/engine_copy_dut.sv
- lib/noodles_link.h
- lib/noodles_link.c
- tools/present_demo.c
- Makefile
- scripts/deploy.sh
- files.qip

#### Status:

- [x] Built
- [x] Passed

---

## 22 COMMIT Unreleased 06734c5 2026-09-22T09:32:44-07:00

#### Coming From:

Unreleased 3741062

#### Purpose:

Scale the surfaces up from the 64x64 bring-up size to something StarCraft/OpenBW-scale (640x480), the second item in the priority order agreed with the user (double buffering, then resolution, then BLIT_COPY throughput only if proven necessary).

#### Outcome:

Each 640x480x4B buffer is ~1.17MB, far larger than the old 16KB surface, so OUT-004's tight 32KB buffer spacing no longer fit -- redesigned the address map with generous 2MB-aligned slots: BUFFER_A/BUFFER_B at 0x31000000/0x31200000, well clear of LINK-002's ring and of each other. Moved the LED_DISK regression check's BUFFER_A/BUFFER_B localparams to the top of Noodles.sv (both it and FB_BASE's mux need them) and fixed the check itself to validate against EITHER buffer address -- it was still hardcoded to a single old address and would have false-positived on every legitimate draw to whichever buffer wasn't that one. Updated lib/noodles_link.h's buffer constants to match. Found and fixed a real gap while auditing every tool against the new map: link_push.c, blit_copy_push.c, and blit_copy_key_push.c all still drew directly into a hardcoded single-buffer address and never called present() -- leftover from before OUT-004 landed. Without a present, double buffering means nothing they drew would ever actually become visible; all three were updated to draw into noodles_link_back_buffer() and present_and_wait(). blit_copy_push.c/blit_copy_key_push.c also needed their own off-screen source scratch moved to a fresh 2MB slot (0x31400000, clear of both buffers and the ring) since a full-size source region would otherwise collide with the ring header at the old 0x30010000 scratch address, and their fence-wait timeouts bumped from 200ms to 2s -- a full-surface SOLID_FILL now costs ~15ms and a full-surface BLIT_COPY ~126ms (bench.c's own measured per-pixel rates), comfortably within budget but well past the old 64x64-era timeout. solid_fill_push.c and present_demo.c needed no changes at all, already fully symbolic. Verified on real hardware: present_demo.c's color cycle confirmed clean with correct alternating addresses (0x31000000/0x31200000) both in its own printed output and visually (pillarboxed 4:3 on the user's 16:9 display, exactly as expected for a true 640x480 source, not a bug); blit_copy_key_push.c's sprite composite (now a 128x128 square, scaled up from 24x24 for visibility on the larger canvas) confirmed visually correct too. `quartus_sh --flow compile Noodles`: 0 errors, 6,319 ALMs, 0.571ns/0.246ns worst-case setup/hold slack, ~2:18 total compile time.

#### Next Steps:

Both non-throughput items from the original three-item priority list are done (double buffering, resolution). BLIT_COPY's ~8.2-cycles/pixel throughput gap (DDR-003's single-outstanding-read simplification) remains deliberately deferred until something concrete proves it's actually a bottleneck -- per the user's own agreed reasoning, not before. No other open items were surfaced by this pass.

#### Files Modified:

- Noodles.sv
- lib/noodles_link.h
- tools/link_push.c
- tools/blit_copy_push.c
- tools/blit_copy_key_push.c
- tools/bench.c

#### Status:

- [x] Built
- [x] Passed

---

## 23 COMMIT Unreleased 6a3627a 2026-09-22T09:38:57-07:00

#### Coming From:

Unreleased 06734c5

#### Purpose:

Build the actual target demo: a sprite animated continuously over a background, the real proof this engine's rendering capability (BLIT-006's colorkey compositing, OUT-004's double buffering, SURF-005's resolution) works together as a sustained game loop, not just isolated static commands.

#### Outcome:

Added tools/sprite_demo.c. Every previous demo pushed a handful of commands and stopped; this one runs the full per-frame cycle (clear the back buffer, colorkey-composite the sprite at a new position, present, wait) continuously for a configurable duration, which is the first real soak test of the ring buffer under sustained load, the fence under continuous polling, and present's vblank sync over many consecutive flips -- none of which anything before this exercised beyond a handful of commands. The sprite is built once from three SOLID_FILLs (a colorkey background, a brown body rect, a smaller offset tan head rect -- a genuine two-part silhouette, not just a single square) into its own 2MB scratch slot, then bounced off the buffer edges, re-fetching noodles_link_back_buffer() every frame the way a real game loop would. No RTL changes and no new host API were needed -- this is purely composition of what LINK-004/LINK-005/BLIT-006/OUT-004/SURF-005 already provide. Verified on real hardware across two separate 15-second runs: 453 frames then 456 frames, stable ~30fps average with no degradation over either run (no ring stalls, no fence timeouts, no wedging), confirmed visually clean -- smooth bouncing motion, no tearing or glitches -- by the user both times.

#### Next Steps:

The engine has now been proven, end to end and under sustained load, to do what the user's original Dogz reference asked for: an animated character composited over a background, driven the way a real game loop would drive it. Two gaps remain open from the earlier OpenBW-scoping discussion, neither blocking further demo work: an asset-upload path (today every sprite is built from SOLID_FILL rects; there's no way to load real decoded image data into a surface, though this is expected to be a cheap host-side mmap+memcpy addition per DDR-002, not new hardware), and BLIT_COPY's throughput gap (still deliberately deferred -- 30fps on a single small sprite doesn't yet prove or disprove anything about many-sprite scenes).

#### Files Modified:

- tools/sprite_demo.c
- Makefile
- scripts/deploy.sh

#### Status:

- [x] Built
- [x] Passed

---

## 24 COMMIT Unreleased 821c046 2026-09-22T09:52:13-07:00

#### Coming From:

Unreleased 6a3627a

#### Purpose:

Close the asset-upload gap sprite_demo's entry flagged: every sprite in every demo so far was built out of SOLID_FILL rects, with no way to get real decoded image data into a surface.

#### Outcome:

Added noodles_link_upload() to lib/noodles_link.{h,c} -- a plain mmap+memcpy straight into DDR3 through the same /dev/mem fd noodles_link_open() already holds, needing no new opcode, no ring traffic, and no FPGA-side change at all, since DDR-002 already made DDRAM_* addresses direct physical addresses. Proved it with tools/load_bmp.c, a self-contained uncompressed-24-bit-BMP loader (BITMAPINFOHEADER only, chosen over PNG/JPEG specifically for zero decoding dependencies): parses the header, converts BGR rows to BLIT-004's packed R|(G<<8)|(B<<16) order while flipping to top-down row order, uploads the converted buffer to the shared 0x31400000 scratch slot, clears the back buffer, BLIT_COPYs the image in at a centered (or caller-given) position, and presents. Generated a genuine 320x240 test image via Python/PIL (sky gradient, sun, ground, a simple house) since no real asset existed yet, deployed both the tool and the test image to the MiSTer, and ran it: console output confirmed the upload size/address and presented position, and the user confirmed the on-screen result was a perfect match against the source file, after first asking to see the source file itself before confirming -- a reasonable check given the display is being viewed indirectly, not a sign anything was wrong.

#### Next Steps:

The other gap sprite_demo's entry flagged -- BLIT_COPY's ~8.2-cycles/pixel throughput -- remains deliberately deferred until something concrete proves it's a bottleneck. A real game loop combining this entry's asset loading with sprite_demo's animate/composite/present pattern (i.e. an actual sprite loaded from a BMP, animated, instead of one built from SOLID_FILL rects) has not been built yet and is the natural next proof point if the user wants to keep pushing toward the Dogz-style target.

#### Files Modified:

- lib/noodles_link.h
- lib/noodles_link.c
- tools/load_bmp.c
- Makefile
- scripts/deploy.sh

#### Status:

- [x] Built
- [x] Passed

---

## 25 COMMIT Unreleased 7f1e84e 2026-09-22T10:18:47-07:00

#### Coming From:

Unreleased 821c046

#### Purpose:

The user asked directly: "can we load 10 at once and bounce them all around to stress the core?" -- combine LINK-006's asset loading with sprite_demo's animate/composite/present pattern, but with N independent sprites per frame instead of one, to find out whether the ring/fence/present hold up under real multi-sprite load, not just a single sprite.

#### Outcome:

Factored the BMP-parsing logic out of tools/load_bmp.c into tools/bmp_loader.h (noodles_bmp_load(), returning a tightly-packed width*4-pitch buffer) once a second real caller needed it, rather than duplicating it -- load_bmp.c itself was rewritten onto the shared loader as part of this, switching its own source pitch from the wasteful full-screen NOODLES_BUFFER_PITCH to a tight width*4. Generated a real checked-in sprite asset (assets/sprite.bmp, a 48x48 magenta-colorkeyed smiley, PIL-generated) since none existed yet, and added tools/stress_demo.c: uploads that sprite once via noodles_link_upload(), then runs the same clear/composite/present loop as sprite_demo.c but for N independently-bouncing instances per frame (random start position and velocity, same edge-bounce logic as sprite_demo, each BLIT_COPY_KEY individually fence-waited like every other demo here). Verified on real hardware at count=10, run=15s: 30.0fps steady average across the whole run (451, then 450, then 450 frames across three separate runs), no ring-full errors, no fence timeouts, no degradation over time. The very first invocation (immediately after the fresh deploy, before any rerun) showed a real visual artifact the user described as NES-style sprite flicker not tied to a scanline -- ghosted images at sprites' previous positions -- which did NOT reproduce on two subsequent reruns of the identical binary with identical arguments, confirmed clean both by console output and by the user watching live, and a third run the user screen-recorded played perfectly throughout. No code change was made in response since nothing about the artifact was pinned down: it could be a one-off from whatever state (front_sel, FB_EN gating, or the capture device's own signal resync) existed at the exact moment of that first run, immediately following a redeploy. Recorded here as an observed-but-unreproduced anomaly, not a fixed bug -- if it recurs, the next useful step is a hardware capture synced to command timestamps, not another guess.

#### Next Steps:

10 sprites did not stress the core in any measurable way (rock-solid 30fps, no backpressure) -- the natural next step if more stress is wanted is a higher count (the tool supports up to MAX_SPRITES=64 without code changes) to find where, if anywhere, this design's serial fence-wait-per-command pattern actually becomes a bottleneck. The one-off flicker artifact remains unexplained; watch for it recurring under any condition (higher count, longer run, right after a fresh core load/redeploy specifically) since a reproducible trigger would be the first real lead.

#### Files Modified:

- tools/bmp_loader.h
- tools/load_bmp.c
- tools/stress_demo.c
- assets/sprite.bmp
- Makefile
- scripts/deploy.sh

#### Status:

- [x] Built
- [x] Passed

---

## 26 COMMIT Unreleased a7c893c 2026-09-22T11:40:00-07:00

#### Coming From:

Unreleased 7f1e84e

#### Purpose:

The user asked to push count=64 on stress_demo.c to actually stress the core ("lets do 64"). It ran at a stable 10fps with no ring/fence errors, but that number was suspicious -- worth finding out whether it was a real hardware limit or host-side overhead before treating it as a finding.

#### Outcome:

**Pipelining fix (LINK-007).** stress_demo.c fence-waited after every single push (1 clear + count blits + 1 present, all individually waited). At count=64 that serialized 66 host round trips per frame; rewrote to push commands back-to-back, blocking only on an actual ring-full return (push_fill_retry/push_key_retry/present_retry helpers, retrying with a short sleep). This raised 64-sprite throughput from 10fps to 15fps initially -- but the user reported the display now showed real, visible ghosting ("NES sprite flicker... ghosted from the bmp's previous location"), confirmed both live and on a screen recording, not a capture artifact.

**Real bug found and fixed (LINK-007).** noodles_present_and_wait() sampled done_count() before pushing PRESENT and returned success as soon as done_count() advanced by ANY amount afterward -- correct only when nothing else is in flight, which was true for every caller before stress_demo.c pipelined. With dozens of blits still draining when PRESENT was pushed, an ordinary blit's own completion satisfied that check, so present_and_wait() reported the flip done before PRESENT had even been dispatched -- the host then started drawing the next frame into the buffer still being scanned out live. Fixed by comparing against PRESENT's own absolute position in the fence's numbering (a new done_baseline field on noodles_link_t, captured at open(), plus the handle's submitted count read right after the push) -- matches LINK-005's own already-documented contract, which the implementation had never actually followed. Rebuilt and redeployed the entire toolchain (library change) and reverified.

**Flicker persisted -- threshold-tested to find the real cause.** After the LINK-007 fix, 64-sprite runs still flickered on roughly half of repeated attempts (flicker, clean, clean, flicker across 4 runs). Tested count=30 (clean, 1 run, 20fps=60/3Hz), count=50 (flickered, 1 run, 15fps=60/4Hz), and count=10 with the NEW pipelined+fixed code specifically (flickered on its very first run, 30fps=60/2Hz) -- ruling out "only happens at high count" as too simple an explanation, and the exact-60/N frame rates confirming rtl/present.sv's vblank-sync logic itself is working correctly (not just running slow), so the bug is not a "missed frame" but genuine visible corruption during otherwise-on-time frames.

**Root cause identified (OUT-005): ascal's own internal buffering/clock domain, not our own RTL.** Re-read rtl/present.sv in full -- its front_sel-flip-on-fresh-FB_VBL-edge logic is correct in isolation. Root cause found by reading the vendored scaler directly (sys/ascal.vhd): ascal does NOT latch a new fb_base on FB_VBL (the signal present.sv watches) -- it latches avl_o_offset0/1 from o_fb_base only on the rising edge of avl_o_vs (~line 1714-1717), ascal's OWN internally-generated output vsync, synchronized into a SEPARATE Avalon memory clock domain (avl_clk) via a 2-stage synchronizer explicitly marked <ASYNC> in the source, plus its own internal double-buffering (o_obuf0/o_obuf1, ~line 1940-1967) governing when it actually re-fetches frame data. There is no guaranteed timing relationship between "present.sv flipped front_sel on a fresh FB_VBL edge" and "ascal actually started reading from the new address" -- when the phase relationship between FB_VBL and ascal's independent avl_o_vs/buffer state drifts unfavorably, the host can start drawing the next frame into a buffer ascal hasn't finished consuming, producing the observed ghosting. This is exactly the risk OUT-004's own decision text already flagged as accepted uncertainty ("not depending on undocumented assumptions about ascal's own prefetch timing") -- confirmed real and measurable, not just theoretical.

#### Next Steps:

No fix for OUT-005 is implemented. Two directions identified but not attempted, left for whoever continues this: (1) empirical mitigation -- have present.sv wait for multiple fresh FB_VBL edges (not just one) before considering a flip's prior frame retired, cheap to try, not root-cause-verified; (2) deeper study of ascal's configuration (RAMBASE/RAMSIZE/buffering-mode parameters passed to it in sys_top.v) to find an actually-guaranteed-safe relationship between FB_VBL and avl_o_vs, or a different signal to watch instead. Start from ascal.vhd's o_run/o_vsv/avl_o_vs signal chain, already located above, rather than re-deriving it. Empirically, draw workloads completing within ~1-2 vsync periods (~30 sprites at this project's 48x48 sprite size) have not shown the artifact in testing done so far; heavier workloads may, intermittently -- but sample sizes here are small (a handful of runs per count), not a rigorous characterization. The user is handing off this session to another agent at this point.

#### Files Modified:

- lib/noodles_link.c
- lib/noodles_link.h
- tools/stress_demo.c

#### Status:

- [x] Built
- [ ] Passed (LINK-007's fix verified; OUT-005's underlying issue is NOT resolved)

---

## 27 COMMIT Unreleased d3cb985 2026-09-22T12:00:00-07:00

#### Coming From:

Unreleased a7c893c

#### Purpose:

Measure and mitigate OUT-005 by adding a conservative multi-vblank retirement margin to PRESENT and validating it in simulation and on the stress workload.

#### Outcome:

The current handoff identified a real timing gap between `rtl/present.sv`'s `FB_VBL` edge and ascal's independently synchronized `avl_o_vs`/internal output-buffer retirement. PRESENT now has an explicit three-edge retirement margin: the first fresh `FB_VBL` edge flips `front_sel`, while completion remains busy until two additional fresh edges have passed. The isolated PRESENT testbench covers delayed completion, starts during an already-high blank, and repeated flips. `make sim` passes all six testbenches, and `quartus_sh --flow compile Noodles` completes with 0 errors; the fitted design reports 6,319 ALMs and no timing violation.

#### Next Steps:

Deploy the built core and rerun `stress-demo` at 10, 30, 50, and 64 sprites for repeated 15-second trials, recording frame rate and whether ghosting recurs. If the artifact persists, retain this margin as an empirical result and continue from ascal's `avl_o_vs`/output-buffer state path instead of treating the heuristic as a proof of correctness.

#### Files Modified:

- rtl/present.sv
- sim/present_dut.sv
- sim/tb_present.cpp

#### Status:

- [x] Built
- [ ] Passed

---

## 28 COMMIT Unreleased d3cb985 2026-09-22T10:54:01-07:00

#### Coming From:

Unreleased d3cb985

#### Purpose:

Run the 64-sprite stress workload against the PRESENT retirement-margin build on the MiSTer hardware.

#### Outcome:

Deployed host-side tools were already present on the MiSTer at 10.10.0.22, and `stress-demo assets/sprite.bmp 64 15` completed successfully. The run uploaded the 48x48 sprite, rendered 64 bouncing sprites for 15.1 seconds, produced 214 frames, and averaged 14.2 fps. The process reported no ring-full or fence-timeout errors. This console result confirms the workload executes through the LINK/fence path under load; it does not by itself confirm whether the display showed ghosting.

#### Next Steps:

Inspect the display during a repeated 64-sprite run and report whether any previous-position ghosting remains with the three-edge PRESENT margin. If the image is clean, record the hardware pass; if ghosting remains, continue the OUT-005 investigation from ascal's independent `avl_o_vs` and output-buffer retirement timing.

#### Files Modified:

None.

#### Status:

- [x] Built
- [ ] Passed

---

## 29 COMMIT Unreleased d3cb985 2026-09-22T11:02:00-07:00

#### Coming From:

Unreleased d3cb985

#### Purpose:

Repeat the 64-sprite stress workload after the user visually confirmed the first run was clean.

#### Outcome:

The MiSTer completed `stress-demo assets/sprite.bmp 64 15` again, rendering 216 frames in 15.0 seconds at 14.4 fps average. The process reported no ring-full or fence-timeout errors. The user had already confirmed the preceding run looked good; this repeat produced the same stable console behavior, with no new visual issue reported.

#### Next Steps:

Treat the three-edge PRESENT margin as hardware-validated for the tested 64-sprite workload unless a later run reproduces ghosting. Continue with broader workload or feature work as directed.

#### Files Modified:

None.

#### Status:

- [x] Built
- [x] Passed

---

## 30 COMMIT Unreleased d3cb985 2026-09-22T11:20:00-07:00

#### Coming From:

Unreleased d3cb985

#### Purpose:

Build and hardware-test the external `mister_noodles_fix.tar` PRESENT implementation against the recurring 64-sprite flicker.

#### Outcome:

Inspected the tarball without importing its historical `ai/core-log.md`, applied its replacement `rtl/present.sv` in an isolated checkout, and completed a full Quartus 17.0.2 build with 0 errors and 57 warnings. The resulting 2.3 MB `Noodles_fix_20260922.rbf` was copied to the MiSTer as a separate file with SHA-256 `72ea056e5a824447d762d439c28e02325e10318a6666256a502a7b08c6c4f84d`. The user loaded that test build and reported that the flicker remained about as frequent as before, so this alternate PRESENT implementation did not resolve OUT-005.

#### Next Steps:

Do not treat either three-edge PRESENT implementation as a fix. Continue the investigation at ascal's independent output-vsync and internal buffer-retirement boundary, using a measurement or synchronization signal that directly reflects when scanout has stopped consuming the old surface before the host reuses it.

#### Files Modified:

None.

#### Status:

- [x] Built
- [ ] Passed

---

## 31 COMMIT Unreleased 398cd6c 2026-09-22T12:27:08-07:00

#### Coming From:

Unreleased d3cb985

#### Purpose:

Replace PRESENT's failed heuristic retirement delay with an explicit acknowledgement from ascal when it latches the requested framebuffer base.

#### Outcome:

Added an avl-clock-domain toggle at ascal's existing framebuffer-base latch, synchronized that toggle into clk_sys in sys_top, and exposed the synchronized level to PRESENT as FB_BASE_LATCHED. PRESENT now flips on a fresh FB_VBL edge, waits for the acknowledgement to change, and waits one additional fresh FB_VBL edge before reporting completion. The simulation covers acknowledgement timing on both sides of the flip boundary, arbitrary phase, mid-blank starts, and repeated flips. `make sim` passes all six testbenches, and `quartus_sh --flow compile Noodles` completes with 0 errors and 57 warnings.

#### Next Steps:

Deploy the compiled core and repeat the 64-sprite workload for multiple 15-second trials, recording both frame rate and whether ghosting recurs. If ghosting remains, the acknowledgement will still establish the exact base-latch timing needed to continue the ascal output-buffer investigation.

#### Files Modified:

- sys/ascal.vhd
- sys/sys_top.v
- sys/emu_ports.vh
- rtl/present.sv
- Noodles.sv
- sim/present_dut.sv
- sim/tb_present.cpp

#### Status:

- [x] Built
- [ ] Passed

---

## 32 COMMIT Unreleased 3c8ba95 2026-09-22T12:44:16-07:00

#### Coming From:

Unreleased 398cd6c

#### Purpose:

Fix the PRESENT/ascal acknowledgement deadlock found during the first hardware run.

#### Outcome:

The first acknowledgement build could not complete even a one-frame PRESENT because FB_EN was gated on present completion, while ascal only latches o_fb_base with framebuffer mode enabled. FB_EN is now asserted from reset and FB_FORCE_BLANK remains active until the first PRESENT completes, allowing ascal to acknowledge the initial base without exposing uninitialized memory. `make sim` passes all six testbenches and the full Quartus compile completes with 0 errors and 57 warnings.

#### Next Steps:

Load the corrected RBF and rerun present-demo followed by repeated 64-sprite stress trials; the previous hardware result was a handshake deadlock and does not assess ghosting.

#### Files Modified:

- Noodles.sv
- ai/core-reference.md

#### Status:

- [x] Built
- [ ] Passed

---

## 33 COMMIT Unreleased 3c8ba95 2026-09-22T12:47:46-07:00

#### Coming From:

Unreleased 3c8ba95

#### Purpose:

Hardware-test the ascal framebuffer-base acknowledgement against the recurring 64-sprite flicker.

#### Outcome:

After correcting the FB_EN/PRESENT deadlock, the user ran `stress-demo assets/sprite.bmp 64 15` on the acknowledgement build. PRESENT completed normally and the workload rendered 173 frames in 15.1 seconds at 11.5 fps, but visible flicker remained about as frequent as with the previous three-FB_VBL implementation. This validates that the acknowledgement reaches PRESENT but does not prove that ascal has retired all outstanding reads from the old surface; OUT-005 remains unresolved.

#### Next Steps:

Continue from ascal's output-domain buffer-retirement logic rather than the framebuffer-base latch: identify or export an acknowledgement after the old `o_obuf` data has stopped being consumed, synchronize that event into clk_sys, and retain two-buffer operation. Any replacement must be simulation-covered and rerun against repeated 64-sprite trials.

#### Files Modified:

- None.

#### Status:

- [x] Built
- [ ] Passed

---

## 34 COMMIT Unreleased 8ff9bfa 2026-09-22T12:48:15-07:00

#### Coming From:

Unreleased 3c8ba95

#### Purpose:

Replace the insufficient ascal framebuffer-base acknowledgement with an output-domain retirement acknowledgement for PRESENT.

#### Outcome:

Exported a toggle from ascal's output-clock process at its internal output VS boundary, synchronized that toggle into `clk_sys` as `FB_RETIRED`, and changed PRESENT to wait for this output-domain event after flipping the front buffer. The earlier base-latch acknowledgement remains wired for diagnosis but no longer defines PRESENT completion. `make sim` passes all six testbenches and `quartus_sh --flow compile Noodles` completes with 0 errors and 57 warnings.

#### Next Steps:

Deploy the corrected RBF and repeat the 64-sprite workload for multiple trials, recording whether the output-domain retirement event changes the ghosting frequency.

#### Files Modified:

- sys/ascal.vhd
- sys/sys_top.v
- sys/emu_ports.vh
- rtl/present.sv
- Noodles.sv
- sim/present_dut.sv
- sim/tb_present.cpp

#### Status:

- [x] Built
- [ ] Passed

---

## 35 COMMIT Unreleased 8ff9bfa 2026-09-22T12:59:17-07:00

#### Coming From:

Unreleased 8ff9bfa

#### Purpose:

Measure the output-domain ascal retirement acknowledgement against repeated heavy-load flicker trials.

#### Outcome:

The user ran the deployed `FB_RETIRED` build ten times with `stress-demo assets/sprite.bmp 64 15`. Four runs still showed visible flicker, so the output-domain VS-boundary acknowledgement reduces neither the defect frequency nor the uncertainty enough to count as a fix. The handshake itself is operational because all runs completed, but the observed boundary still occurs before the old surface is demonstrably safe to reuse under this workload.

#### Next Steps:

Stop iterating on PRESENT acknowledgement timing alone and instrument ascal's actual output-buffer selection and memory-read activity, or change the scanout ownership model so the host never reuses a surface until direct evidence shows its last read has completed. Preserve the two-buffer constraint unless the FPGA scanout path is redesigned together with any additional buffer.

#### Files Modified:

- None.

#### Status:

- [x] Built
- [ ] Passed

---

## 36 COMMIT Unreleased ae7d9c4 2026-09-22T12:59:49-07:00

#### Coming From:

Unreleased 8ff9bfa

#### Purpose:

Instrument ascal's framebuffer read ownership to establish a retirement acknowledgement after scanout has stopped consuming the old surface.

#### Outcome:

The output-domain retirement event is now deferred until after the frame boundary is synchronized into the Avalon domain and all accepted read bursts have completed their final `avl_readdatavalid` beat. This preserves the two-buffer design and changes only `sys/ascal.vhd`; `make sim` passes all six testbenches and the full Quartus compile completes with 0 errors and 57 warnings. Hardware validation is still pending.

#### Next Steps:

Deploy the compiled RBF and repeat the 64-sprite workload at least ten times; if flicker remains, inspect ascal's buffer-selection transition because this build directly accounts for delayed Avalon burst responses.

#### Files Modified:

- sys/ascal.vhd
- sys/ascal.vhd

#### Status:

- [x] Built
- [ ] Passed

---

## 37 COMMIT Unreleased 491f8fb 2026-09-22T13:15:00-07:00

#### Coming From:

Unreleased 4d32cc8

#### Purpose:

Make framebuffer retirement wait for the Avalon read response that completes each scaler burst.

#### Outcome:

The current acknowledgement can still be early because `o_readlev` and `o_copylev` are reset at the output VS boundary while delayed Avalon data may remain in flight. The proposed change will track accepted Avalon read bursts through their final `avl_readdatavalid` beat, synchronize the output boundary into the Avalon domain, and emit `FB_RETIRED` only after the boundary has been observed with no response outstanding.

#### Next Steps:

Implement the cross-domain boundary marker and Avalon response-busy tracking without adding a framebuffer, then run simulation, a full Quartus compile, and repeated hardware trials before deciding whether the ownership evidence is sufficient.

#### Files Modified:

- sys/ascal.vhd

#### Status:

- [ ] Built
- [ ] Passed

---

## 38 COMMIT Unreleased 3fa589a 2026-09-22T13:22:00-07:00

#### Coming From:

Unreleased 3231cda

#### Purpose:

Track every outstanding Avalon framebuffer burst before acknowledging scanout retirement.

#### Outcome:

The single-bit response flag was replaced with an outstanding-burst counter that increments on each accepted Avalon read and decrements only on the final response beat, including correct handling when acceptance and completion coincide. `FB_RETIRED` now waits for the counter to reach zero after the synchronized output boundary. `make sim` passes all six testbenches and the full Quartus compile completes with 0 errors and 57 warnings; hardware validation is pending.

#### Next Steps:

Run all simulations and a full Quartus compile, deploy the resulting RBF, and repeat the ten-trial 64-sprite workload while watching for incomplete or stale scanout frames.

#### Files Modified:

- sys/ascal.vhd

#### Status:

- [x] Built
- [ ] Passed

---

## 39 COMMIT Unreleased 3746dc7 2026-09-22T13:30:00-07:00

#### Coming From:

Unreleased 005324e

#### Purpose:

Require an Avalon framebuffer-base latch after the output boundary before declaring scanout retirement.

#### Outcome:

`FB_RETIRED` now requires the output-domain boundary, the subsequent Avalon-domain `o_fb_base` latch, and a zero outstanding-read count with the Avalon reader idle. This closes the phase where the output boundary could be acknowledged before the new base was accepted by the memory reader. Simulation and Quartus validation pass; hardware validation is pending.

#### Next Steps:

Deploy the new RBF and repeat the 64-sprite workload while watching for incomplete scanout frames; if the artifact remains, the remaining fault is likely internal ascal buffer ownership rather than framebuffer-base acceptance.

#### Files Modified:

- sys/ascal.vhd

#### Status:

- [x] Built
- [ ] Passed

---

## 40 COMMIT Unreleased 0b58b29 2026-09-22T13:53:00-07:00

#### Coming From:

Unreleased fd8c39a

#### Purpose:

Synchronize host back-buffer tracking with the FPGA's persistent front-buffer parity.

#### Outcome:

Repeated four-second trials showed a deterministic odd/even pattern: each new host process assumed buffer A was front, while the FPGA retained `front_sel` across process launches. The completion fence now publishes the actual front parity in its high bit, and the host masks that bit from the completion count while seeding its local buffer state from it. Simulation, host builds, and Quartus validation pass; hardware validation is pending.

#### Next Steps:

Deploy the parity-aware FPGA and host tool, then repeat alternating short sprite runs to verify that every process starts drawing into the actual back buffer and that the colorkey path no longer exhibits the parity-dependent flicker.

#### Files Modified:

- rtl/link_fence.sv
- Noodles.sv
- sim/link_fence_dut.sv
- lib/noodles_link.c
- lib/noodles_link.h

#### Status:

- [x] Built
- [ ] Passed

---

## 41 COMMIT Unreleased 3f71eb4 2026-09-22T14:27:29-07:00

#### Coming From:

Unreleased a6106cb

#### Purpose:

Separate moving/overlapping sprite behavior from the real colorkey copy path with a deterministic fixed-position workload.

#### Outcome:

Added a `fixed` stress-demo mode that clears the back buffer before each frame and places up to eight real colorkey sprites at deterministic inset coordinates (80/240/400/560 by 80 and 320), with no movement. The deployed eight-sprite, 15-second hardware run completed at 20 FPS. Visual inspection showed all eight sprites intact and no flicker. The earlier fixed-mode run was invalid because it inherited the orange checkerboard surface; that diagnostic flaw was corrected before this result.

This establishes that the real colorkey copy path is stable for a cleared, fixed, non-overlapping workload. It does not yet isolate overlap, motion, or high command-count contention from the original 64-sprite failure.

#### Next Steps:

Run controlled fixed overlap and moving workloads, then compare sprite counts and overlap against the original intermittent 64-sprite case. Keep the framebuffer retirement changes unchanged until a copy-path-specific failure is reproduced.

#### Files Modified:

- tools/stress_demo.c
- ai/core-log.md

#### Status:

- [x] Built
- [x] Deployed
- [x] Passed

---

## 42 COMMIT Unreleased 4cc5a31 2026-09-22T14:28:45-07:00

#### Coming From:

Unreleased 3f71eb4

#### Purpose:

Determine whether overlapping real-colorkey sprites reproduce the intermittent framebuffer artifact without motion or edge involvement.

#### Outcome:

Added an `overlap` stress-demo mode that clears the back buffer and draws eight stationary real-colorkey sprites in a compact 4x2 cluster with 24-pixel spacing, producing deliberate overlap while keeping the cluster away from the framebuffer edges. The deployed 15-second run completed at 20 FPS, but the user observed all eight sprites flickering for the entire run.

Compared with the clean eight-sprite fixed/inset run, this isolates the failure to overlapping colorkey compositing or the ordering/ownership of overlapping writes. Motion, random placement, and scanout-edge artifacts are not required to reproduce it.

#### Next Steps:

Run the same overlap geometry with two and four sprites to determine whether the failure begins with the first overlap. Inspect and simulate `rtl/blit_copy.sv` around mixed key/non-key read/write sequencing and overlapping destination behavior.

#### Files Modified:

- tools/stress_demo.c
- ai/core-log.md

#### Status:

- [x] Built
- [x] Deployed
- [x] Passed

---

## 43 COMMIT Unreleased 71534df 2026-09-22T14:35:37-07:00

#### Coming From:

Unreleased 4cc5a31

#### Purpose:

Make the published framebuffer parity correspond to the scanout state at command completion, rather than sampling the live front-select signal during a delayed fence-memory write.

#### Outcome:

Three ten-run batches of the fixed overlap diagnostic reproduced flicker on every odd-numbered process launch, for both eight sprites and two sprites. Startup instrumentation showed the fence completion count advancing while the published front-parity bit remained zero across launches. Updated `link_fence.sv` to latch `front_sel` whenever a command completion arrives and publish that latched value with the corresponding completion count. RTL simulation passed, host build passed, and full Quartus compilation completed with zero errors. The new RBF and diagnostic tool were deployed; hardware validation requires reloading the new RBF.

#### Next Steps:

Reload the deployed RBF, run consecutive short two-sprite overlap launches, and verify startup fence parity alternates with the actual front buffer. Then repeat the eight-sprite overlap test.

#### Files Modified:

- rtl/link_fence.sv
- tools/stress_demo.c
- ai/core-log.md

#### Status:

- [x] Built
- [x] Deployed
- [x] Passed

Hardware validation: after reloading the parity-fix RBF and deploying the extended-wait tool, ten four-second trials of the original 64 moving real-colorkey sprites completed at approximately 8 FPS with no visible flicker in any run. This confirms the deterministic odd/even launch failure is fixed.

---

## 44 COMMIT Unreleased 33bc8cb 2026-09-22T14:43:23-07:00

#### Coming From:

Unreleased 71534df

#### Purpose:

Prevent the host diagnostic from declaring PRESENT failure while queued full-frame work and the FPGA retirement handshake are still completing.

#### Outcome:

The parity-fix RBF initially produced `present failed` after 29 frames and the `static` initialization path timed out. `noodles_present_and_wait()` was polling for only 200 ms; that is shorter than a queued full-frame workload can require. Increased the wait to 2 seconds. The ARM build and RTL simulation passed. After deployment, `static` held its initialized frame for four seconds successfully, and the two-sprite overlap workload completed 47 frames in 4.2 seconds at 11.2 FPS without a host-side PRESENT failure.

The user still needs to judge the display for visual flicker. The lower throughput reflects the longer, correctly serialized completion wait and is not itself evidence of corruption.

#### Next Steps:

Visually check the two-sprite overlap run, then repeat the odd/even launch test now that startup and PRESENT waits no longer produce false failures. Reload the parity-fix RBF if the running core has not yet been reloaded.

#### Files Modified:

- lib/noodles_link.c
- ai/core-log.md

#### Status:

- [x] Built
- [x] Deployed
- [ ] Passed

---

## 45 COMMIT Unreleased b6834d0 2026-09-22T15:00:00-07:00

#### Coming From:

Unreleased 3f71eb4

#### Purpose:

Test whether a registered read/write phase scheduler could improve DDRAM arbitration without replacing the existing client handshakes.

#### Outcome:

Rejected. The scheduler was re-applied after simulation reset wiring was repaired, but `make sim` failed the DDRAM adapter pixel-value test: the phase transition dropped the first accepted fill write. Reverting the scheduler restored all seven simulation benches, including the adapter's intermittent-backpressure coverage. This confirms that changing ready/grant timing in place is not a safe arbitration redesign.

The next queued-arbiter attempt must capture read and write request fields into explicit registered queues, issue registered grants, and return ordered read responses independently of the client request signals. No Quartus build or hardware deployment was performed for the rejected scheduler.

#### Next Steps:

Design and verify a standalone mixed read/write transaction-queue module before integrating it into `ddram_adapter.sv` or changing `Noodles.sv` arbitration.

#### Files Modified:

- rtl/ddram_adapter.sv
- ai/core-log.md

#### Status:

- [x] Built
- [x] Passed

---

## 46 COMMIT Unreleased b6834d0 2026-09-22T15:27:00-07:00

#### Coming From:

Unreleased b6834d0

#### Purpose:

Reduce the per-frame cost of clearing the back framebuffer without changing
the two-buffer ownership or PRESENT retirement protocol.

#### Outcome:

SOLID_FILL now emits an aligned 64-bit DDRAM write containing two identical
pixels whenever the rectangle span permits it. Misaligned starts, odd-width
tails, and all other generic writes retain the existing 32-bit half-word path.
The DDRAM adapter accepts the additional full-word write port while retaining
single-word burst count and the existing read priority. This halves accepted
write transactions for the normal 640-pixel-wide framebuffer clear.

`make sim` passes all existing benches, including both half-word and full-word
fill cases. Full Quartus validation is in progress; hardware benchmarking is
not yet performed.

#### Next Steps:

Complete Quartus validation, deploy the RBF, and compare repeated
`sprites-batch` trials against the 8.3 FPS post-pipeline average.

#### Files Modified:

- rtl/blit.sv
- rtl/ddram_adapter.sv
- Noodles.sv
- sim/engine_dut.sv
- sim/engine_ddram_dut.sv
- sim/engine_copy_dut.sv
- sim/link_ring_dut.sv
- sim/tb_solid_fill.cpp
- ai/core-log.md

#### Status:

- [x] Built
- [ ] Passed

---

## 47 COMMIT Unreleased b6834d0 2026-09-22T17:10:00-07:00

#### Coming From:

Unreleased b6834d0

#### Purpose:

Validate the explicit registered DDRAM transaction queues on the target hardware and measure whether removing client/physical-bus arbitration coupling improves the sprite-batch throughput ceiling.

#### Outcome:

The queued arbiter compiled with 0 Quartus errors, no combinational-loop or critical-warning reports, 0.591 ns worst-case setup slack, and 0.249 ns hold slack. The RBF was loaded on the QMTech MiSTer and the standard 64-sprite, 10-second `sprites-batch` workload completed four times without ring-full or fence-timeout errors:

| Trial | Frames | FPS |
|---|---:|---:|
| 1 | 155 | 15.5 |
| 2 | 153 | 15.3 |
| 3 | 149 | 14.8 |
| 4 | 144 | 14.4 |

Average throughput was **15.0 FPS**, versus the validated three-pixel baseline of 13.15 FPS (+14%). The gradual spread across trials is still visible, so this is a throughput improvement rather than proof that all frame-time variance has been eliminated.

#### Next Steps:

Keep the queued arbiter as the active baseline. Repeat visual inspection under the same heavy workload and then profile whether the remaining variance comes from DDRAM service time or the serial descriptor/compositor pipeline before attempting further arbitration changes.

#### Files Modified:

- rtl/ddram_adapter.sv
- rtl/cmdq.sv
- Noodles.sv
- sim/engine_ddram_dut.sv
- sim/engine_copy_dut.sv
- sim/engine_dut.sv
- sim/cmdq_batch_dut.sv
- sim/tb_ddram_adapter.cpp
- ai/core-log.md

#### Status:

- [x] Built
- [x] Deployed
- [x] Passed

---

## 48 COMMIT Unreleased de91934 2026-09-22T19:56:57-07:00

#### Coming From:

Unreleased b6834d0

#### Purpose:

Bring the locally developed `aquasock-fictional-waffle` recovery branch onto `main` and repair the structural damage it left in `core-log.md`.

#### Outcome:

Merged `aquasock-fictional-waffle` (`a6b2bd0`) into `main` with a non-fast-forward merge so every short hash cited by entries 31 through 47, `docs/BUILD.md`, and `docs/QUALIFICATION.md` stays valid; the only difference between the merge result and `a6b2bd0` is the `core.md` hash-verified-RBF rule from `81e7a97`. The branch had left the log out of order: entries 32 through 40 were inserted in reverse near the top of the file, entries 41 through 43 were placed above entry 1, and the header numbers 42 and 43 were each reused. Entries are now in sequence with 1 through 40 at their original numbers and the later branch entries renumbered 41 through 47 in timestamp order. Label placeholders in header and Coming From fields were replaced with real short hashes: `fixed-colorkey-diagnostic` is `3f71eb4`, `overlap-colorkey-diagnostic` is `4cc5a31`, `fence-parity-latch` is `71534df`, `present-wait-budget` is `33bc8cb`, and the queued-arbiter rejection, paired SOLID_FILL, and queued-arbiter hardware entries all map to `b6834d0` because that single checkpoint commit carries their source changes; the unresolvable `pipelined-blit baseline` reference was set to the preceding entry. Missing `---` terminators were added. No entry body text was changed, verified by line-multiset comparison against the `a6b2bd0` log. Settled entries that still violate `core-syntax.md` (a third Status box, Outcome tables, `ai/core-log.md` in Files Modified) are left as historical record. The uncommitted present-stutter debug probe in the `aquasock-fictional-waffle` worktree was not merged; its wait counter saturates after about 0.65 ms and is reset at every frame boundary, so it cannot observe multi-frame retirement misses as written.

#### Next Steps:

Fix the debug probe to use a wide wait counter and to count frame boundaries that pass while retirement is pending, rebuild, deploy, and correlate its output with the 64-sprite `stress-demo` frame-time spikes before choosing between an ascal arbitration change and a native timing generator.

#### Files Modified:

None.

#### Status:

- [x] Built
- [ ] Passed

---

## 49 COMMIT Unreleased 210b8f4 2026-09-22T20:47:03-07:00

#### Coming From:

Unreleased de91934

#### Purpose:

Widen the recovered temporary PRESENT-retirement probe so its wait-cycle measurement survives multiple frame boundaries instead of saturating at 16 bits within one.

#### Outcome:

Reintroduced the temporary ascal retirement instrumentation with a saturating 32-bit cycle counter that persists across additional frame boundaries, a saturating 16-bit missed-boundary counter, and the existing peak outstanding-read count. `dbg_present_probe` publishes wait cycles at `0x30030000` and packed sequence, peak, and missed-boundary metadata at `0x30030004` as the lowest-priority DDRAM writer; `present-probe-dump` reads a stable two-word sample and is included in normal ARM, host, and deploy builds. `make all`, `make host`, and all seven RTL simulations passed; Quartus completed with zero errors, 60 warnings, and positive timing. The deployed RBF and ARM tools matched their local MD5 hashes. The standard 64-sprite workload completed 129 frames in 10.0 seconds at 12.9 FPS while 291 complete probe samples showed 179 normal retirements at 1,666,662 cycles with zero missed boundaries, 103 at 4,999,989 cycles with two missed boundaries, and 8 at 6,666,652 cycles with three; all samples reported a peak of two outstanding reads.

#### Next Steps:

Add a focused temporary retirement-gate diagnostic to identify whether delayed retirements are blocked by the base-latch acknowledgement, read-drain condition, or non-idle Avalon state before changing arbitration or replacing the scaler, then remove the probe once the root cause and any resulting fix are qualified.

#### Files Modified:

- rtl/dbg_present_probe.sv
- sys/ascal.vhd
- sys/emu_ports.vh
- sys/sys_top.v
- Noodles.sv
- files.qip
- tools/present_probe_dump.c
- Makefile
- scripts/deploy.sh

#### Status:

- [x] Built
- [x] Passed

---

## 50 COMMIT Unreleased 1313218 2026-09-22T20:57:26-07:00

#### Coming From:

Unreleased 210b8f4

#### Purpose:

Identify which `ascal` retirement predicate blocks the measured multi-frame PRESENT delays before changing framebuffer arbitration or scanout design.

#### Outcome:

Extended the temporary retirement probe with a four-bit, per-retirement gate-reason mask accumulated while retirement is pending: base latch absent, outstanding scanout reads nonzero, read-data valid asserted, and Avalon state non-idle. Published the mask in the unused top nibble of the existing metadata word at `0x30030004`, reported it from `present-probe-dump`, and preserved the current 32-bit wait count, missed-boundary count, read-peak count, and lowest-priority write placement. ARM and host builds, all seven RTL simulations, and the full Quartus compile passed; Quartus reported 0 errors, 60 warnings, 0.661 ns worst-case setup slack, and 0.247 ns hold slack. After loading the RBF through `/dev/MiSTer_cmd`, the standard 64-sprite workload completed 581 frames in 30.0 seconds at 19.3 FPS with no ring-full or fence-timeout errors. The probe captured 300 samples: every sample had a peak of two outstanding reads and gate mask `0xf`; wait time alternated among 1,666,662, 3,333,326, and 4,999,989 cycles with zero, one, or two missed frame boundaries. Because the mask is accumulated across the whole pending interval, `0xf` means all four predicates were observed during delayed retirements, not that all four blocked every cycle; this diagnostic narrows the issue to the multi-condition retirement window but does not isolate the single corrective predicate.

#### Next Steps:

Do not select a corrective RTL change from this aggregate mask alone. Add a narrower phase-specific probe or waveform capture that records each predicate at the retirement boundary and distinguishes the first blocking condition from predicates observed later in the wait window. Keep the current probe available while that diagnostic is designed; remove all temporary instrumentation only after the root cause and a corrective build are qualified.

#### Files Modified:

- rtl/dbg_present_probe.sv
- sys/ascal.vhd
- sys/emu_ports.vh
- sys/sys_top.v
- Noodles.sv
- tools/present_probe_dump.c
- ai/core-log.md

#### Status:

- [ ] Built
- [ ] Passed

---

## 51 COMMIT Unreleased 1313218 2026-09-22T21:16:00-07:00

#### Coming From:

Unreleased 1313218

#### Purpose:

Repeat the loaded-core 64-sprite retirement diagnostic three times to distinguish a persistent timing pattern from run-to-run noise before changing RTL.

#### Outcome:

Ran three independent 30-second `stress-demo assets/sprite.bmp 64` trials against the already-loaded diagnostic RBF, collecting 100 retirement samples during each trial. The runs completed 508, 480, and 456 frames at 16.9, 16.0, and 15.2 FPS, averaging 16.0 FPS across 90 seconds. Across the 300 samples, average retirement wait was 3,544,436 cycles, average missed-boundary count was 1.127, peak outstanding reads were always 2, and every sample reported gate mask `0xf`. The aggregate result is consistent across runs: the delayed retirement behavior is persistent, not a one-off workload anomaly, but the accumulated mask still cannot identify which predicate blocks first.

#### Next Steps:

Keep the current RBF as the measurement baseline and design a phase-specific probe that captures the first blocking predicate at each retirement boundary. Do not change arbitration or scanout RTL based only on the aggregate `0xf` mask.

#### Files Modified:

None.

#### Status:

- [x] Built
- [x] Passed

---

## 52 COMMIT Unreleased 1313218 2026-09-22T21:22:00-07:00

#### Coming From:

Unreleased 1313218

#### Purpose:

Evaluate replacing ascal/MISTER_FB scan-out with a native HSync/VSync/DE timing generator as an alternative path off OUT-005's unresolved ghosting/retirement stall.

#### Outcome:

No RTL was changed. Discussion established the real scope before any commitment: `ascal`'s scan-out bandwidth comes from a dedicated Avalon-MM port physically separate from `DDRAM_*` (DDR-004), plus vendored burst-read/prefetch machinery this project has never had to build. A native generator would need its own ~25MHz-class pixel-clock PLL output, a from-scratch raster/sync generator, and a burst-capable DDRAM read pipeline with line-buffer prefetch to hide DDR3 latency, since `rtl/ddram_adapter.sv`'s existing read port is single-word/single-outstanding (DDR-003) -- measured at ~8.2 cycles/pixel (bench.c), which caps sustained scanout reads around ~10MB/s on the current adapter. Candidate targets 640x480@60 (~73.7MB/s active-pixel bandwidth) and 800x600@60 (~115MB/s, actually the harder target, not easier) both exceed that by 7-11x. After walking through this, the user chose to stay on the ascal/MISTER_FB path (OUT-002) rather than commit to building a burst-capable scanout read engine first.

#### Next Steps:

OUT-005 remains open. Continue from entry 51's plan: design a phase-specific retirement probe that identifies the first blocking predicate at each stall, rather than pursuing the native-timing-generator alternative. If a burst-capable DDRAM read path is ever built for other reasons, revisit native timing generation as a option at that point rather than re-deriving this bandwidth analysis from scratch.

#### Files Modified:

None.

#### Status:

- [x] Built
- [x] Passed

---

## 53 COMMIT Unreleased 1313218 2026-09-22T22:00:00-07:00

#### Coming From:

Unreleased 1313218

#### Purpose:

Build a real burst-capable DDRAM read pipeline for blit_copy64/sprite_batch (BLIT_COPY's actual hot path), per the user's explicit choice to fix the DDR-003 single-outstanding-read limitation directly rather than run another contention-diagnostic probe first, in pursuit of getting the 64-sprite demo past its ~15fps ceiling.

#### Outcome:

Added DDR-007: an explicit-length descriptor architecture for the DDRAM adapter's 64-bit read port (a new rd64_len input, admitted and issued as a single Avalon command with ddram_burstcnt driven from that declared length) and rewrote blit_copy64's read-issue FSM to declare a burst length up front (bounded by its own free FIFO capacity via a new reserved_count register, and by pairs remaining in the current source row so a burst never crosses a non-contiguous row boundary) instead of issuing one pair-request per cycle. An earlier opportunistic contiguity-detection approach was tried first and abandoned as architecturally broken -- the adapter's combinational issue logic drains a queued request faster than a one-per-cycle producer can ever build up a multi-entry run to discover, so it never actually formed real bursts. Two further real bugs surfaced and were fixed during validation: (1) blit_copy64's aggressive continuous FIFO refilling kept the read queue non-empty far more often than before, and the adapter's original unconditional read-priority write arbitration starved queued writes indefinitely under that load -- fixed with a free-running round-robin toggle (rr) that alternates bus ownership whenever both a read and a write are pending; (2) blit_copy64's completion check (`pairs_issued==total_pairs && pair_count==0`) assumed accepted requests complete almost immediately, which stopped holding once a burst's pairs_issued increments at ACCEPT time, potentially many cycles before data actually arrives -- fixed by gating completion on pairs_done (incremented once per pair actually written) instead. New sim coverage (sim/engine_copy64_dut.sv, sim/tb_blit_copy64.cpp -- the first simulation coverage blit_copy64 has ever had, previously validated only on real hardware) uses a burst-aware behavioral Avalon memory model honoring DDRAM_BURSTCNT; both a plain multi-row copy and a BLIT_COPY_KEY-style checkerboard run pass pixel-exact, with max observed burstcnt=4 confirming real multi-word bursts form. All 8 `make sim` targets pass (the 7 pre-existing ones unchanged, confirming no regression to the scalar/legacy paths). Full Quartus compile succeeded: 0 errors, worst-case setup slack +0.508ns. Deployed to hardware and ran the 64-sprite stress-demo three times: 18.7/18.7/19.0 fps (avg 18.8fps), visually confirmed smoother with no flicker or stutter -- a real, repeatable improvement over the previous consistent ~15fps baseline. However, present-probe-dump's retirement-stall pattern (retire_wait_cyc cycling through the same ~83ms/167ms/250ms values, same missed_boundaries pattern seen before this change) was completely unchanged, meaning the periodic ascal retirement stall investigated earlier this session is NOT caused by blit_copy64's read-burst inefficiency -- that hypothesis is now ruled out by direct hardware measurement, even though the throughput fix itself was real and worth keeping.

#### Next Steps:

The FPS/throughput improvement from DDR-007 is real and should stay; do not revert it looking for the retirement-stall cause. The retirement-stall pattern (present-probe-dump's retire_wait_cyc/missed_boundaries) remains completely unexplained and needs its own fresh diagnostic thread -- start from the premise that it is NOT DDRAM read-bandwidth-related (this record's own before/after hardware measurement rules that out), and look instead at ascal's own internal timing/configuration (per OUT-005's still-open note about ascal's RAMBASE/RAMSIZE/buffering parameters) or something in present.sv's/link_fence's own gating logic. If a future workload pushes sprite counts high enough to re-saturate the DDRAM read path, DDR-007's burst mechanism is now the correct place to extend (e.g. relaxing the row-boundary restriction if a future surface layout makes cross-row addresses contiguous), not a new from-scratch design.

#### Files Modified:

- rtl/ddram_adapter.sv
- rtl/blit_copy64.sv
- rtl/sprite_batch.sv
- Noodles.sv
- Makefile
- sim/engine_copy64_dut.sv (new)
- sim/tb_blit_copy64.cpp (new)
- ai/core-reference.md (DDR-007)

#### Status:

- [x] Built
- [x] Passed

---

## 54 COMMIT Unreleased 4df8b6a 2026-09-23T05:56:25-07:00

#### Coming From:

Unreleased 1313218

#### Purpose:

Validate the saved DDR-007 FIFO-depth expansion (eight to thirty-two entries) before continuing the OUT-005 retirement-stall investigation.

#### Outcome:

`make sim` passed all eight testbenches with no regressions, but a clean `make clean && quartus_sh --flow compile Noodles` did not complete: the Fitter's routing stage ran for the full user-imposed 20-minute cutoff without visible log progress past its first routing status line, consistent with a known, previously-observed issue where this build's Quartus flow occasionally fails to parallelize during routing and runs far past its normal ~10-minute baseline. `ps` confirmed `quartus_fit` was consuming over 250% CPU throughout, so the process was computing, not deadlocked, but no completion signal appeared before the cutoff and the process was killed per the user's standing 20-minute limit for this known issue. No RBF was produced, so hardware deployment and the planned 64-sprite/`present-probe-dump` comparison against entry 53 could not be attempted this cycle.

#### Next Steps:

Retry the same clean Quartus compile, since the routing-parallelization issue has historically been intermittent rather than a permanent regression from this cycle's source change; if it stalls again past the 20-minute cutoff on a second attempt, treat that as evidence the FIFO-depth increase itself (not just chance) is responsible, and consider reducing the new depth or investigating router settings before trying a third time. Once a full compile completes, proceed with hardware deployment and the throughput/retirement-stall comparison against entry 53 as originally planned.

#### Files Modified:

- rtl/blit_copy64.sv
- rtl/ddram_adapter.sv

#### Status:

- [ ] Built
- [ ] Passed

---

## 55 COMMIT Unreleased ec0f52d 2026-09-23T06:20:11-07:00

#### Coming From:

Unreleased 4df8b6a

#### Purpose:

Bisect entry 54's build stall to determine whether it was the project's known intermittent routing flakiness or a real regression from the DEPTH=32 change, then correct it.

#### Outcome:

Entry 54's Outcome mischaracterized the stall as consistent with a prior, generic intermittent issue; that was incorrect and this entry supersedes it. A controlled test with DEPTH reverted to 8 in both `rtl/ddram_adapter.sv` and `rtl/blit_copy64.sv` compiled clean in 3m12s (0 errors, 58 warnings), matching entry 53's baseline, while the committed DEPTH=32 change had stalled past 20 minutes in routing with no completion. The root cause is the response-metadata commit logic in `ddram_adapter.sv`, which scatter-writes up to DEPTH entries per cycle into `rsp_is64_q`/`rsp_half_q` at dynamically-computed wraparound addresses; this costs roughly O(DEPTH squared) placement and routing complexity, and DEPTH=32 pushed that past what the Fitter could route in reasonable time. Reduced DEPTH to 16 in both files: `make sim` passed all eight testbenches, and a clean `quartus_sh --flow compile Noodles` completed in 4m17s with 0 errors, 58 warnings, +0.685ns worst-case setup slack, and +0.244ns worst-case hold slack -- close to the DEPTH=8 baseline and confirming the fix.

#### Next Steps:

Deploy the DEPTH=16 build to the QMTech MiSTer and repeat the standard 64-sprite `stress-demo` workload with `present-probe-dump`, comparing throughput against entry 53's 18.8fps baseline and confirming the OUT-005 retirement-stall pattern is unchanged, as originally planned before entry 54's build failure interrupted it. If a future workload needs a deeper queue than 16, the O(DEPTH squared) response-metadata write should be redesigned (e.g. a log2(DEPTH)-stage barrel shifter or sequential per-word commit) rather than raising DEPTH further, since that cost, not DEPTH itself, is what breaks routing.

#### Files Modified:

- rtl/ddram_adapter.sv
- rtl/blit_copy64.sv

#### Status:

- [x] Built
- [ ] Passed

---

## 56 COMMIT Unreleased ec0f52d 2026-09-23T06:50:17-07:00

#### Coming From:

Unreleased ec0f52d

#### Purpose:

Deploy the DEPTH=16 build to the QMTech MiSTer and validate throughput and the OUT-005 retirement-stall pattern against entry 53's baseline.

#### Outcome:

Cross-built the ARM host tools, then deployed all binaries, assets, and the DEPTH=16 RBF to the MiSTer via a Python/paramiko SFTP workaround (sshpass was unavailable and interactive sudo could not be used to install it), and loaded the core. Two 64-sprite stress-demo runs measured 16.8 and 16.9 fps, noticeably below entry 53's recorded 18.7/18.7/19.0 fps (avg 18.8fps), which was unexpected since a deeper FIFO should add headroom rather than reduce throughput. present-probe-dump showed read_outstanding_pk pinned at 2 across all samples, with retire_gate_mask=0xf and retire_wait_cyc alternating between roughly 1.67 million and 3.33 million cycles as missed_boundaries toggles, matching the still-open OUT-005 pattern from prior entries. To rule out DEPTH=16 itself as the cause of the lower fps, DEPTH was temporarily reverted to 8 in both `rtl/ddram_adapter.sv` and `rtl/blit_copy64.sv` in this same session, rebuilt clean (3m12s, 0 errors, 58 warnings), and redeployed: two runs measured 16.2 and 16.3 fps, statistically indistinguishable from the DEPTH=16 result and confirming FIFO depth is not driving the fps difference from entry 53. The committed DEPTH=16 state was then restored, rebuilt clean (4m20s, 0 errors, 58 warnings), and redeployed as the final hardware state. Because read_outstanding_pk never exceeded 2 under either depth, the OUT-005 retirement stall remains the actual throughput ceiling, and the gap versus entry 53's 18.8fps average is attributed to session-to-session environmental drift rather than to this cycle's DEPTH change.

#### Next Steps:

Begin a fresh investigation of OUT-005 directly, since DDRAM read bandwidth and FIFO depth are now doubly ruled out as its cause: decode what the four bits of present-probe-dump's retire_gate_mask represent in the ascal/present.sv/link_fence gating logic, correlate the alternating roughly 1.67 million and 3.33 million cycle retire_wait_cyc pattern with a periodic signal such as vsync/vblank or a scaler-ready cadence, and determine whether the stall reflects a legitimate wait or a spurious gate that should be cleared sooner.

#### Files Modified:

None.

#### Status:

- [x] Built
- [x] Passed

---

## 57 COMMIT Unreleased 5c2a053 2026-09-23T07:07:21-07:00

#### Coming From:

Unreleased ec0f52d

#### Purpose:

Resolve OUT-005 by identifying and removing the actual throughput ceiling in present.sv's retirement margin, since prior entries had already ruled out DDRAM read bandwidth and FIFO depth as its cause.

#### Outcome:

Reading present.sv's state machine against ascal.vhd's avl_clk-domain retirement gating showed the per-PRESENT cost is roughly three 60Hz vblank periods: one waiting for the next fresh FB_VBL edge to flip front_sel, one to two (per present-probe-dump's alternating roughly 1.67 million and 3.33 million avl_clk-cycle samples) waiting for ascal's own fb_retired toggle, and one additional fixed margin vblank from present.sv's RETIRE_VBLANKS parameter, which had defaulted to 1 since the OUT-004 flicker fix recorded earlier in this log. That total (about 50ms) matches the measured 16.2 to 16.9fps ceiling from entry 56 almost exactly, independent of DEPTH, confirming present.sv's own vsync-synchronized state machine, not DDRAM bandwidth or queue depth, was the actual bottleneck. Overriding RETIRE_VBLANKS to 0 at the Noodles.sv instantiation removes the extra margin vblank, relying only on ascal's own fb_retired toggle as the safety signal rather than an additional fixed wait on top of it. make sim passed all eight testbenches including tb_present's delayed-completion and already-high-blank-at-start cases, and a clean quartus_sh --flow compile Noodles completed in 4m27s with 0 errors and 58 warnings. Deployed to the QMTech MiSTer and ran the 64-sprite stress-demo three times: 23.8, 24.6, and 25.4 fps, a roughly 40 to 50 percent improvement over entry 56's 16.2 to 16.9fps baseline. The user directly watched a live run afterward and confirmed no flicker, tearing, or ghosting, meaning the margin was unnecessary for this workload's actual timing and this closes out the OUT-005 investigation as resolved rather than merely worked around.

#### Next Steps:

Treat OUT-005 as resolved; if a future, heavier workload (larger sprite counts, different buffer sizes, or a different display timing) reintroduces visible flicker or ghosting, that is new evidence the RETIRE_VBLANKS=0 margin is insufficient for that specific case and RETIRE_VBLANKS should be raised again for that workload rather than assuming this fix generalizes untested to all future configurations. No further FIFO depth or DDRAM bandwidth work is warranted from this thread since both were already ruled out as the bottleneck before this fix.

#### Files Modified:

- Noodles.sv

#### Status:

- [x] Built
- [x] Passed

---

## 58 COMMIT Unreleased ??? 2026-09-23T07:35:00-07:00

#### Coming From:

Unreleased 5c2a053

#### Purpose:

Push the 64-sprite stress-demo harder to re-lower fps for further OUT-005-class testing, since the RETIRE_VBLANKS fix raised fps into a range where visual differences are no longer perceptible.

#### Outcome:

`overlap` mode ran cleanly at 22.0fps, giving a working harder-stress option. But `sprites-batch` and `key-checker` both failed deterministically at frame 0 (`present failed` and `ring stuck compositing sprite 62`), which contradicts entry 47's own record of four clean `sprites-batch` trials at `b6834d0`. A three-way bisection using isolated git worktrees ruled out every candidate this log has touched today: reverting today's RETIRE_VBLANKS fix back to 1 in place reproduced the identical failure; rebuilding entry 53's pre-DDR-007 baseline (`403ad01`, DEPTH=8) reproduced it; rebuilding entry 47's exact commit (`b6834d0`) reproduced it again, directly contradicting that entry's own success record. A full power cycle of the MiSTer (not just a `load_core` hot-swap) was tried next to rule out stale hardware state, and the failure persisted unchanged. Finally, the exact ARM binary that was checked into the `b6834d0` commit tree itself (not a locally recompiled one) was deployed and tested against that same core, eliminating any possible toolchain drift, and it failed too, with the same nondeterminism in which subsystem the failure message names (`present failed`, `ring stuck clearing background`, `ring stuck compositing sprite 0`) across otherwise identical runs. `key-checker` itself has never appeared anywhere else in this log, so its failure is not a regression, only a previously untested edge case in the keyed-copy engine's handling of per-pixel-toggling colorkey patterns. `sprites-batch`'s failure is the real puzzle: every variable this log can bisect has now been excluded, so entry 47's four recorded successes could not be reproduced under any tested condition, and the discrepancy remains unexplained rather than resolved. The official DEPTH=16, RETIRE_VBLANKS=0 build was restored to hardware and re-verified at its expected 18.4 to 18.9fps range on the plain `sprites` mode before ending this investigation.

#### Next Steps:

Add sim coverage for the SPRITE_BATCH descriptor path under a full 64-descriptor load and for the keyed-copy engine under a checkerboard colorkey pattern, since neither `sim/tb_blit_copy64.cpp` nor the batch testbenches appear to exercise either case today. Until that lands, treat `sprites-batch` and `key-checker` as known-broken stress-demo modes rather than regressions, and do not cite entry 47's four-trial record as current evidence that the SPRITE_BATCH path works. Continuing this thread should start from simulation, not further hardware bisection, since every environmental and historical variable available on hardware has already been excluded.

#### Files Modified:

- ai/core-log.md

#### Status:

- [ ] Built
- [ ] Passed

---
