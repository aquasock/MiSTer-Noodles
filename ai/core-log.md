## 1 COMMIT Unreleased 6ebd0fd 2026-09-23T21:39:52-07:00

#### Coming From:

Unreleased 5f35d98

#### Purpose:

Hand off the accepted project state after the user archived the previous core-log.md as `ai/archived_logs/core-log_23-09-2026.md` in rollover commit `79cf833`.

#### Outcome:

The previous log closed at entry 96 with every cycle resolved and no open proposal. The accepted hardware baseline is the fixed 800x600 SVGA Stage 2B core at 100MHz built from source `6b9ff63` with seed 13, RBF SHA256 `d217d48ed33ea0010f56c31ad1626f99918d306d1a5f2b709ad4d384b4efeaa2`, deployed on the MiSTer at 10.10.0.22 as `/media/fat/pet/Noodles_2b_fix_seed13.rbf`. It provides protocol 1.0 live identity and sessions, SOLID_FILL, BLIT_COPY, BLIT_COPY_KEY, PRESENT, SPRITE_BATCH and LOAD_SDRAM. The accepted host baseline is SDK source `7d4b259`, which adds SDK 0.3 managed surfaces in a 224MiB DDR3 arena, a generic fixed-cell texture cache with the pacing fixes from `6acc2f2` and `45566e8`, and a 20us-to-0.1ms fence-wait backoff. On hardware, the canonical 64-sprite one-batch 128x128 `blit-bench` averaged 77.41 Mpixel/s, the 256-sprite four-batch workload ran at 15.1fps and the tile-cache demo held 60.2fps; the user visually accepted each. The standard `stress-demo` and `tile-cache-demo` on the MiSTer come from `7d4b259`, older binaries and RBFs are preserved beside them as fallbacks, and other deployed tools still use the earlier SDK wait policy. RTL changes must pass the four-corner timing gate, and performance comparisons should use controlled builds across three distinct seeds. The blit engines support colorkey transparency but no alpha blending, tinting, scaling or flipping. The planned first consumer is GemRB v0.9.5 through SDL2 2.32.10.

#### Next Steps:

Scope alpha blending as the next generic 2D rendering capability, keeping the accepted image and tools unchanged until a qualified replacement is accepted.

#### Files Modified:

None.

#### Status:

- [x] Built
- [x] Passed

---

## 2 COMMIT Unreleased 1d4957f 2026-09-23T21:41:35-07:00

#### Coming From:

Unreleased 6ebd0fd

#### Purpose:

Add single-command straight-alpha source-over blending as opcode 7 BLIT_BLEND with SDK support.

#### Outcome:

Reference records BLIT-007 and LINK-012 define the blend and protocol 1.1, superseding LINK-011, with arithmetic taken from SDL 2.32.10's generic truncating /255 path, since SDL's unmodulated fast path uses a >>8 approximation, and implemented with the exact identity D(x) = (x + 1 + (x >> 8)) >> 8. Source `1d4957f` adds `blend_px`, `blend_walk` and the `blit_blend` burst engine without modifying `blit_copy64`, plus CMDQ opcode 7, protocol 0x00010001 with mask 0xfe, and SDK 0.4 raw, surface and texture-cache blend calls that accept any 1.x core and return ENOTSUP without the capability. Engine simulation exposed a real hazard: with tightly packed rows, one 64-bit word can hold two rows' edge pixels, so full-word read-modify-write could restore a stale lane; single-lane edge words now use the 32-bit write port. The exhaustive datapath test matched all 16842752 vectors, the randomized engine test with bus stalls and variable latency passed 1500 rectangles plus fixed cases, all 36 simulations, host and sanitizer tests, installed consumers and ARM builds passed, and Quartus synthesis used 51 of 112 DSP blocks. Clean GitHub builds with seeds 13, 5 and 7 failed setup at the slow corners with worst slack -0.389, -0.404 and -0.596ns; hold, recovery, removal and pulse width passed. The failing paths run from the fill engine's column compare through the top-level write-port select into `blit_copy64`, not through the blend engine. At the user's explicit request the best seed-13 image, SHA256 `3d6763813453ebc1304f34a2b2f7b706ca02dade68a202813eef8cedf3b2c869`, was deployed as `Noodles_blend_seed13_TIMING_VIOLATED.rbf` with hash-verified `-blend` tools. On the accepted protocol-1.0 core, SDK 0.4 verified, refused blending, and matched baseline benchmarks. On the blend image, hardware readback of 10 cases and 24671 blended pixels was bit-exact, blending measured 56.66 Mpixel/s, `blit-bench` gave 73.94, 78.48 and 81.58 Mpixel/s, the 256-sprite workload held 15.1fps, the tile cache 60.2fps and the blend demo 60.3fps, without errors or timeouts. The user reported that the blended sprites looked perfect and explicitly waived the timing violations for now; Passed records that hardware and visual acceptance, not timing qualification.

#### Next Steps:

Keep the accepted `6b9ff63` image as the timing-qualified fallback while the blend image remains a timing-waived diagnostic baseline. Close the write-port select timing path before this work is released, and scope the next GemRB-driven capability from the review of GemRB v0.9.5's SDL2 renderer.

#### Files Modified:

- Makefile
- Noodles.sv
- files.qip
- rtl/blend_px.sv
- rtl/blend_walk.sv
- rtl/blit_blend.sv
- rtl/cmdq.sv
- rtl/link_control.sv
- sim/blend_ref.h
- sim/cmdq_batch_dut.sv
- sim/engine_blend_dut.sv
- sim/engine_copy_dut.sv
- sim/engine_ddram_dut.sv
- sim/engine_dut.sv
- sim/tb_blend_px.cpp
- sim/tb_blit_blend.cpp
- sim/tb_cmdq_batch.cpp
- sim/tb_link_control.cpp
- sim/test_noodles_link.c
- sim/test_noodles_sdk.c
- sim/test_sdk_install.sh
- lib/noodles.pc.in
- lib/noodles_link.c
- lib/noodles_link.h
- lib/noodles_link_internal.h
- lib/noodles_surface.c
- lib/noodles_surface.h
- tools/blend_demo.c
- scripts/deploy.sh
- docs/INTEGRATION.md
- docs/SDK.md

#### Status:

- [x] Built
- [x] Passed

---

## 3 COMMIT Unreleased 0b48215 2026-09-23T22:25:51-07:00

#### Coming From:

Unreleased 1d4957f

#### Purpose:

