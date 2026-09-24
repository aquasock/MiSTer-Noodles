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

## 3 COMMIT Unreleased ??? 2026-09-23T22:25:51-07:00

#### Coming From:

Unreleased 1d4957f

#### Purpose:

Add per-descriptor blend, mirror and colour/alpha modulation to SPRITE_BATCH and close the write-port timing violation left by entry 2.

#### Outcome:

Planned, not yet implemented. A new reference record will define sprite descriptor flag bits for straight-alpha blending, horizontal mirroring and vertical mirroring, with the colour-key word reinterpreted as an RGBA modulation for flagged descriptors, and the arithmetic of SDL 2.32.10's generic path for colour and alpha modulation with and without blending. A protocol minor revision will advertise the new descriptor semantics without changing the command layout. The blend engine will gain a colour-modulation stage, reversed source walking for vertical mirroring and burst-reversed pixel placement for horizontal mirroring, and `sprite_batch` will dispatch flagged descriptors to it, waiting for the DDR3 adapter to drain between descriptors so overlapping draws read completed results, while unflagged descriptors keep the accepted `blit_copy64` path. Batch-launched blends will not advance the host fence individually. The timing fix will give each write client a ready signal derived only from the adapter's registered queue space and its own requests, removing the combinational path from one engine's request logic into another engine's ready. The SDK will add flagged surface and texture-cache batch draws with mirror-aware clipping and will gate them on the protocol revision.

#### Next Steps:

Extend the exhaustive datapath and randomized engine simulations to cover modulation, both mirror axes, keyed and flagged batches and overlapping batched draws, and pass host, sanitizer and full simulation regressions. Build three seeds through the four-corner gate, deploy with hash readback, verify flagged draws on hardware against the C model, measure batch throughput, confirm existing benchmarks, and obtain user visual acceptance of a mirrored and tinted demo.

#### Files Modified:

- Noodles.sv
- rtl/ddram_adapter.sv
- rtl/blend_px.sv
- rtl/blend_walk.sv
- rtl/blit_blend.sv
- rtl/sprite_batch.sv
- rtl/link_control.sv
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
