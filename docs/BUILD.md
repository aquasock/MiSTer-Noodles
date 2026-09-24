# Building

Target: Cyclone V `5CSEBA6U23I7` (DE10-Nano-compatible MiSTer), Quartus Prime
Lite 17.0.2 Build 602.

## Quick start

```sh
make            # cross-build the ARM-side host tools (static, armv7/Cortex-A9)
make host       # native build of the same tools, for the desktop
make sim        # Verilator RTL simulation (rtl/ engines, no Quartus needed)
make test-host  # mocked transport and SDK lifecycle tests
make test-sdk-install # installed SDK consumers, native C/C++ and ARM
quartus_sh --flow compile Noodles   # full FPGA build -> output_files/Noodles.rbf
quartus_sta -t tools/report_timing.tcl
quartus_sta -t tools/report_multicorner.tcl  # required post-fit timing gate
```

`Noodles.qsf` pins the fitter settings used by the accepted protocol 1.4 and
protocol 1.5 seed-13 builds (see below).
The Quartus project is named `Noodles`, so a full build writes
`output_files/Noodles.rbf`.

`make sdk` / `make sdk-host` build the static SDK independently of the demos.
See [SDK.md](SDK.md) for staged installation, pkg-config and external consumers.
SDK stage 2A was host-only. The stage-2B live identity/session protocol adds
FPGA RTL and therefore requires a new full build, timing qualification and
hardware validation.

## Two levels of build

**Fast sanity check** -- analysis and synthesis only (`quartus_map Noodles -c
Noodles`): elaborates and maps the design, no placement or routing. Takes
under a minute on this design. Good for catching a typo, a missing module or
a broken instantiation after a source change. It does **not** produce a
working bitstream and says nothing about timing.

**Full build** -- `quartus_sh --flow compile Noodles`: the complete compile
flow (analysis and synthesis, fit, assembler, and the flow's own built-in
timing pass), producing an actual `.rbf` and `.sof` to run on hardware. Takes
a few minutes on this design (it is far smaller than a typical whole-system
MiSTer core). A successful compile alone is not timing acceptance: inspect
the reports and run the post-fit checks below before hardware qualification.

Neither level substitutes for the other: a clean fast check only proves the
design elaborates; timing acceptance requires analysis of the completed fit.

## Reproducing a bitstream bit for bit

Three settings must match for a build to reproduce a previously validated
result -- all three are already pinned in `Noodles.qsf`, committed to source
control, so an ordinary clone and build reproduces them automatically:

- `SEED` (currently `13`) -- Quartus's fitter uses its seed as the starting
  point for placement search; a different seed can produce meaningfully
  different placement, routing and timing closure on the *same* source.
- `NUM_PARALLEL_PROCESSORS` (currently `16`) -- fitter thread count. This
  affects fitter scheduling and is not guaranteed to reproduce identical
  placement if changed, even with the same seed.
- `ALM_REGISTER_PACKING_EFFORT` (currently `MEDIUM`).

Use the exact qualified source revision, Quartus version, these settings,
and the recorded build date. Matching settings alone is not proof of
reproducibility; compare the resulting RBF hash against
[QUALIFICATION.md](QUALIFICATION.md).

The current accepted source is protocol 1.6 with SDK 0.10 and fill batches.
Its seed-13 build passes all four timing corners and is the pinned
hardware-accepted image; seed 7 fails slow -40C setup. Use
`SOURCE_DATE_EPOCH=1790121600` and compare accepted reproductions against the
protocol 1.6 seed-13 hash in
[QUALIFICATION.md](QUALIFICATION.md).

```sh
git checkout --detach d1702b435134b6994b2062353b104e0cde40a7c6
SOURCE_DATE_EPOCH=1790121600 quartus_sh --flow compile Noodles
quartus_sta -t tools/report_timing.tcl
quartus_sta -t tools/report_multicorner.tcl
sha256sum output_files/Noodles.rbf
```

The previous protocol 1.4 fallback remains reproducible from the pinned source
below. It passed exact-pixel hardware diagnostics, HDMI audio and the
MiSTer-GemRB AR4000 workload.

```sh
git checkout --detach 042b62ce9aefd1d34d167916ccffff930512e8e6
SOURCE_DATE_EPOCH=1790121600 quartus_sh --flow compile Noodles
quartus_sta -t tools/report_timing.tcl
quartus_sta -t tools/report_multicorner.tcl
sha256sum output_files/Noodles.rbf
```

For the older accepted 640x480 build, use a clean checkout without prior Quartus
databases and run:

```sh
git checkout --detach c3d04ab68dd1d2f14ba7bd858f6cfe98c1508e86
SOURCE_DATE_EPOCH=1790121600 quartus_sh --flow compile Noodles
quartus_sta -t tools/report_timing.tcl
sha256sum output_files/Noodles.rbf
```