Add per-descriptor blend, mirror and colour/alpha modulation to SPRITE_BATCH and close the write-port timing violation left by entry 2.

#### Outcome:

Reference records BLIT-008 and LINK-013 define descriptor flag bits 1-3 for blending and horizontal and vertical mirroring, with the colour-key word as an RGBA modulation and SDL 2.32.10's generic colour and alpha modulation arithmetic, advertised as protocol 1.2. The blend engine gained colour modulation, a plain-store mode, burst-reversed horizontal and row-reversed vertical mirroring and colour keys, `sprite_batch` dispatches to it and drains the adapter around its draws, and SDK 0.5 adds flagged surface and texture-cache batches with mirror-aware clipping. While building the mixed-batch test, the accepted `blit_copy64` was found to leave odd widths' last column uncopied, hang from the second row on and misread sources that are not 8-byte aligned, reproducible with the unmodified pre-cycle RTL; at the user's choice of option A, `sprite_batch` now sends it only even-width copies with 8-byte-aligned source address and pitch and routes all others to the blend engine. Write clients now take their ready from the adapter's registered queue space and their own requests. Source `ce924b8` failed setup on seeds 13, 5 and 7 by 1.1 to 1.8ns, entirely from the blend engine's block-RAM tag FIFO into its pixel FIFO; `0b48215` keeps the tags in registers and registers each response beat, bringing seeds 13, 7 and 5 to worst setup of -0.071, -0.150 and -0.380ns at slow -40C with hold and fast corners passing. The remaining small paths are in `blend_walk` request formation, `blit_copy64` destination-address arithmetic and the `link_control` read request into the adapter queue. Simulation passed the 33.8M-vector datapath test, 4000 randomized engine rectangles and 320 overlapping descriptors in eight mixed batches against a sequential model, with mutations of the mirror and clipping logic detected, plus all 37 simulations, host, sanitizer and installed-consumer tests and a brute-force mirrored clipping check. The user directed that seed 13, RBF SHA256 `bb142a6e6ee81bdc5b8a61092cdc2903146bdf737f2ac91dfc0f0858ae26badf`, be treated as passing for testing; it was deployed as `Noodles_batch_seed13_TIMING_VIOLATED.rbf` with hash-verified tools and reported protocol 0x00010002. Hardware readback was bit-exact for 10 single-command cases and 12 rounds of 576 overlapping batched draws, 282 of them flagged and including rerouted odd and unaligned copies; blending measured 61.05 Mpixel/s single and 61.04 batched, `blit-bench` 76.65, 76.63 and 77.44 Mpixel/s, the 256-sprite workload 15.1fps and the tile cache 60.2fps. After host-only commit `5de85a5` replaced the symmetric demo sprite with an arrow, the batched demo ran at 60.3fps and the user confirmed that mirroring, tinting, blending and edge clipping all passed.

#### Next Steps:

Close the remaining slow -40C setup paths in `blend_walk` request formation, `blit_copy64` address arithmetic and the `link_control` read request, verifying with a local fit and four-corner gate before publishing, then rebuild three seeds. Then continue the GemRB-driven work with the factor-based blend mode unit, designed to share the existing DSP multipliers.

#### Files Modified:

- Noodles.sv
- rtl/ddram_adapter.sv
- rtl/blend_px.sv
- rtl/blend_walk.sv
- rtl/blit_blend.sv
- rtl/sprite_batch.sv
- rtl/link_control.sv
- Makefile
- sim/blend_ref.h
- sim/engine_blend_dut.sv
- sim/engine_sprite_batch_dut.sv
- sim/engine_sprite_batch_sdram_dut.sv
- sim/tb_blend_px.cpp
- sim/tb_blit_blend.cpp
- sim/tb_link_control.cpp
- sim/tb_sprite_batch.cpp
- sim/test_noodles_link.c
- sim/test_noodles_sdk.c
- sim/test_sdk_install.sh
- lib/noodles.pc.in
- lib/noodles_link.c
- lib/noodles_link.h
- lib/noodles_link_internal.h
- lib/noodles_surface.c
- lib/noodles_surface.h
- tools/blend_demo.c
- docs/INTEGRATION.md
- docs/SDK.md

#### Status:

- [x] Built
- [x] Passed

---

## 4 COMMIT Unreleased 36a2986 2026-09-23T23:28:23-07:00

#### Coming From:

Unreleased 0b48215

#### Purpose:

Close the remaining slow-corner setup paths and add a factor-based blend-mode unit for flagged draws.

#### Outcome:

Reference records BLIT-009 and LINK-014, superseding LINK-013, add descriptor flag bit 4 selecting an explicit blend mode in flag bits 31:8 with SDL 2.32.10's blend factor and operation numbering and a single-rounding bit, published as protocol 1.3. SDL's software BLEND, NONE, ADD, MOD and MUL are exact presets, confirmed against SDL's literal code on 83.9M checks; composed modes, which SDL's software renderer lacks, use the project-defined 8-bit arithmetic of truncating per-term products, the operation and a 0 to 255 clamp. Each blend lane is now one modulation, factor, two-product, operation and clamp unit with 7-cycle latency, and single rounding needs no divider because D(Ps + Pd) equals D(Ps) + D(Pd) plus one when the two remainders reach 255; the lane matched the C model on 89.1M vectors covering every factor and operation combination. Timing work gave `blend_walk` registered burst preparation, `blit_copy64` running source and destination addresses with a precomputed row end, cycle-identical in its tests, and `link_control` a registered read request. SDK 0.6 adds the mode constants, SDL presets including GemRB's wall-occlusion stencil mode, validation and protocol 1.3 gating. Following the user's new rule, a local seed-13 fit and four-corner gate passed before publishing, with worst setup +0.150ns. Commit `e580544` omitted `Noodles.sv`, which `36a2986` added immediately; the published RTL then matched the checked tree. Clean builds of `36a2986` passed at every corner for seed 7 (worst setup +0.168ns, RBF SHA256 `18effcd119329a578569ccf62cf2cd9bc56469a79cfaf7dae2dd2747eaa81185`, 14,663 ALMs, 60 of 112 DSP blocks) and seed 13, whose RBF was byte-identical to the local build, while seed 5 failed at -0.292ns on a `sprite_batch` descriptor-state to `blit_copy64` row-counter path. Seed 7, the QSF's pinned seed, was deployed as `Noodles_modes_seed7.rbf` with hash-verified `-modes` tools and reported protocol 0x00010003. Hardware readback was bit-exact for 10 single-command cases and 576 batched draws, 298 of them flagged with random explicit modes; blending measured 66.18 Mpixel/s, `blit-bench` 75.72, 77.56 and 78.00 Mpixel/s, the 256-sprite workload 15.1fps and the tile cache 60.2fps. Host commit `ebb7c0c` let the demo's wall-occlusion scene use one mode, which ran at about 31fps for BLEND, ADD and MUL each; the rate reflects per-arrow batches waiting on the single descriptor table. The user judged all three modes functionally correct and asked about faint squares under MUL, which are SDL-exact: the demo sprite keeps colour in its transparent pixels, SDL's MUL brightens the destination there, and the stencil zeroes only alpha.

