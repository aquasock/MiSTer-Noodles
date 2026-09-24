# Build qualification

The living record of Noodles's builds: what was built, whether it closed
timing, whether it was validated on hardware, and where the artifact came
from. The build procedure itself is in [BUILD.md](BUILD.md).

## Summary

| # | Date | Build | Seed | RBF SHA-256 | Hardware status |
|---|---|---|---:|---|---|
| 5 | 2026-09-24 | **Current:** protocol 1.4, 800x600 at 100MHz, four-corner timing pass | 13 | `39c2efa8…7e008f` | Exact pixels, HDMI audio and MiSTer-GemRB accepted |
| 4 | 2026-09-23 | Previous protocol 1.0 800x600 build, four-corner timing pass | 7 | `a020e304…43a47a` | User visually accepted; independent reproduction waived |
| 3 | 2026-09-23 | 800x600 candidate, source `37d21c9`; cold-corner setup failure | 5 | `65ca7861…eb5587` | Diagnostic hardware run only; not qualified |
| 2 | 2026-09-23 | Recovery fallback: 640x480, shared 100MHz clock, registered write ingress and slot enables | 5 | `b76fb924…247b8d` | Accepted; clean-commit reproduction verified |
| 1 | 2026-09-22 | Historical: SPRITE_BATCH engine, 64-bit DDRAM path, PRESENT retirement-acknowledgement fix | 1 | `25f9d3a1…edba93` | Accepted -- see below |

## Current protocol 1.4 seed-13 build (5)

The accepted RBF was built from source
`2dea6a1b0a5a536bba8d497fda2b5480c47600fe` with only the fitter SEED
overridden to 13. `Noodles.qsf` now pins seed 13 without changing RTL,
clocks, constraints, thread count or register-packing effort. The build used
Quartus Prime Lite 17.0.2 Build 602, device `5CSEBA6U23I7`, 16 fitter
threads, MEDIUM register packing and `SOURCE_DATE_EPOCH=1790121600`. Its RBF
SHA-256 is
`39c2efa8b08164eb3daad2d5b62ea6961152727b1f92886f5c4a329d527e008f`.

Three isolated clean builds held source, epoch and settings constant while
changing only the seed. Seed 13 reproduced the independent prepublication
fit byte for byte and was the only seed to pass every timing corner:

| Seed | Slow -40C setup | Worst hold | Four-corner result | RBF SHA-256 |
|---:|---:|---:|---|---|
| 5 | -0.064ns | +0.080ns | FAIL | `39c0c66985dc7cbe7b1e440f086fcbeec146a8c32eaf6941be109373116faee2` |
| 7 | -0.009ns | +0.080ns | FAIL | `e3c7d5dac7f807d5e57b82f2b6d93b9432d1dfd222adc6c00ad450f5729669f5` |
| 13 | +0.250ns | +0.108ns | PASS | `39c2efa8b08164eb3daad2d5b62ea6961152727b1f92886f5c4a329d527e008f` |

Seed 13 per-corner worst slack, in ns:

| Model at 1.1V | Setup | Hold | Core setup | Core hold | Recovery | Removal | Min pulse width |
|---|---:|---:|---:|---:|---:|---:|---:|
| Slow, +100C | +0.399 | +0.226 | +0.399 | +0.245 | +0.571 | +1.010 | +1.122 |
| Slow, -40C | +0.250 | +0.112 | +0.250 | +0.146 | +0.559 | +0.950 | +1.122 |
| Fast, +100C | +3.154 | +0.131 | +4.241 | +0.131 | +5.070 | +0.498 | +1.122 |
| Fast, -40C | +3.589 | +0.108 | +5.249 | +0.108 | +5.338 | +0.431 | +1.122 |

The fitted image uses 14,687 ALMs, 18,983 registers, 367,668 block-memory
bits, 77 RAM blocks and 60 DSP blocks. All recovery, removal and pulse-width
checks pass. The same twelve framework constraint warnings remain covered by
the audit later in this document.

The image was deployed as `Noodles_blend_fill_seed13.rbf` and its upload was
hash-verified. The live identity reported protocol `0x00010004`, capability
mask `0x000001fe`, 800x600 geometry and 3200-byte pitch. Hardware readback was
bit-exact for 10 existing blend cases covering 24,671 pixels, seven
constant-source blended fills covering 10,607 pixels, and 12 ordered batch
rounds containing 576 draws and 270,574 checked pixels. Clipping and pixels
surrounding every blended fill remained unchanged.

