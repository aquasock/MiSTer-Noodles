## 1 COMMIT Unreleased ??? 2026-09-23T21:39:52-07:00

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