#### Next Steps:

The timing-qualified seed-7 blend-mode image is loaded on the MiSTer at 10.10.0.22, with the accepted `Noodles_2b_fix_seed13.rbf` and earlier diagnostics preserved beside it; the user has not yet decided whether the demo sprite should use black transparent pixels to show MUL without squares. Before publishing any RTL change, run one local fit and four-corner gate on an isolated copy of the working tree, as the user requires. Open follow-ups are the seed-5 path from `sprite_batch` descriptor fetch into `blit_copy64`'s row counter, double-buffering the SDK descriptor table so consecutive batches do not wait on each other, and the remaining GemRB needs: blended rectangle fill, lines, points and polygons, scaled copy for zoom, the SDL2 render driver and core audio. No release has been cut; README and CHANGELOG updates belong to the Releasing workflow.

#### Files Modified:

- Noodles.sv
- rtl/blend_px.sv
- rtl/blend_walk.sv
- rtl/blit_blend.sv
- rtl/blit_copy64.sv
- rtl/link_control.sv
- rtl/sprite_batch.sv
- Makefile
- sim/blend_ref.h
- sim/engine_blend_dut.sv
- sim/engine_sprite_batch_dut.sv
- sim/engine_sprite_batch_sdram_dut.sv
- sim/tb_blend_px.cpp
- sim/tb_blit_blend.cpp
- sim/tb_link_control.cpp
- sim/tb_sprite_batch.cpp
- sim/test_noodles_sdk.c
- sim/test_sdk_install.sh
- lib/noodles.pc.in
- lib/noodles_link.c
- lib/noodles_link.h
- lib/noodles_surface.c
- tools/blend_demo.c
- docs/INTEGRATION.md
- docs/SDK.md

#### Status:

- [x] Built
- [x] Passed

---

## 5 COMMIT Unreleased 0df688d 2026-09-24T07:57:47-07:00

#### Coming From:

Unreleased 36a2986

#### Purpose:

Add bounded CPU transfer and fill operations for the current hardware back buffer so SDL consumers can render their default target without an extra full-screen copy.

#### Outcome:

Source `0df688d` publishes SDK 0.7 with `noodles_back_buffer_read`, `noodles_back_buffer_update` and `noodles_back_buffer_fill`. Transfers require fully in-bounds rectangles, validate host pitch, refuse a pending presentation, perform bounded link drains before resolving the current buffer and copy each row using the hardware pitch; fill clips signed rectangles and submits the existing raw solid-fill command to the current buffer. Host tests cover pitched transfers, clipping, pending-present refusal and both framework-buffer roles. The complete host and SDK-install suites, manual AddressSanitizer and UndefinedBehaviorSanitizer runs, SDK build and installed ARM C and C++ consumers passed. MiSTer-GemRB sources `43b4fe7` and `667661e` used the new API for its SDL default target, and the existing timing-qualified protocol-1.3 RBF passed the expanded hardware diagnostic with hash `a6d5728e`; the same Throne of Bhaal AR4000 save ran without a reported visual fault and eliminated the measured full-screen composition copy.

#### Next Steps:

Use SDK 0.7 as the baseline for direct display-target integrations. The GemRB workload now shows that its remaining approximately 20 blended rectangle fallbacks per frame cost about 19-20ms in regional synchronization plus 13-14ms in CPU fallback and queue handling, so scope an ordered FPGA blended-fill command and enable the existing MiSTer ALSA path in the same required RBF build and timing-qualification cycle.

#### Files Modified:

- docs/SDK.md
- lib/noodles.pc.in
- lib/noodles_link.h
- lib/noodles_surface.c
- lib/noodles_surface.h
- sim/test_noodles_sdk.c
- sim/test_sdk_install.sh

#### Status:

- [x] Built
- [x] Passed

---

## 6 COMMIT Unreleased 2dea6a1 2026-09-24T08:29:17-07:00

#### Coming From:

Unreleased 0df688d

#### Purpose:

Accelerate ordered solid-colour blended rectangles and qualify Linux ALSA audio in the same new RBF cycle.

#### Outcome:

Source `2dea6a1` publishes protocol 1.4 and SDK 0.8 with opcode 8 `BLEND_FILL`, which clips and blends a constant RGBA source through the existing explicit SDL-compatible modes, reads only the destination and preserves command ordering. Raw, managed-surface and current-back-buffer helpers validate the operation and gate it on capability bit 8; the final correction initializes constant-source modulation to full intensity. Simulation passed 5000 randomized rectangles with stalls and alignment variation, a destination-read-count check, 89063424 blend vectors, the complete RTL suite, host and installed-consumer tests and ASan/UBSan. The required isolated seed-13 fit and four-corner gate passed before publication. Three clean builds from the exact source then gave slow -40C setup of -0.064ns for seed 5, -0.009ns for seed 7 and +0.250ns for seed 13; seed 13 passed every corner with worst hold +0.108ns, used 14687 ALMs, 18983 registers, 367668 memory bits and 60 DSP blocks, and reproduced the isolated RBF byte for byte with SHA256 `39c2efa8b08164eb3daad2d5b62ea6961152727b1f92886f5c4a329d527e008f`. On hardware it reported protocol `0x00010004` and capability mask `0x1fe`; 10 existing blend cases covering 24671 pixels, seven blended-fill cases covering 10607 pixels and 576 ordered batched draws covering 270574 pixels were bit-exact with clipping and surrounding pixels preserved. A paced 384000-byte 48 kHz stereo tone reached `/dev/MrAudio` completely and the user heard it over HDMI. MiSTer-GemRB source `7eb7efd` then passed its exact-pixel SDL diagnostic with hash `64d5728e`, its SDL audio tone drained, the user heard menu music, and the Throne of Bhaal AR4000 run reached combat and the game-over video without a renderer fault. Hardware blended fills replaced all measured CPU blended fills and readbacks, halving comparable command-queue time from 45.6-47.7ms to 24.1-26.5ms per frame; settled combat reached 13.93fps and the game-over video 19.8fps.