A deterministic 384,000-byte 48 kHz stereo S16 tone was consumed completely
through `/dev/MrAudio`, and the user heard it over HDMI. MiSTer-GemRB source
`7eb7efd` passed its managed- and default-target exact-pixel diagnostic with
hash `64d5728e`, drained a second tone through SDL's `mister` audio driver and
played audible menu music. In the Throne of Bhaal AR4000 workload, hardware
blended fills reduced comparable command-queue time from 45.6-47.7ms to
24.1-26.5ms per frame with zero CPU blended fills, readbacks or blended-fill
stalls. Settled combat reached 13.93fps, and the run reached a 19.8fps
game-over video without a renderer fault.

**Pinned-source reproduction verified.** A fresh online clone checked out at
source `042b62ce9aefd1d34d167916ccffff930512e8e6` and built with
`SOURCE_DATE_EPOCH=1790121600` completed its full compile in 5m18s. The
four-corner gate reproduced every slack value and resource count above, and
the resulting RBF was byte-identical to the hardware-accepted artifact with
SHA-256 `39c2efa8b08164eb3daad2d5b62ea6961152727b1f92886f5c4a329d527e008f`.
No redeployment or repeated hardware run was needed because the generated
bitstream did not change.

## Previous protocol 1.0 SVGA build (4)

The seed7 RBF from the additional seed comparison below was uploaded as
`Noodles_svga_seed7.rbf`, verified by FTP readback and loaded with matching
`stress-demo-svga-seed7`. The user reported "Looks good" and explicitly
waived independent clean-rebuild verification. This is visual acceptance
of the tested workload, not exhaustive pixel-readback validation.

The source is `37d21c9b5535df0a8dff604516a423e3653c7f29` with only SEED
overridden to 7. Source `4cd38a7207e74771ca94351c6d7b94d307c69211`
pins seed7 without changing RTL,
constraints, clock frequency or other fitter settings. The RBF SHA-256 is
`a020e304aa6903e06e55c2efdba15d1513fb3aa4db9494840b6028a3ba43a47a`.
All four timing corners pass as recorded below. An exact online pinned
revision has not been independently rebuilt to prove a byte-identical RBF;
do not confuse the verified 640x480 reproduction with this SVGA build.

The SVGA seed5 diagnostic and accepted 640x480 image remain preserved. Seed 7
was the standard image until the protocol 1.4 seed-13 build superseded it; a
runtime resolution switcher remains deferred.

Hardware measurements using the matching SVGA tool:

| Workload | Result |
|---|---|
| 256 sprites, 128x128, four batches, 15 seconds | 227 frames, 15.1fps |
| Same workload, 60 seconds | 905 frames, 15.1fps |
| Uncapped blits, three 15-second runs | 77.13 / 78.75 / 79.04 Mpixel/s |
| Key-checker, 64 sprites at 128x128, 15 seconds | 453 frames, 30.1fps |
| Full-screen clear/present, 15 seconds | 906 frames, 60.3fps |
| Present-only, 15 seconds | 905 frames, 60.3fps |

The initial key-checker invocation incorrectly requested 256 sprites; the
tool rejected it because that mode permits at most 64, before submitting
work. The corrected run and remaining checks completed without reported
command errors or timeouts. The key-checker result uses an explicit sprite
size/count and is not directly comparable to earlier differently sized runs.

## SVGA seed comparison and original candidate (3)

### Additional seed comparison

Source `37d21c9` was also built in three isolated copies with only the
fitter SEED assignment changed to 4, 6 or 7. The date, threads, packing,
device, RTL and constraints stayed fixed. Three builds ran concurrently;
each completed within the twenty-minute limit.

| Seed | Compile time | Worst setup across corners | Worst hold across corners | Four-corner result |
|---|---|---:|---:|---|
| 4 | 9m09s | -0.081ns | +0.082ns | FAIL: cold slow core setup |
| 6 | 9m00s | -0.046ns | +0.089ns | FAIL: cold slow core setup |
| 7 | 9m03s | +0.382ns | +0.084ns | PASS |

At comparison time seed7 was timing-qualified but not yet hardware accepted,
and the repository QSF still pinned seed5. Reproducing that experiment
requires source `37d21c9` plus SEED 7, not the unchanged source revision alone.
Subsequent seed7 hardware acceptance and pinning are recorded above.

Seed7 per-corner worst slack, in ns:

