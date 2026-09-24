# Build qualification

The living record of Noodles's builds: what was built, whether it closed
timing, whether it was validated on hardware, and where the artifact came
from. The build procedure itself is in [BUILD.md](BUILD.md).

## Summary

| # | Date | Build | Seed | RBF SHA-256 | Hardware status |
|---|---|---|---:|---|---|
| 2 | 2026-09-23 | **Current:** shared 100MHz clock, registered write ingress and slot enables, honest DDR3 constraints | 5 | `b76fb924…247b8d` | Accepted; clean-commit reproduction verified |
| 1 | 2026-09-22 | Historical: SPRITE_BATCH engine, 64-bit DDRAM path, PRESENT retirement-acknowledgement fix | 1 | `25f9d3a1…edba93` | Accepted -- see below |

## Current build (2)

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
