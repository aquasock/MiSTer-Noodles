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

## 4 COMMIT Unreleased ??? 2026-09-23T23:28:23-07:00

#### Coming From:

Unreleased 0b48215

#### Purpose:

Close the remaining slow-corner setup paths and add a factor-based blend-mode unit for flagged draws.

#### Outcome:

Planned, not yet implemented. The timing work splits `blend_walk` request formation into registered prepare and commit steps, registers `blit_copy64`'s per-entry destination address arithmetic and registers `link_control`'s read request. A new reference record will add descriptor flag bit 4, selecting a blend mode encoded in flag bits 31:8: SDL 2.32.10's software ADD, MOD and MUL, bit-exact including MUL's single rounding over a two-product sum, computed exactly as (x * 131587) >> 25 for x up to 130050, and composed modes with SDL's ten blend factors and five operations for colour and alpha, which SDL's software renderer lacks. For composed modes the project defines its own exact 8-bit arithmetic: each term is floor(value * factor / 255), the operation combines the terms and the result clamps to 0 to 255, while minimum and maximum compare raw values and ignore the factors. This covers GemRB's additive, modulate, multiply, glow and wall-occlusion stencil modes. The blend stage of each pixel lane becomes one general two-product, operation and clamp unit reusing the existing multipliers, published as protocol 1.3, with SDK 0.6 carrying modes in SDL's own factor and operation numbering.

#### Next Steps:

Verify built-in modes exhaustively per channel and composed modes over exhaustive factor and operation tables plus random compositions, extend the batch tests, pass all simulation and host regressions, run a local fit and four-corner gate before publishing, then build three seeds, deploy, check hardware readback and benchmarks, and obtain user visual acceptance of a demo showing additive glow and stencil occlusion.

#### Files Modified:

- Noodles.sv
- rtl/blend_px.sv
- rtl/blend_walk.sv
- rtl/blit_blend.sv
- rtl/blit_copy64.sv
- rtl/link_control.sv
- rtl/sprite_batch.sv
- sim/blend_ref.h
- sim/tb_blend_px.cpp
- sim/tb_blit_blend.cpp
- sim/tb_sprite_batch.cpp
- lib/noodles_link.c
- lib/noodles_link.h
- lib/noodles_surface.c
- lib/noodles_surface.h
- sim/test_noodles_sdk.c
- tools/blend_demo.c
- docs/INTEGRATION.md
- docs/SDK.md

#### Status:

- [ ] Built
- [ ] Passed

---
