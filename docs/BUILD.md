# Building

Target: Cyclone V `5CSEBA6U23I7` (DE10-Nano-compatible MiSTer), Quartus Prime
Lite 17.0.2 Build 602.

## Quick start

```sh
make            # cross-build the ARM-side host tools (static, armv7/Cortex-A9)
make host       # native build of the same tools, for the desktop
make sim        # Verilator RTL simulation (rtl/ engines, no Quartus needed)
quartus_sh --flow compile Noodles   # full FPGA build -> output_files/Noodles.rbf
```

`Noodles.qsf` pins the fitter settings for the accepted seed-5 build
(see below); the Quartus project is named
`Noodles`, so a full build writes `output_files/Noodles.rbf`.

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
MiSTer core). Only a full build proves the design meets timing and is safe
to load.

Neither level substitutes for the other: a clean fast check only proves the
design elaborates, and only a full build proves it meets timing.

## Reproducing a bitstream bit for bit

Three settings must match for a build to reproduce a previously validated
result -- all three are already pinned in `Noodles.qsf`, committed to source
control, so an ordinary clone and build reproduces them automatically:

- `SEED` (currently `5`) -- Quartus's fitter uses its seed as the starting
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

For the accepted 2026-09-23 build, use a clean checkout without prior Quartus
databases and run:

```sh
SOURCE_DATE_EPOCH=1790121600 quartus_sh --flow compile Noodles
quartus_sta -t tools/report_timing.tcl
sha256sum output_files/Noodles.rbf
```

The epoch pins `BUILD_DATE` to `260923` in UTC. The small project adaptation
in `sys/build_id.tcl` honors this input; without it, normal builds retain the
framework's local-calendar-date behavior. All synthesis and fitter inputs
must also match; do not assume a different date changes only a few RBF bytes.

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
engine (CMDQ/BLIT/LINK/DDRAM adapter/PRESENT/SPRITE_BATCH) with no Quartus
or hardware required; it is the fast, iterate-on-RTL check. It does not
replace a full Quartus build's timing pass, and neither replaces hardware
acceptance of a new bitstream.