| Model at 1.1V | Setup | Hold | Core setup | Core hold | Recovery | Removal | Min pulse width |
|---|---:|---:|---:|---:|---:|---:|---:|
| Slow, +100C | +0.391 | +0.247 | +0.391 | +0.247 | +3.582 | +0.941 | +1.122 |
| Slow, -40C | +0.382 | +0.186 | +0.382 | +0.239 | +3.808 | +0.876 | +1.122 |
| Fast, +100C | +3.284 | +0.104 | +4.336 | +0.104 | +5.034 | +0.461 | +1.122 |
| Fast, -40C | +3.765 | +0.084 | +5.133 | +0.084 | +5.329 | +0.395 | +1.122 |

RBF SHA-256 values:

| Seed | SHA-256 |
|---|---|
| 4 | `ceffada3753a9bf2baa02ee3b859202b0f9a312a7fef2eeae7781bf2bc723100` |
| 6 | `f9c24dbe4527a38b6dd1ea2f6ece4ba03af48eed7b5ffe9aa98119b09052bd77` |
| 7 | `a020e304aa6903e06e55c2efdba15d1513fb3aa4db9494840b6028a3ba43a47a` |

SVGA remains the intended standard render resolution. Runtime VGA/SVGA
switching is deferred; the 640x480 image is retained only as a recovery
baseline. Passing timing does not establish visual acceptance or identical
hardware performance for a new fit.

### Original seed5 build

A clean clone of online source `37d21c9` built in 4m23s with the same
Quartus/device/seed/thread/packing settings and `SOURCE_DATE_EPOCH=1790121600`.
The render framebuffer is 800x600, pitch 3200; the GPU remains 100MHz.
RBF SHA-256:
`65ca7861f16add6df078287e79ad52e584f20fc3fb4fc6698990a8c156eb5587`.

The default slow +100C check passes, but the explicit four-corner gate
correctly exits nonzero: slow -40C setup fails at -0.137ns from the
`vga_out:vga_scaler_out` line-buffer RAM to `y_1r[13]`, on the HDMI PLL
clock. This candidate is not timing-qualified. The user subsequently
authorized loading it explicitly as a diagnostic to measure FPS.

| Model at 1.1V | Overall setup | Overall hold | Core setup | Core hold |
|---|---:|---:|---:|---:|
| Slow, +100C | +0.349 | +0.225 | +0.679 | +0.244 |
| Slow, -40C | -0.137 | +0.127 | +0.542 | +0.190 |
| Fast, +100C | +3.230 | +0.131 | +4.410 | +0.131 |
| Fast, -40C | +3.629 | +0.114 | +5.304 | +0.116 |

Recovery, removal and pulse width pass at every corner. The same twelve
framework unmatched-filter/empty-source warnings remain. Host and ARM/native
builds and the full RTL suite pass, including the 480000-pixel fill and
sprite-batch tests with 3200-byte destination pitch. These do not override
the failing timing gate or establish hardware acceptance.

### Diagnostic hardware measurements

The RBF was uploaded as `Noodles_svga_seed5_diagnostic.rbf` with matching
`stress-demo-svga`; both uploads were hash-verified by FTP readback. The
accepted `Noodles_ingress_seed5.rbf` and `stress-demo-ingress` were preserved.
Four 15-second runs completed without reported command errors/timeouts:

| Workload | SVGA result | Prior 640x480 result |
|---|---:|---:|
| 256 sprites, 128x128, four batches, with clear/present | 15.1fps (227 frames) | 15.1fps |
| Uncapped blit throughput | 75.31 Mpixel/s | 76.18 / 80.11 / 81.16 Mpixel/s |
| Full-screen clear/present | 60.4fps | 60.3fps |
| Present-only | 60.3fps | 60.3fps |

These are short-run performance observations, not pixel-readback or visual
acceptance. One uncapped sample does not establish a persistent regression.
SVGA has 56.25% more framebuffer pixels, but the fixed sprite workload has
the same sprite count and dimensions. The timing violation remains unresolved;
the diagnostic image remained loaded after that run, until seed7 superseded it.

## Accepted 640x480 recovery build (2)

This remains the accepted recovery fallback. Current source targets 800x600
with a 3200-byte pitch and seed 13, qualified separately above. Do not pair
the new host tools with this 640x480 image.

Quartus Prime Lite 17.0.2 Build 602, Cyclone V `5CSEBA6U23I7`,
revision `Noodles`, seed 5, 16 fitter threads, MEDIUM register packing,
`BUILD_DATE "260923"`. Accepted RBF SHA-256:
`b76fb924c43cb25b9c516e216f247dacb576ec72ab6ef408b1a275d9bc247b8d`.