The epoch pins `BUILD_DATE` to `260923` in UTC. The small project adaptation
in `sys/build_id.tcl` honors this input; without it, normal builds retain the
framework's local-calendar-date behavior. All synthesis and fitter inputs
must also match; do not assume a different date changes only a few RBF bytes.

## Post-fit timing qualification

Run both reporting scripts against the completed project's database:

```sh
quartus_sta -t tools/report_timing.tcl
quartus_sta -t tools/report_multicorner.tcl
```

The first retains detailed queue/bridge diagnostics. The second iterates
every operating condition returned by TimeQuest for the fitted device and
configured temperature range. For the accepted device/settings these are
slow and fast models at 1.1V, each at -40C and +100C. It checks global setup,
hold, recovery, removal and minimum pulse width, plus core-clock setup/hold,
and verifies exactly one 100MHz core PLL output at each corner.

Reports and `summary.tsv` go into `output_files/multicorner/`. The summary's
path count is the number of worst paths reported, not the total number of
timed paths. The command exits with an error for negative slack, missing
timing evidence or an unexpected core clock. Require a successful exit and
the final `Multi-corner timing PASS` message; a partial summary is not a pass.
Quartus warnings must still be reviewed, including any changes from the
twelve audited warnings in [QUALIFICATION.md](QUALIFICATION.md).

`TIMEQUEST_MULTICORNER_ANALYSIS` stays OFF in the QSF to preserve the accepted
build settings; this explicit post-fit gate supplies the additional coverage
without changing placement/routing or the RBF. It does not validate omitted
constraints or replace board-I/O and hardware qualification.

The script was added after source `c3d04ab`. To analyze that exact historical
checkout, invoke the newer script by absolute path while the working
directory is the historical compiled project. Do not copy newer synthesis
inputs into the reproduction checkout.

`make test-timing` runs the reporting script against mocked TimeQuest
commands to check its failure handling, corner iteration and clock guards.
This needs Tcl (`TCLSH` may override `tclsh`) but no fitted database, and is
not a substitute for actual TimeQuest analysis.

## Known gotchas

- **A killed or interrupted build leaves partial state behind** (fit
  database, incremental database, output files, the generated build-
  identifier file). Clear it (`rm -rf db incremental_db output_files
  build_id.v`) before relaunching rather than letting the next run reuse
  stale partial results.
- **The build-identifier file (`build_id.v`) is regenerated on every
  build.** A pre-flow step (`sys/build_id.tcl`, wired in via
  `PRE_FLOW_SCRIPT_FILE` in `Noodles.qsf`) produces it; it is not checked-in
  source (`.gitignore`'d) and carries only a `YYMMDD` date stamp used for the
  OSD version string. The date is a synthesis input embedded in the bitstream.
  Set `SOURCE_DATE_EPOCH` as above for reproduction across calendar days.
- Running `quartus_map` directly against the live project for a quick
  sanity check is safe on this project (unlike some MiSTer cores) since
  `Noodles.qsf` does not source a separate platform pin-assignment fragment
  that a bare synthesis run could accidentally rewrite; still, diff
  `Noodles.qsf` after any Quartus-driven run before committing, on general
  principle.

## Keeping the source tree clean

Every artifact Quartus or the Makefile produces (`db/`, `incremental_db/`,
`output_files/`, the ARM/host tool binaries under `build/`, the Verilator
sim binaries under `build/sim/`, every `.rpt`/`.smsg`/`.summary`, the
generated `build_id.v`, and `jtag.cdf`) belongs outside the committed source
tree -- `.gitignore` covers all of it (`/build/`, `output_files`,
`build_id.v`, etc.). Nothing generated should ever be `git add`'d; if it
happens by accident, `git rm --cached` it and confirm `.gitignore` covers
the path. `.gitattributes` stores every file byte for byte (`* -text`): the
vendored MiSTer framework in `sys/` has mixed line endings, and letting an
editor or Git normalize them turns a two-line change into a whole-file diff
and risks breaking byte-for-byte bitstream reproduction from source.

## Deploying

```sh
scripts/deploy.sh [mister-host]                       # copies build/arm/* + assets/ over scp
scp output_files/Noodles.rbf root@<host>:/media/fat/pet/
ssh root@<host> 'echo load_core /media/fat/pet/Noodles.rbf > /dev/MiSTer_cmd'
```

## Verification benches

`make sim` runs the Verilator testbenches under `sim/` against every RTL
engine (CMDQ/BLIT/LINK/DDRAM adapter/PRESENT/SPRITE_BATCH/FILL_BATCH) with no Quartus
or hardware required; it is the fast, iterate-on-RTL check. It does not
replace a full Quartus build's timing pass, and neither replaces hardware
acceptance of a new bitstream.