#### Next Steps:

Open a separate approved cycle to pin seed 13 in `Noodles.qsf`, refresh the older seed-7 qualification, build and integration documentation, and reproduce the pinned revision before treating it as the default distributable image. After that, reduce the remaining sprite-batch drains with bounded descriptor buffering and use the GemRB workload to prioritize scaling and additional 2D primitives shared by VCMI, OpenRCT2, OpenTTD and Augustus.

#### Files Modified:

- Noodles.sv
- lib/noodles.pc.in
- rtl/blit_blend.sv
- rtl/cmdq.sv
- rtl/link_control.sv
- lib/noodles_link.c
- lib/noodles_link.h
- lib/noodles_surface.c
- lib/noodles_surface.h
- sim/test_noodles_link.c
- sim/test_noodles_sdk.c
- sim/test_sdk_install.sh
- sim/cmdq_batch_dut.sv
- sim/engine_blend_dut.sv
- sim/engine_sprite_batch_dut.sv
- sim/tb_blit_blend.cpp
- sim/tb_cmdq_batch.cpp
- sim/tb_link_control.cpp
- docs/INTEGRATION.md
- docs/SDK.md

#### Status:

- [x] Built
- [x] Passed

---

## 7 COMMIT Unreleased 042b62c 2026-09-24T09:33:02-07:00

#### Coming From:

Unreleased 2dea6a1

#### Purpose:

Pin the hardware-accepted seed-13 protocol 1.4 image and make its build and qualification record reproducible from the default project settings.

#### Outcome:

Source `042b62c` replaces the obsolete seed-7 fitter assignment with seed 13 and updates the consumer, build and qualification documents for the protocol 1.4 and SDK 0.8 baseline, including the exact accepted RBF hash, three-seed timing comparison, hardware pixel validation, HDMI audio result and MiSTer-GemRB AR4000 result; it changes no RTL, clock, constraint, protocol or SDK behavior. A fresh online clone of exact source `042b62c`, built with Quartus Prime Lite 17.0.2 Build 602 and `SOURCE_DATE_EPOCH=1790121600`, completed in 5m18s and passed the four-corner gate with the same +0.250ns worst setup, +0.108ns worst hold, 14687 ALMs, 18983 registers, 367668 memory bits and 60 DSP blocks. Its RBF was byte-identical to the hardware-accepted artifact with SHA256 `39c2efa8b08164eb3daad2d5b62ea6961152727b1f92886f5c4a329d527e008f`, so deployment and hardware diagnostics did not need repeating. Documentation commit `70de906` records the exact pinned revision and successful reproduction.

#### Next Steps:

Scope double-buffered or multi-slot sprite descriptors as the next performance cycle, using fence-based ownership so the host can prepare a following batch while hardware consumes the current table. Preserve command order and bounded memory ownership, measure its effect on draw stalls and drains in AR4000, and defer fill batching until the remaining approximately 3ms per frame of solid fills becomes material.

#### Files Modified:

- Noodles.qsf
- README.md
- docs/BUILD.md
- docs/INTEGRATION.md
- docs/QUALIFICATION.md

#### Status:

- [x] Built
- [x] Passed

---

## 8 COMMIT Unreleased 513f218 2026-09-24T09:49:02-07:00

#### Coming From:

Unreleased 042b62c

#### Purpose:

Remove the single sprite-descriptor-table submission bottleneck while preserving ordered execution and bounded host ownership.

#### Outcome:

Source `513f218` publishes protocol 1.5 and SDK 0.9 with 64 aligned 2 KiB descriptor tables, CMDQ-captured opcode-5 table selection, per-table fence ownership, protected raw uploads and protocol-1.4 single-table compatibility. Complete RTL, host, installed-consumer and sanitizer regressions passed, including non-default bases, 320 mixed draws, all 64 simultaneous table owners and 89,063,424 blend vectors. A first seed-13 fit with a redundant table-base register failed slow -40C setup at -0.082ns; removing that register while retaining CMDQ's stable capture preserved behavior, and the repeated suite passed. Per the user's two-build rule, corrected seed 13 and seed 7 fits both passed all four corners; pinned seed 13 has +0.088ns worst setup, +0.080ns worst hold and RBF SHA256 `b79037fce611af71513b7aba9f48ace0a3fa1ffc3f6820c96080be4e60dd5e56`. On hardware it reported protocol `0x00010005` and mask `0x3fe`, passed 576 ordered batched draws bit-exactly with three tables queued per round, drained the SDL audio diagnostic, and ran a four-batch stress at 60.4fps. MiSTer-GemRB source `50cf286` passed its pixel diagnostic and AR4000 combat reduced queue time from 24.1-26.5ms to 14.4-15.2ms per frame, eliminated sprite-batch stalls, reduced drains from approximately 25-27 to about one per frame, reached 15.9-17.8fps and game over without a renderer fault, and used 41.8% of one Cortex-A9 core versus the prior 48-50.5% sample.

#### Next Steps:

Repeat AR4000 once with statistics disabled, then capture a spell-heavy interval to identify whether its remaining cost is flagged sprite work, scaling or a software primitive before choosing the next shared accelerator feature. Keep the protocol-1.4 image as the recovery fallback and retain the two-build limit for future seed comparisons.

#### Files Modified:

- Noodles.sv
- README.md
- docs/INTEGRATION.md
- docs/SDK.md
- lib/noodles.pc.in
- lib/noodles_link.c
- lib/noodles_link.h
- lib/noodles_link_internal.h
- rtl/cmdq.sv
- rtl/link_control.sv
- rtl/sprite_batch.sv
- sim/cmdq_batch_dut.sv
- sim/engine_sprite_batch_dut.sv
- sim/engine_sprite_batch_sdram_dut.sv
- sim/tb_cmdq_batch.cpp
- sim/tb_link_control.cpp
- sim/tb_sprite_batch.cpp
- sim/tb_sprite_batch_sdram.cpp
- sim/test_noodles_link.c
- sim/test_noodles_sdk.c
- sim/test_sdk_install.sh

#### Status:

- [x] Built
- [x] Passed

---

## 9 COMMIT Unreleased d1702b4 2026-09-24T13:44:40-07:00

