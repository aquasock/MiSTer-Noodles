# Host SDK, stage 2A

`libnoodles.a` is a C99 static library with a C++-compatible public header
`noodles_link.h`. SDK version 0.1.0 is independent of the FPGA command
protocol. This is a host-only change: the accepted 800x600 seed7 RBF and its
100MHz clock are unchanged.

**Every connection is legacy/unverified.** The current FPGA has no live
identity, capability, readiness or reset-generation handshake. Information
returned by this SDK is the compiled-in SVGA contract, not a hardware probe.
Stage 2B must supply that protocol before applications can discover a core
safely. Do not use this SDK with another core or the 640x480 fallback.

## Build and install

```sh
make sdk                 # static ARMv7 hard-float library and sdk-smoke
make sdk-host            # native library and sdk-smoke
make install-sdk SDK_TARGET=arm PREFIX=/usr DESTDIR="$PWD/build/stage"
```

Override `CROSS` for another compatible ARM cross-toolchain. `SDK_TARGET`
is `arm` by default, or `host` for a native installation. `PREFIX` is the
runtime installation prefix; `DESTDIR` stages it without installing into the
build machine's system directories. Only the public header, archive and
`lib/pkgconfig/noodles.pc` are installed; internal transport state is private.

Compile an independent ARM consumer against that staged SDK:

```sh
export PKG_CONFIG_LIBDIR="$PWD/build/stage/usr/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$PWD/build/stage"
arm-linux-gnueabihf-gcc -static $(pkg-config --cflags noodles) \
    examples/sdk_smoke.c $(pkg-config --libs noodles) -o build/consumer
```

`make test-host` exercises transport and SDK lifecycle behavior without
hardware. `make test-sdk-install` stages native/ARM packages and compiles
separate C and C++ consumers using only installed files and `pkg-config`.
The example is also the device-info/smoke tool:

```sh
# On MiSTer, after the matching SVGA core is loaded, initialized and idle:
./sdk-smoke --legacy-svga
```

It prints the assumed geometry and unverified status, fills the back buffer,
presents, waits and closes. `/dev/mem` access normally requires root.

## Lifecycle

`noodles_link_open_legacy(&device, 0)` returns an opaque heap-allocated handle.
The explicit legacy entry point means the caller guarantees the matching
core is initialized and quiescent, and that no old tool is still using it.
The SDK checks ring indices and refuses a visibly nonempty ring, but **an
empty ring is not proof that its last dispatched command completed**.

Calls must be serialized by the application. A nonblocking `flock` on
`/run/noodles.lock` excludes other cooperating SDK clients, including
other handles in the same process. No daemon or kernel driver is installed.
Do not unlink/replace that lock file while applications are running. The
handle must not be used across `fork`; a child should exec or exit without
touching it. Old tools, direct `/dev/mem` access and other processes using
different locking conventions bypass this exclusion.

The lock file also records clean/dirty sessions. Opening marks it dirty;
a successful drained close marks it clean. Process death or a failed
shutdown leaves it dirty even though the OS releases the lock. A subsequent
normal open fails with `EOWNERDEAD` rather than assuming abandoned work is
safe to overwrite. This marker survives process restart, not system reboot,
and is not a hardware identity or reset counter.

To recover, stop all producers, explicitly reload the matching core and
allow initialization to finish. Only then may the caller use
`noodles_link_open_legacy(&device, 1)` or:

```sh
./sdk-smoke --legacy-svga --ack-core-reload
```

This flag acknowledges an action the caller already performed. It does not
load/reset the core, prove idle, or bypass an active process lock. Never
automatically retry with it after an error.

Reset or core replacement during an open handle remains unsupported and
cannot reliably be detected in 2A. A reset may make old fence values appear
complete; do not rely on a timeout to detect it.

## Submission and completion