The core PLL has one 100MHz output. Core setup is +0.541ns and hold
+0.252ns; minimum setup across reported clocks is +0.327ns (HDMI).
All reported setup, hold, recovery, removal and pulse-width categories have
zero TNS. Seeds 4 and 6 also pass, with core setup +0.319/+0.071ns.
Resources: 11,120 ALMs, 14,286 registers, 362,241 block-memory bits.
A post-fit sweep of this same reproduced database passes all four available
timing corners; see the results below. The twelve framework
unmatched-filter/ignored-exception warnings were audited against synthesis
removal records and the fitted netlist. They refer to eliminated logic in
this configuration, not twelve timing failures. Broader constraint coverage
and board-I/O sign-off remain outside this qualification.

On the MiSTer, the 256-sprite 128x128 workload ran at 15.1fps, including a
60-second run of 905 frames visually accepted by the owner. Key-checker,
clear and present checks completed at approximately 60fps. Uncapped
throughput samples were 76.18, 80.11 and 81.16 Mpixel/s. No command failures
or timeouts were reported. These are workload checks, not exhaustive pixel
readback validation.

**Reproducibility verified.** A fresh clone fetched from GitHub, checked out
at source commit `c3d04ab68dd1d2f14ba7bd858f6cfe98c1508e86`, was built without
prior Quartus databases using `SOURCE_DATE_EPOCH=1790121600`. The build
completed in 4m19s on 2026-09-23 and produced a byte-for-byte identical RBF
to the hardware-accepted seed-5 snapshot (SHA-256 above). The full compile
and detailed timing script succeeded, and all reported timing categories
have zero TNS. This verifies that exact revision and toolchain/settings,
not arbitrary later revisions or tool versions.
See [BUILD.md](BUILD.md) for the reproduction command.

## Historical build (1)

Quartus Prime Lite 17.0.2 Build 602, Cyclone V `5CSEBA6U23I7`, project
revision `Noodles` (top-level entity `sys_top`), MEDIUM ALM register
packing, 16 fitter threads, `SEED 1` -- all pinned in `Noodles.qsf`.

- **Resources:** 7,341 / 41,910 ALMs (18%), 61 / 553 M10K blocks (11%), 35 /
  112 DSP blocks (31%), 3 / 6 PLLs.