#### Coming From:

Unreleased 513f218

#### Purpose:

Replace the measured per-rectangle solid-fill submission bottleneck with ordered multi-table fill descriptors while preserving protocol compatibility and exact rendering.

#### Outcome:

Source `d1702b4` publishes protocol 1.6 and SDK 0.10 with a capability-gated `FILL_BATCH` operation that reuses the protocol-1.5 descriptor-table ring and fence ownership, sequences up to 64 validated opaque fills through the existing fill engine, and retains every earlier scalar operation for older consumers. The complete RTL suite, native host tests, installed native/C++/ARM consumer tests, ASan/UBSan and ARMv7 static builds passed. Under the user's two-build limit, seed 13 passed all four timing corners with +0.177ns worst setup and +0.100ns worst hold while seed 7 failed slow -40C setup at -0.158ns; the accepted seed-13 RBF SHA256 is `6b19b4a21e3f5fcfecd46558c9ba49c12f1056d87a5ed44bdfe7468f864d82b9`. Live hardware reported protocol `0x00010006` and mask `0x7fe`, twice passed the extended SDL diagnostic with exact-pixel hash `787b0fbd` across the 64-fill boundary and mixed fill/draw ordering, and drained its audio queue. In AR4000 combat, fill submission fell from 11.5-11.9ms to 1.25-1.76ms per frame and total queue time fell from 14.2-14.5ms to 3.7-5.0ms, but the user observed similar spell stutter because non-renderer work and presentation now dominate.

#### Next Steps:

Keep the accepted seed-13 protocol-1.6 image as the consumer baseline and preserve protocol 1.5 as its recovery fallback. Investigate the spell interval in MiSTer-GemRB before selecting another generic core feature: the remaining cost is outside fill and sprite submission, with bursts of CPU-side animation work, synchronization, texture uploads and readbacks plus presentation waiting.

#### Files Modified:

- Makefile
- Noodles.sv
- README.md
- docs/BUILD.md
- docs/INTEGRATION.md
- docs/QUALIFICATION.md
- docs/SDK.md
- files.qip
- lib/noodles.pc.in
- lib/noodles_link.c
- lib/noodles_link.h
- lib/noodles_link_internal.h
- lib/noodles_surface.c
- lib/noodles_surface.h
- rtl/cmdq.sv
- rtl/fill_batch.sv
- rtl/link_control.sv
- sim/cmdq_batch_dut.sv
- sim/engine_fill_batch_dut.sv
- sim/engine_copy_dut.sv
- sim/engine_ddram_dut.sv
- sim/engine_dut.sv
- sim/tb_cmdq_batch.cpp
- sim/tb_fill_batch.cpp
- sim/tb_link_control.cpp
- sim/test_noodles_link.c
- sim/test_noodles_sdk.c
- sim/test_sdk_install.sh

#### Status:

- [x] Built
- [x] Passed

---

## 10 COMMIT Unreleased 8846a6d 2026-09-25T03:31:49-07:00

#### Coming From:

Unreleased d1702b4

#### Purpose:

Allow one queued frame to cross a pending presentation fence without serializing safe managed-surface work or selecting the wrong back buffer.

#### Outcome:

Source `8846a6d` permits non-presentation commands to remain ordered behind one pending `PRESENT`, predicts the back-buffer parity those commands observe after the flip, allows descriptor uploads behind that flip and lets managed-surface transfers wait only for the surface's last-use fence. A second presentation, arbitrary raw uploads and direct back-buffer CPU transfers remain blocked until the pending presentation completes, while descriptor ownership continues to protect batch tables. Native lifecycle and SDK tests, installed native, C++ and ARM consumers, the ARM static build, ASan/UBSan and the complete RTL simulation suite passed. MiSTer-GemRB source `b77f77c` pins this SDK, twice passed its expanded exact-pixel diagnostic with hash `93f8e614` and passed audio, and reached the 30fps menu cap by queuing rendering behind presentation. In the paused and combat workload, per-texture surface rotation removed the previous 30-38ms managed-update wait, but the resulting overlap exposed 21-32ms of renderer submission backpressure because SDL drains the complete stream whenever the 64-slot command or descriptor ring reports `EAGAIN`. The protocol and RBF remain unchanged.

#### Next Steps:

Add a generic bounded progress wait that retires or live-confirms only the next necessary command, then let MiSTer-GemRB retry ring and descriptor pressure without draining through the pending presentation. Repeat the exact-pixel diagnostic and the same paused and combat measurements before selecting an RBF throughput change.

#### Files Modified:

- README.md
- docs/SDK.md
- lib/noodles_link.c
- lib/noodles_surface.c
- sim/test_noodles_sdk.c

#### Status:

- [x] Built
- [x] Passed

---

## 11 COMMIT Unreleased 973dfb6 2026-09-25T03:55:03-07:00

#### Coming From:

Unreleased 8846a6d

#### Purpose:

Replace whole-stream drains under transient queue pressure with a bounded wait for the next necessary command completion.

#### Outcome:

Source `973dfb6` adds SDK 0.11 and `noodles_link_wait_progress`, which waits for one command of verified forward progress or live-confirms the latest raw completion when hardware has already caught up without changing the nonblocking submission contract. Native lifecycle tests cover idle, outstanding, already-retired, pending-presentation and fence-wrap states; native and installed C/C++ consumers, the ARM static build, ASan/UBSan and the complete RTL simulation suite passed. MiSTer-GemRB source `b404508` pins the API and replaces full-stream renderer drains with bounded progress-and-retry loops. Its exact-pixel diagnostic twice produced hash `93f8e614` and audio passed. A clean paused Throne of Bhaal sample held 20.1fps: renderer queue time fell from 21-24ms to 3.8-4.5ms per frame with zero drains, while presentation wait rose to 32-35ms and visible pacing remained unchanged. This proves the host-side full drain was removed and isolates the remaining approximately 50ms frame interval to FPGA rendering throughput plus the stable 11-13ms of other frame work. The protocol and RBF remain unchanged.

#### Next Steps:

Keep the bounded progress API as the generic pressure path and benchmark the accepted RBF's solid-fill, copy and blend engines independently. Use the measured engine rates and the captured per-frame workload to select the first reusable RTL throughput change, then require exact-pixel, audio and identical paused-scene comparisons before retaining it.

#### Files Modified:

- README.md
- docs/SDK.md
- lib/noodles.pc.in
- lib/noodles_link.c
- lib/noodles_link.h
- sim/test_noodles_sdk.c
- sim/test_sdk_install.sh