Draw submission stays nonblocking. A successful `noodles_push_*` means
published, not completed. Capture `noodles_link_last_fence(device)` after
success; there is no public baseline arithmetic or mapped-pointer access.
Tokens belong to that device session and retain the existing 31-bit modulo
count. Keep token distance below 2^30 completions and never compare with `>=`.

`noodles_link_poll(device, fence, &complete)` does not wait. Use
`noodles_link_wait(device, fence, timeout_ms)` for a monotonic deadline, or
`noodles_link_drain(device, timeout_ms)` for the last submitted command.
A zero timeout checks once and faults the handle if not complete; use poll
for ordinary nonblocking checks. Interrupted sleeps do not restart deadlines.

`noodles_push_present(device, &fence)` submits exactly one flip, separately
from waiting. While that flip is pending, drawing, uploads and another
PRESENT return `EAGAIN`. Poll/wait observes retirement and refreshes the
back-buffer role; only then query `noodles_link_back_buffer()` for the next
frame. This also applies to raw opcode-4 submissions. The convenience
`noodles_present_and_wait()` submits once and waits up to 2000ms.

On a wait timeout or clock/sleep failure the handle is faulted. Further
work is rejected with that error; even late completion does not restore it.
**Timeout does not cancel queued work or a flip.** Do not resubmit that
command, reuse its memory or infer the visible buffer from the failure.

`noodles_link_close(device, timeout_ms)` attempts to drain and always frees
the handle and releases local resources, whether it succeeds or fails.
Check its return value and discard the pointer in both cases. Failure leaves
the session dirty; a clean close is not a substitute for externally ensuring
the core was never reset.

## Errors and validation

Fallible APIs return 0 or `-1` with `errno`. Read-only scalar getters require
a valid live handle; they are observations, not health checks.

| Error | Meaning / action |
|---|---|
| `EAGAIN` | Ring/table busy or presentation not yet observed complete. Nothing new published; poll/drain as appropriate and retry. |
| `EBUSY` | Another SDK client owns the device, or legacy attachment sees a nonempty ring. |
| `EOWNERDEAD` | A dirty prior session requires explicit external core reload. |
| `ETIMEDOUT` | Deadline expired; handle faulted, work not cancelled. |
| `EINVAL` | Invalid argument, unsupported command encoding, rectangle/alignment or address span. |
| `EPROTO` | Invalid ring index at attachment; do not write to that presumed device. |
| OS errors | Permission, mapping, allocation, clock or I/O failures; report them, do not retry as queue pressure. |

The SDK rejects unknown opcodes, nonzero reserved fields, zero-sized draws,
invalid batch counts/flags, truncated field widths, misalignment and
overflowing/out-of-envelope spans. This is stricter than the old raw
transport, whose zero-size/unknown commands could hang fence waits.

This stage conservatively permits DDR3 spans only in
`[0x30000000, 0x40000000)`, excluding `[0x30020000, 0x30022800)` control
memory. Upload alone may write wholly inside the fixed descriptor table,
subject to its existing ownership protection. Board-SDRAM loads require
page-aligned destinations and 8-byte-aligned DDR3 sources with rounded-up
page backing storage. These checks are **not allocation or isolation**:
the caller must still own every byte, respect scanout ownership, avoid
overlapping copies and retain all source data until completion.

Typed sprite-batch submission validates descriptors before uploading them.
The raw batch entry point validates the command only; callers manually
uploading descriptors remain responsible for their contents and must obey
the same limits. Raw memory diagnostics remain explicitly outside the SDK.

## Migration

The C API is intentionally source-incompatible with stack-allocated demo
handles: use an opaque pointer and explicit legacy open, handle uniform
`-1/errno` errors, use fence tokens and check bounded close. There is no
stable shared-library ABI promise in this static-only milestone.
Repository draw tools now link the archive and use SDK completion helpers;
they print the legacy attachment assumption instead of claiming detection.

No SDL code, runtime resolution switch, capability negotiation, texture
allocator, automatic recovery or new FPGA drawing operations are included.