- **Timing:** single-corner analysis (this project does not run
  `TIMEQUEST_MULTICORNER_ANALYSIS`; see [Timing coverage](#timing-coverage-and-limits)
  below). Worst slack: Setup +0.412 ns, Hold +0.246 ns, Recovery +3.891 ns,
  Removal +0.716 ns, Minimum Pulse Width +1.122 ns -- every category zero
  TNS (no failing paths).

**Reproducibility.** Built twice from two independently-extracted copies of
the same commit (`b6834d0`, no manual edits, isolated build directories with
no shared Quartus state), pinning the same seed/thread-count/packing-effort
already committed in `Noodles.qsf`. Both produced a byte-identical
`output_files/Noodles.rbf`: 2,441,536 bytes, SHA-256
`25f9d3a1ce9dcab382bc03a5b455edb2ea799cc231e732157766367483edba93`. The only
non-deterministic input, `build_id.v`'s date stamp, was identical between
the two runs since both ran the same day; a build made on a different
calendar day will differ in those bytes only (see BUILD.md's gotcha note).

**Hardware.** Deployed and driven directly on the owner's MiSTer (loaded via
`/dev/MiSTer_cmd`'s `load_core`) on 2026-09-22:

- `link-push`/`link-slot-dump`: basic LINK ring-buffer dispatch confirmed
  (command consumed, `read_ptr` caught up to `write_ptr`).
- `present-demo`: six-color double-buffer cycle completed cleanly, no
  reported tearing.
- `sprite-demo`: one bouncing colorkeyed sprite, ~19.5 fps average, no
  fence timeouts or ring stalls.
- `stress-demo` (64 independently-bouncing sprites): ~13-14 fps average,
  matching the historically-recorded ~15 fps target for this workload (see
  `ai/core-log.md` entries around "paired-solid-fill" and the LINK-007
  pipelining fix). No fence timeouts, no ring-full errors, no visible
  flicker, ghosting, or corruption.

**Known non-blocking issue.** Under the 64-sprite `stress-demo` workload, the
host observes a periodic per-frame stutter (~1 frame in 5 balloons from the
normal ~50ms to ~150-370ms) rather than smooth pacing, which pulls the
session average down from the per-frame steady-state rate. Root cause: PRESENT
(`rtl/present.sv`) blocks until `ascal`'s Avalon-side read pipeline reports
fully idle (`sys/ascal.vhd`'s `avl_read_outstanding=0` gate on
`o_fb_retired`) before completing a flip. `ascal`'s scanout reads and this
core's own BLIT/SPRITE_BATCH writes contend for the same physical DDR3 bus
with no shared arbitration between them, so under heavy sustained write load
`ascal` occasionally misses its usual per-frame idle window and PRESENT has
to wait for an extra video frame or more before the retirement acknowledgement
arrives. This is DRAM bandwidth contention, not a logic defect; visual output
itself remains correct (no tearing or corruption observed), only pacing is
affected. Tracked for a future OUT-record decision (a native fixed-resolution
timing generator bypassing `ascal`/MISTER_FB entirely would remove the
independent-arbiter contention, at the cost of MiSTer's automatic
resolution/refresh scaling).

## Timing coverage and limits

The compile flow retains its original single-corner setting
(`TIMEQUEST_MULTICORNER_ANALYSIS OFF` in `Noodles.qsf`) for reproduction.
Future qualification also requires the explicit post-fit
`tools/report_multicorner.tcl` gate described in [BUILD.md](BUILD.md).

On 2026-09-23 the independently reproduced `c3d04ab` seed-5 fitted database
was analyzed at every operating condition returned by Quartus 17.0.2 for
`5CSEBA6U23I7` and the configured -40C to +100C junction-temperature range.
All values below are worst slack in ns; all checks pass.

| Model at 1.1V | Setup | Hold | Core setup | Core hold | Recovery | Removal | Min pulse width |
|---|---:|---:|---:|---:|---:|---:|---:|
| Slow, +100C | +0.327 | +0.252 | +0.541 | +0.252 | +3.497 | +0.973 | +1.122 |
| Slow, -40C | +0.239 | +0.117 | +0.317 | +0.235 | +3.742 | +0.872 | +1.122 |
| Fast, +100C | +3.282 | +0.099 | +4.563 | +0.099 | +5.334 | +0.506 | +1.122 |
| Fast, -40C | +3.620 | +0.081 | +5.410 | +0.081 | +5.515 | +0.383 | +1.122 |

The minimum setup path is `ascal|o_hacc[8]` to `ascal|o_div[0][20]` in
the HDMI clock domain. The minimum hold path is the
`pll_hdmi_adj|i_delay[13]` self-feedback path on the 100MHz core clock.
The analysis did not rebuild or alter the accepted RBF; its SHA-256 remains
`b76fb924c43cb25b9c516e216f247dacb576ec72ab6ef408b1a275d9bc247b8d`.
These results qualify timing under the existing constraints, not their
completeness, arbitrary board interfaces or every runtime workload.

### Framework constraint warning audit

The twelve messages from `sys/sys_top.sdc:60-70` comprise eight unmatched
filter patterns (332174) and four ignored empty-source exceptions (332049).
The synthesis removal report gives the following reasons; TimeQuest queries
of the fitted registers confirm the targets are absent, rather than merely
renamed under a different hierarchy.

| Targets | Synthesis evidence and configuration |
|---|---|
| `arc*` | `arc1x/y`, `arc2x/y` lost fanout; Noodles supplies a fixed 4:3 ratio instead of selecting programmable alternatives. |
| `arx*`, `ary*` | Bits reduced to constants matching the core's 4:3 ratio. |
| `vs_line*` | Lost fanout in the unused native-video synchronization path; core HS/VS/DE are tied low for framebuffer output. |
| `ascal|o_hdown`, `ascal|o_vdown` | Stuck at GND; framebuffer mode overrides both flags to zero. |
| `ascal|o_vrr`, `ascal|o_vrrmax*` | Lost fanout; associated VRR synchronization logic reduced to constants. |

No false-path exceptions were added, removed or broadened to silence these
warnings. This conclusion is specific to the accepted configuration; changes
to native video, aspect selection, framebuffer mode or VRR require a new
audit. A surviving path is not exempted by an ignored empty-source exception.

## Verification during development

The Verilator testbenches under `sim/` (`make sim`) cover every RTL engine
in isolation (CMDQ decode/dispatch, BLIT/BLIT_COPY/BLIT_COPY_KEY pixel
semantics, the DDRAM adapter's read/write arbitration and 64-bit path,
LINK's ring buffer and completion fence, PRESENT's vblank/retirement
handshake, and SPRITE_BATCH decode/retirement) against modelled memory,
independent of Quartus or real hardware. Passing them never replaces
hardware acceptance of a new bitstream; `ai/core-log.md` records the
detailed history of what was tried, what failed, and what was fixed on the
way to this build.