#### Status:

- [x] Built
- [x] Passed

---

## 12 COMMIT Unreleased eb5886f 2026-09-25T05:18:57-07:00

#### Coming From:

Unreleased 973dfb6

#### Purpose:

Remove unnecessary DDR3 destination traffic from identity-modulated standard-alpha blends by resolving fully opaque and fully transparent source pairs before destination access.

#### Outcome:

Source `eb5886f` makes identity-modulated standard-alpha draws classify each source pair before destination access: transparent pairs advance without a destination read or write, opaque pairs bypass the blend pipeline and write directly through a registered output stage, and the first partial pair returns the remainder of the draw to the existing destination-read pipeline. The complete simulation suite passed 5,000 randomized cases and 89,063,424 exact blend vectors, native and installed SDK tests, the ARM build and ASan/UBSan passed, and clean seed-13 and seed-7 Quartus builds passed every timing corner. The seed-13 RBF SHA256 is `75e3a2c633f0c729c04d72a57138f34d2222ba5772a48427d0e6ab23e140d197`; it used 16,061 ALMs, 20,656 registers, 366,612 memory bits and 60 DSP blocks. On MiSTer, the exact SDL diagnostic retained hash `93f8e614`, audio passed, and the blend diagnostic matched 307,852 pixels across scalar, fill and batched cases. Direct comparison with the accepted RBF showed unchanged synthetic endpoints of approximately 66.2 million mixed, 57.7 million opaque and 66.9 million transparent pixels per second because source reads or destination writes remain the limiting traffic. The live paused scene improved from the prior 20.0-20.2fps range to 20.9-21.6fps in the first controlled sample, but panning measured 16.6-17.9fps and matched the prior clean 17.9fps result. Combat measured 12.1-14.5fps with unchanged visible stutter; rendering consumed approximately 30-34ms per frame while time outside the renderer rose to 42-53ms, and the known Kobold Commando projectile fault then terminated GemRB with signal 11 while the core remained running.

#### Next Steps:

Retain the correct binary-alpha shortcuts, but do not expect them to remove the visible gameplay dip. Profile the current spell-heavy interval at ARM function level because its 42-53ms non-renderer component now exceeds rendering time, and separately design a generic span-list or polygon submission path for panning, where thousands of SDL span calls still dominate command construction. Select the next RTL throughput change only after the profile distinguishes useful CPU work from synchronization and identifies which remaining full-screen operation limits stationary rendering.

#### Files Modified:

- rtl/blend_walk.sv
- rtl/blit_blend.sv
- sim/tb_blit_blend.cpp

#### Status:

- [x] Built
- [x] Passed

---

## 13 COMMIT Unreleased 26acb9c 2026-09-25T08:46:09-07:00

#### Coming From:

Unreleased eb5886f

#### Purpose:

Let draw work continue while a flip waits for vertical blank by adding an opt-in third display buffer and a queued PRESENT.

#### Outcome:

The previously proposed DDR3 write-burst change was superseded before implementation after MiSTer-GemRB source `cd506c8` measured the accepted protocol-1.6 image: solid fills already reached 175 Mpixel/s or 0.57 clocks per pixel, about 88% of the 64-bit 100MHz port's one-write-per-cycle ceiling, blends were pipeline-limited at 69 Mpixel/s, and GemRB's paused scene locked at 20fps because PRESENT held CMDQ until vertical blank after about 35ms of engine work. Sources `ca23af4` and `26acb9c` publish protocol 1.7, capability mask `0x00000ffe` and SDK 0.12 as specified in reference record OUT-013: a third buffer at `0x31600000`, a two-bit front index, opcode 11 `PRESENT_QUEUED` with buffer index 0-2 or flip barrier 3, fence completion on acceptance, retirement captured at the flip, unchanged legacy PRESENT, and an opt-in SDK three-buffer mode that rotates the back buffer, barriers the first queued flip and permits back-buffer CPU transfers during a queued flip. The first fits of the feature failed timing in pre-existing paths, so with user approval the top level now registers the engine read-port owner and `blit_blend` tracks free FIFO space; the complete simulation suite, host tests, ASan/UBSan, installed consumers and ARM build passed. Seed 13 of `ca23af4` passed all corners but hardware showed commands behind a queued flip still waited for it, because `cmd_ready` gated on the retained PRESENT in `cmd_data` without `cmd_valid`; `26acb9c` gates on the offered command and adds a stale-data test that fails on the previous RTL. Its isolated seed-13 build, with Quartus Prime Lite 17.0.2 and `SOURCE_DATE_EPOCH=1790121600`, passed all four corners with +0.100ns worst setup and +0.009ns worst hold, used 15,604 ALMs, 20,486 registers, 366,612 memory bits, 75 RAM blocks and 60 DSP blocks, and produced RBF SHA256 `ae0159da05a78b3209a6f3619173bb83cff84ca319d24c62159b2156a7e0fcd9`, deployed as `pet/Noodles_triple_seed13.rbf`; seed 7 failed slow -40C setup at -0.047ns and the limiting seed-13 path is link_ring's combinational read priority into `blit_copy64`. On MiSTer the SDL diagnostic passed with hash `93f8e614` and audio in both buffer modes, engine rates were unchanged, a fill behind a queued flip completed 2.76ms after acceptance, and off-screen frames of 19.2ms, 27.4ms and 35.5ms ran at 51.8, 36.4 and 28.1fps against 30.2, 30.2 and 20fps with two buffers. In MiSTer-GemRB the paused AR4000 scene rose from 19.84-19.91fps to 29.15-29.23fps with near-zero presentation wait, the menu felt smoother and the user saw no ghosting, but spell-heavy combat fell to 7.8-10fps with 88-117ms per frame outside the renderer and felt laggier before the known Kobold Commando signal-11 fault ended the session.

#### Next Steps:

Keep the image as the three-buffer candidate while MiSTer-GemRB measures whether concurrent engine traffic slows ARM memory access through the shared DDR3 controller, then compare two- and three-buffer combat on this core. If contention is material, evaluate controller port priority, renderer pacing or moving read-only texture sources to board SDRAM; register link_ring's read priority in the next RTL change to restore timing margin.

#### Files Modified:

- Makefile
- Noodles.sv
- README.md
- docs/INTEGRATION.md
- docs/SDK.md
- lib/noodles_link.c
- lib/noodles_link.h
- lib/noodles_link_internal.h
- lib/noodles_surface.c
- rtl/blit_blend.sv
- rtl/cmdq.sv
- rtl/link_control.sv
- rtl/present.sv
- sim/cmdq_batch_dut.sv
- sim/engine_sprite_batch_dut.sv
- sim/present_dut.sv
- sim/tb_cmdq_batch.cpp
- sim/tb_link_control.cpp
- sim/tb_present.cpp
- sim/test_noodles_sdk.c

#### Status:

- [x] Built
- [x] Passed

---

## 14 COMMIT Unreleased be5b058 2026-09-25T11:00:34-07:00

#### Coming From:

Unreleased 26acb9c

#### Purpose:

Add formal verification of the core's handshake logic and registered pipeline stages that restore timing margin before new rendering features.

#### Outcome:

The protocol-1.7 image from seed 13 passed all four corners with only +0.100ns worst setup and seed 7 failed, and protocol 1.7 had exposed a handshake defect that simulation missed, so the user approved formal verification before registered pipeline stages; CERN's colibri library remains a practice reference only, with project-owned SystemVerilog. At the user's direction the formal tools were installed system-wide: Ubuntu 26.04's Yosys 0.52 with `yosys-smtbmc`, Z3 4.13.3 and Boolector 1.5.118, plus SymbiYosys built from its `v0.52` tag; Boolector rejects the SMT-LIB `set-option` command that `yosys-smtbmc` issues, so every job uses Z3, and a user-space OSS CAD Suite 20260925 bundle downloaded earlier is unused. Source `be5b058` adds each module's properties in an `ifdef FORMAL` block, `fv/link_ring.sby`, `fv/cmdq.sby` and `fv/present.sby`, and `make formal`, which ran all eight proof and cover tasks in about a minute. `link_ring` is proved for 4 and 64 ring slots to keep one read outstanding with its address held, fetch only the slot at read_ptr after a poll finds new work, offer exactly the fetched words and hold them stable until accepted, and advance and write back read_ptr once per accepted command. `cmdq`, with abstract engines and the present contract, is proved to keep cmd_ready independent of cmd_data while cmd_valid is low, dispatch exactly when it reports ready, give each recognized command exactly one start or queued-flip acceptance and one completion, drop other commands without completion, accept no PRESENT while a flip is pending and never restart a running engine; the proof needed explicit invariants that a remembered done never outlives its WAIT_DONE and that a background queued flip never coexists with a legacy PRESENT as last engine, both of which hold. `present` is proved for RETIRE_VBLANKS 0 and 1 to change FB_BASE only on an FB_VBL rising edge and to retire each flip once, after its buffer is selected and FB_RETIRED differs from the level sampled at start for opcode 4 or at the flip for opcode 11. Cover tasks reached every command kind's completion, dropped commands, drawing and a held PRESENT during a queued flip, and full ring dispatch and write-back. Three reintroduced historical defects were each rejected: the protocol-1.7 stale-data cmd_ready, a queued flip without its flip-time acknowledgement capture and an unpinned ring poll address. The top-level read-port owner and fence composition in `Noodles.sv` remain outside the proofs. Reference record CMDQ-004 states the proved contracts and `docs/BUILD.md` documents the flow. The Verilator suite passed unchanged, and an isolated seed-13 Quartus build of this tree with `SOURCE_DATE_EPOCH=1790121600` reproduced the hardware-accepted RBF bit for bit, SHA256 `ae0159da05a78b3209a6f3619173bb83cff84ca319d24c62159b2156a7e0fcd9`, confirming synthesis never sees the properties.

#### Next Steps:

MiSTer-GemRB now reaches 25-30fps across tested scenes with the engine near its limit, and the user has directed a clock increase targeting 150MHz, falling back to 120MHz if closure proves too costly. Measure which paths of the current fit exceed a 6.67ns period, then propose the registered pipeline-stage cycle that extracts and proves the top-level read-port arbiter, registers link_ring and control read priority, adds valid/ready pipeline stages on the adapter paths and resynchronizes FB_VBL and FB_RETIRED, which present.sv currently samples unsynchronized because CLK_VIDEO equals clk_sys, before any clock change.

#### Files Modified:

- .gitignore
- Makefile
- docs/BUILD.md
- fv/cmdq.sby
- fv/link_ring.sby
- fv/present.sby
- rtl/cmdq.sv
- rtl/link_ring.sv
- rtl/present.sv

#### Status:

- [x] Built
- [x] Passed

---

## 15 COMMIT Unreleased d5051f4 2026-09-25T15:20:57-07:00

#### Coming From:

Unreleased be5b058

#### Purpose:

Raise the core clock from 100MHz to 120MHz by separating the video clock and registering the paths that cannot meet an 8.33ns period.

#### Outcome:

Source `d5051f4` raises `clk_sys` to 120MHz, keeps video at 100MHz, synchronizes the video and retirement levels, registers the DDRAM paths, adds a proved seven-client read owner, pipelines the copy and blend engines and scales board-SDRAM timing from the clock frequency without changing protocol 1.7, its capabilities or the SDK contract. The complete Verilator suite and all ten formal proof and cover tasks passed. Three clean Quartus fits then tested seeds 3, 7 and 13: seed 3 passed every corner with +0.089ns worst setup and +0.096ns worst hold, seed 13 passed with +0.051ns worst setup and +0.112ns worst hold, and seed 7 failed slow -40C setup at -0.100ns, so seed 3 is pinned; its RBF SHA256 is `fe858c3fce82ac17cb867485bf66c0627e5219c6cdd6f351dc7478364399a0c3`. On hardware the seed-3 image reported protocol 1.7 and passed the exact-pixel SDL diagnostic with hash `93f8e614` plus HDMI audio in two-buffer mode, but it failed the throughput qualification reproducibly: solid fill, fill batch and blended fill completed at approximately their 100MHz rates, then the first full-screen `BLIT_COPY` warmup never retired and timed out. The earlier apparent two- and three-buffer passes were found to have run against the accepted fallback left by the interrupted session, not this candidate. The MiSTer-GemRB AR0015 comparison was therefore not run, the 120MHz image is rejected, and the accepted 100MHz seed-13 image with SHA256 `ae0159da05a78b3209a6f3619173bb83cff84ca319d24c62159b2156a7e0fcd9` was restored and passed its SDK, three-buffer exact-pixel and audio checks.

#### Next Steps:

Keep the accepted 100MHz image loaded and obtain approval for a diagnostic-only cycle that instruments the full-screen copy request, response, FIFO and completion state around the timeout, then reproduces it with bounded copy sizes to distinguish a 120MHz DDRAM handshake failure from an engine pipeline or counter defect. Do not continue toward 150MHz or run GemRB against the 120MHz candidate until the copy timeout is understood and corrected.

#### Files Modified:

- Noodles.sv
- Noodles.sdc
- Noodles.qsf
- README.md
- docs/BUILD.md
- docs/INTEGRATION.md
- Makefile
- files.qip
- fv/ddram_read_owner.sby
- rtl/blend_px.sv
- rtl/blit.sv
- rtl/blit_blend.sv
- rtl/blit_copy.sv
- rtl/blit_copy64.sv
- rtl/ddram_adapter.sv
- rtl/ddram_read_owner.sv
- rtl/pll.v
- rtl/pll/pll_0002.v
- rtl/present.sv
- rtl/sdram.sv
- rtl/sdram_loader.sv
- sim/engine_sprite_batch_dut.sv
- sim/sdram_loader_dut.sv
- sim/tb_blend_px.cpp
- sim/tb_blit_copy64.cpp
- sim/tb_ddram_ingress.cpp
- sim/test_report_multicorner.tcl
- tools/report_multicorner.tcl
- tools/report_timing.tcl

#### Status:

- [x] Built
- [ ] Passed

---

## 16 COMMIT Unreleased f97ce70 2026-09-25T16:44:05-07:00

#### Coming From:

Unreleased d5051f4

#### Purpose:

Find and correct the 120MHz full-screen copy completion failure without weakening the accepted timing or command-order contracts.

#### Outcome:

Source `4b1015f` identifies the 120MHz copy timeout as an unowned DDR response: the scalar copy request could reach the adapter before the registered read-owner grant, so the adapter accepted a request for which the copy engine had reserved no response slot. It gates the adapter request with the actual grant, adds the registered owner handoff to the simulation regression and adds a bounded hardware copy sweep. Source `4673ec8` then registers blend FIFO alpha classification before it controls destination reads and opaque output, removing the remaining blend control path without changing results or measured simulation cycles. The complete Verilator suite, all formal jobs, native and installed SDK checks and ARM build passed. Nine exploratory clean fits tested seeds 1 through 7, 9 and 13; final source `f97ce70` pins seed 2 and a clean three-build reproduction from that exact online commit gave seed 2 a four-corner pass with +0.227ns worst setup and +0.077ns worst hold, while comparison seeds 1 and 3 missed only the 100MHz composite-video path by 0.034ns and 0.093ns. The qualified fit uses 12,906 ALMs, 22,261 registers, 365,969 memory bits and 60 DSP blocks, and its reproducible RBF SHA256 is `ae2cdf45e0322f0d91bafeba481594b57c6d65c80fa444256a0153338e849cc6`. On MiSTer it reported protocol 1.7, passed every bounded copy case through repeated 800x600 copies, completed the full engine and presentation throughput suite, retained exact SDL pixel hash `93f8e614` and passed HDMI audio in both two-buffer and three-buffer modes. Full-screen copy measured 26.5 Mpixel/s, fill 177.5 Mpixel/s and blended draws 66.7-70.7 Mpixel/s, confirming that the clock increase is timing and functionally qualified but does not materially raise the DDR- or pipeline-limited rates that determine the observed GemRB frame rate.

#### Next Steps:

Keep the timing-qualified seed-2 image under the canonical launcher filename and retain the accepted 100MHz seed-13 image as the fallback. Use MiSTer-GemRB frame profiling and the measured per-operation rates to select a DDR traffic or engine-pipeline improvement before considering another clock increase, because 120MHz alone does not improve the current gameplay bottleneck.

#### Files Modified:

- Makefile
- Noodles.sv
- Noodles.qsf
- rtl/blit_blend.sv
- scripts/deploy.sh
- sim/engine_copy_dut.sv
- tools/copy-sweep.c

#### Status:

- [x] Built
- [x] Passed

---

## 17 COMMIT Unreleased 019a496 2026-09-25T18:19:00-07:00

#### Coming From:

Unreleased f97ce70

#### Purpose:

Measure why the 120MHz core retains the 100MHz engine throughput before selecting the next memory-path change.

#### Outcome:

Source `019a496` adds a passive physical-port probe and ARM reader that count an isolated operation only until its engine and the DDR adapter drain, then publish the snapshot through the lowest-priority write client after the measured interval. The complete simulation suite, formal proofs, native and installed SDK checks, ARM build and timing-report tests passed. Three disposable seed fits completed; all missed 120MHz setup, with seed 3 the closest at -0.344ns, and the user explicitly waived timing qualification for this short diagnostic. On MiSTer, seed 3 measured a 480,000-pixel solid fill in 327,226 cycles: 240,002 accepted 64-bit writes, only three command-idle cycles and 87,221 DDRAM-stalled command cycles, fixing the accepted rate near 88 million beats/s despite the 120MHz clock. Scalar BLIT_COPY issued 480,000 separate one-word reads and 480,002 writes while spending 1,087,688 of 2,261,572 cycles without a command. BLEND_FILL and BLIT_BLEND source/destination reads used healthy eight-word bursts, but their 240,002 writes remained individual beats and they respectively spent 214,104 of 548,229 and 658,292 of 1,002,247 cycles command-idle. This proves raw DDR bandwidth is not exhausted: burst-count-one writes pay enough bridge/controller backpressure to erase the clock gain, while the legacy scalar copy additionally serializes one-word reads and leaves the port idle. The qualified `f97ce70` seed-2 RBF was restored with SHA256 `ae2cdf45e0322f0d91bafeba481594b57c6d65c80fa444256a0153338e849cc6` under the release-convention `_Utility/Noodles_20260925.rbf` filename, with the launcher and MGL convention left intact.

#### Next Steps:

Remove the temporary probe while teaching the shared DDR adapter to combine queued, contiguous full-word writes into legal Avalon write bursts, preserving sparse and partial writes as single beats. Verify the burst protocol and ordering in simulation, then measure fill and blend throughput before considering replacement of the legacy scalar BLIT_COPY path.

#### Files Modified:

- Makefile
- Noodles.sv
- files.qip
- rtl/ddram_perf_probe.sv
- scripts/deploy.sh
- tools/ddram-perf.c

#### Status:

- [x] Built
- [x] Passed

---
