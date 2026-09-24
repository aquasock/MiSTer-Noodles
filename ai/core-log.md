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

## 5 COMMIT Unreleased ??? 2026-09-24T07:57:47-07:00

#### Coming From:

Unreleased 36a2986

#### Purpose:

Add bounded CPU transfer and fill operations for the current hardware back buffer so SDL consumers can render their default target without an extra full-screen copy.

#### Outcome:

The planned SDK 0.7 operations will read, update and fill clipped regions of the current 800x600 back buffer while preserving pending-present ownership, bounded fence waits, pitch validation and command order. They will use protocol 1.3's existing fixed back buffers and commands, require no RTL or RBF change, and retain managed surfaces for textures and offscreen render targets.

#### Next Steps:

Implement the public back-buffer operations, add host tests for clipping, pitched transfers, buffer-role changes and pending-present refusal, run the complete host, sanitizer and installed-consumer suites, then update MiSTer-GemRB to render its SDL default target directly and verify the existing hardware diagnostic before repeating gameplay timing.

#### Files Modified:

- lib/noodles.pc.in
- lib/noodles_link.h
- lib/noodles_surface.c
- lib/noodles_surface.h
- sim/test_noodles_sdk.c
- docs/SDK.md

#### Status:

- [ ] Built
- [ ] Passed

---
