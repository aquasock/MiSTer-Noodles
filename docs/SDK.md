# Host SDK

`libnoodles.a` is a C99 static library with C++-compatible public headers
`noodles_link.h` and `noodles_surface.h`. SDK 0.6.0 uses hardware protocol 1.x to identify the live
800x600 core, claim one host session and detect reset before accepting a
fence as completed. Protocol 1.1 cores add opcode 7, BLIT_BLEND, and 1.2 cores add flagged
batch draws (blend, mirroring and RGBA modulation per draw) and 1.3 cores
explicit blend modes per draw; framebuffer
geometry and the 100MHz core clock are unchanged.

Use `noodles_link_open()` for the stage-2B core. The explicit
`noodles_link_open_legacy()` entry point remains for older unverified images;
it is not a fallback mode for a stage-2B core.

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
# On MiSTer, after the stage-2B core is loaded:
./sdk-smoke
```

It prints verified protocol, capability and geometry information, fills the
back buffer, presents, waits and closes. `/dev/mem` access normally requires
root.

## Hardware control block

The control block begins at physical `0x30020010`. All fields are
little-endian 32-bit words.

| Address | Owner | Meaning |
|---|---|---|
| `0x30020010` | FPGA | Magic `0x4e444c53`. Published last during initialization. |
| `0x30020014` | FPGA | Protocol version, major in bits 31:16 and minor in 15:0; `0x00010003` with explicit blend modes, `0x00010002` with flagged batch draws, `0x00010001` with BLIT_BLEND only, `0x00010000` before. |
| `0x30020018` | FPGA | Capability bits; bit N advertises opcode N: `0x000000fe` with BLIT_BLEND, `0x0000007e` before it. |
| `0x3002001c` | FPGA | Width in bits 31:16, height in bits 15:0. |
| `0x30020020` | FPGA | Framebuffer pitch in bytes. |
| `0x30020028/2c` | Host | 64-bit request token, low word then high word. |
| `0x30020030` | Host | Request sequence. |
| `0x30020038/3c` | FPGA | Echoed 64-bit response token. |
| `0x30020040` | FPGA | Echoed response sequence. |

On reset the FPGA disarms the command ring and clears request/response
sequences before publishing identity. A new host writes a random nonzero
64-bit token, then request sequence `0x434c414d`. The FPGA accepts that claim
only after ring-pointer initialization, echoes the token and sequence, and
then enables command polling. While active, it echoes nonzero non-claim
sequence changes only when the request token still matches. Request sequence
zero closes the hardware session and disables the ring.

Static magic alone is not proof of a live core because DDR3 survives reload.
The claim echo proves readiness; a fresh sequence echo validates liveness.
The protocol is correctness metadata and cooperative ownership, not an
authentication or security boundary.

## Verified lifecycle

`noodles_link_open(&device)` returns an opaque heap-allocated handle only
after checking magic, protocol major version 1 (any minor revision),
required opcode capabilities 1 through 6, 800x600 geometry and 3200-byte
pitch, then completing the live claim. Unexpected identity fails before the
SDK publishes commands. Minor revisions only add capabilities (LINK-012);
optional operations such as BLIT_BLEND check their capability bit on every
submission and fail with `ENOTSUP` without publishing when it is absent.

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
verified open fails with `EOWNERDEAD` while the hardware response still
shows the abandoned active session. After an actual core reload clears and
disarms the response, verified open may recover the dirty software marker
without a caller-supplied acknowledgement flag. The marker survives process
restart, not system reboot, and remains separate from hardware identity.

If the FPGA resets during a handle, the response clears and fallible SDK
operations fail with `ESTALE`. The reset fence value is never accepted as
completion without a fresh live challenge. A submission racing the reset may
already have been written to DDR3, but the reset hardware keeps the ring
disarmed; the SDK does not claim that work completed or was cancelled.

`noodles_link_close(device, timeout_ms)` uses one monotonic deadline to drain,
close the hardware session, release resources and free the handle. Check its
return value and discard the pointer in both cases. Only a successful drain
and hardware disarm mark the software session clean.

## Legacy lifecycle

`noodles_link_open_legacy(&device, ack_reload)` retains SDK 0.1 behavior for
the preserved pre-2B core images. The caller guarantees a matching,
initialized and quiescent SVGA core. Empty ring pointers cannot prove idle,
and reset cannot be detected. A dirty legacy marker requires an external
reload followed by `ack_reload=1`; the flag does not reload hardware.

The SDK refuses legacy attachment when it sees the current protocol
identity. Use verified open for the stage-2B core. For the older recovery
core, preserve and use its matching stage-2A binary package because static
control bytes can survive switching back from a newer core.

## Submission and completion

Draw submission stays nonblocking. A successful `noodles_push_*` means
published, not completed. Capture `noodles_link_last_fence(device)` after
success; there is no public baseline arithmetic or mapped-pointer access.
Tokens belong to that device session and retain the existing 31-bit modulo
count. Keep token distance below 2^30 completions and never compare with `>=`.

`noodles_link_poll(device, fence, &complete)` does not wait. On a verified
handle, a reached fence starts or checks a new hardware challenge; poll may
therefore report incomplete once after the raw count reaches its target.
It reports complete only after the matching live response arrives. Use
`noodles_link_wait(device, fence, timeout_ms)` for a monotonic deadline, or
`noodles_link_drain(device, timeout_ms)` for the last submitted command.
A zero timeout checks once and faults the handle if not complete; use poll
for ordinary nonblocking checks. Interrupted sleeps do not restart deadlines.
Waits sleep between checks with a backoff from 20us to a 0.1ms cap, and drop
back to 20us whenever a new challenge is issued, so a challenge (normally
answered within one 10us core poll period) costs about one short sleep rather
than a full backoff period. Sleeping a flat 1ms per check cost the canonical
one-batch `blit-bench` about 13% of its measured throughput.

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

## Errors and validation

Fallible APIs return 0 or `-1` with `errno`. Read-only scalar getters require
a valid live handle; they are observations, not health checks.

| Error | Meaning / action |
|---|---|
| `EAGAIN` | Ring/table busy or presentation not yet observed complete. Nothing new published; poll/drain as appropriate and retry. |
| `EBUSY` | Another SDK client owns the device, or legacy attachment sees a nonempty ring. |
| `EOWNERDEAD` | A dirty prior software session is still active in hardware; reload the core. |
| `ESTALE` | The verified hardware session was lost, normally by FPGA reset/reload. |
| `ENODEV` | The stage-2B identity magic is absent. |
| `EPROTONOSUPPORT` | Hardware protocol version is incompatible, or legacy open was attempted on the current protocol. |
| `ENOTSUP` | Required capabilities or fixed geometry do not match this SDK, or the attached core lacks an optional operation's capability bit. |
| `ETIMEDOUT` | Deadline expired; handle faulted, work not cancelled. |
| `EINVAL` | Invalid argument, unsupported command encoding, rectangle/alignment or address span. |
| `EPROTO` | Invalid ring index at attachment; do not write to that presumed device. |
| OS errors | Permission, mapping, allocation, clock or I/O failures; report them, do not retry as queue pressure. |

The SDK rejects unknown opcodes, nonzero reserved fields, zero-sized draws,
invalid batch counts/flags, truncated field widths, misalignment and
overflowing/out-of-envelope spans. This is stricter than the old raw
transport, whose zero-size/unknown commands could hang fence waits.

The SDK conservatively permits DDR3 spans only in
`[0x30000000, 0x40000000)`, excluding `[0x30020000, 0x30022800)` control
memory and the managed arena `[0x32000000, 0x40000000)`. Upload alone may write wholly inside the fixed descriptor table,
subject to its existing ownership protection. Board-SDRAM loads require
page-aligned destinations and 8-byte-aligned DDR3 sources with rounded-up
page backing storage. BLIT_BLEND additionally requires modulation in word 5 bits 7:0 only and
disjoint source and destination byte spans. These checks are **not allocation or isolation**:
the caller must still own every byte, respect scanout ownership, avoid
overlapping copies and retain all source data until completion.

Typed sprite-batch submission validates descriptors before uploading them.
The raw batch entry point validates the command only; callers manually
uploading descriptors remain responsible for their contents and must obey
the same limits. Raw memory diagnostics remain explicitly outside the SDK.

## Managed surfaces and texture cache

Include `noodles_surface.h` for SDK-owned XRGB8888 storage. The allocator owns
the explicit 224MiB physical arena `[0x32000000, 0x40000000)`. It uses
page-sized allocations and 64-byte row-pitch alignment; callers provide
dimensions, not addresses. Raw command and upload APIs reject every overlap
with this arena so unmanaged code cannot alias an active surface through the
SDK.

`noodles_surface_create()` returns an opaque surface. Partial
`noodles_surface_update()` and `noodles_surface_read()` require an entirely
in-bounds rectangle and a host pitch large enough for one row. They wait with
the caller's bounded timeout if GPU work still references that surface.
Surface fill and copy operations clip signed rectangles against source and
destination bounds before publishing a command. Same-surface copies remain
unsupported because hardware overlap semantics are undefined.

`noodles_surface_destroy()` is nonblocking and invalidates the handle. Its
physical extent enters a deferred-free list and cannot be reused until the
surface's last command fence has completed and, on verified hardware, the
live-session challenge succeeds. `noodles_surface_collect()` reaps completed
frees; allocation also collects opportunistically. Closing the link drains
the command stream and releases all allocator metadata, but applications
must not retain surface or cache pointers after close.

`noodles_surface_blend()` and `noodles_surface_blend_to_back_buffer()` clip
exactly like the copy calls, then submit BLIT_BLEND (BLIT-007): each source
pixel's high byte is straight alpha, scaled by the call's `alpha_mod`
(255 leaves it unchanged), composited source-over with SDL 2.32.10's generic
truncating arithmetic. Pixels with zero effective alpha leave the
destination unchanged, and destination alpha is updated as `a + (255-a)dA/255`.
Upload blended sources with a meaningful high byte; `noodles_rgb()` leaves it
zero, which is fully transparent. `noodles_texture_cache_blend_to_back_buffer()`
submits one blended cached cell per call.

`noodles_surface_draw_batch()` and `noodles_texture_cache_draw_batch_to_back_buffer()`
submit up to 64 draws as one `SPRITE_BATCH`, into the back buffer or (for
surfaces) into another managed surface. Each draw carries `NOODLES_DRAW_*`
flags and a 32-bit `modulation`: the colour key for `NOODLES_DRAW_KEY`,
otherwise an RGBA modulation (R in bits 7:0 ... A in 31:24, `0xffffffff` for
none) applied as SDL's colour and alpha modulation before an optional
source-over blend (BLIT-008). Mirroring is applied before clipping, so a
mirrored draw hanging off an edge shows the correct part of its source.
Draws run in order and see earlier draws' results. Flagged draws need a
protocol 1.2 core and fail with `ENOTSUP`, publishing nothing, on older
ones; a keyed draw cannot also be flagged, and a surface cannot draw onto
itself.

`NOODLES_DRAW_MODE` (protocol 1.3, BLIT-009) replaces `NOODLES_DRAW_BLEND`
with an explicit mode built by `NOODLES_DRAW_BLEND_MODE(color_src, color_dst,
color_op, alpha_src, alpha_dst, alpha_op)` from `NOODLES_BLENDFACTOR_*` and
`NOODLES_BLENDOP_*`, which use SDL's `SDL_BlendFactor`/`SDL_BlendOperation`
numbering so `SDL_ComposeCustomBlendMode()` descriptions map across
unchanged. `NOODLES_DRAW_MODE_ADD`, `_MOD` and `_MUL` reproduce SDL 2.32.10's
software modes bit-exactly (MUL adds `NOODLES_DRAW_SINGLE_ROUNDING`), and
`NOODLES_DRAW_MODE_STENCIL_ALPHA` keeps the destination colour while scaling
its alpha by one minus the source alpha, GemRB's wall-occlusion pass.
SDL's software renderer has no composed modes, so their arithmetic is the
project's own: each term is `floor(value * factor / 255)`, combined by the
operation and clamped to 0-255, with minimum and maximum comparing the raw
values. Malformed modes fail with `EINVAL`; modes on a pre-1.3 core fail
with `ENOTSUP`.

The fixed-cell `noodles_texture_cache` packs same-sized images into one
managed atlas and addresses them with application-defined 64-bit keys.
Uploads replace the least-recently-used cell when full and wait only if that
specific cell is still in flight. Batched draws clip visible cells and use
the existing 64-entry `SPRITE_BATCH` operation. This is a generic residency
helper rather than a tilemap ABI: engines remain responsible for map layout,
animation and choosing visible keys. The `tile-cache-demo` workload scrolls
154 visible 64x64 tiles through a 256-cell atlas.

## Migration and scope

New consumers use an opaque pointer from `noodles_link_open()`, handle uniform
`-1/errno` errors, use fence tokens and check bounded close. Device
information now includes the hardware protocol version and
`hardware_verified=1`. Repository draw tools use verified open. There is no
stable shared-library ABI promise in this static-only pre-1.0 SDK.

No SDL code, runtime resolution switch or automatic core reload is included.
Managed surfaces and the texture cache are host-SDK facilities that work
over protocol 1.0 through 1.3; SDK 0.4 added BLIT_BLEND for protocol 1.1
cores, SDK 0.5 flagged batch draws for protocol 1.2 cores and SDK 0.6
explicit blend modes for protocol 1.3 cores.

## Stage-2A hardware execution

Source `775405d` was exercised on the accepted SVGA seed7 core without
reloading or rebuilding the FPGA. The independently installed ARM consumer
ran twice in succession, reporting the unverified 800x600/3200-byte-pitch
contract and completing fill/present/close both times. The migrated stress
tool completed 227 frames in 15 seconds (15.1fps) with 256 sprites, four
batches and 128x128 source art. Short three-second clear/present and
present-only runs reported 60.5fps and 60.3fps respectively. Every command
exited successfully, and the session marker was clean afterward.

FTP readback verified these separately named binaries under `/media/fat/pet`:

| Binary | SHA256 |
|---|---|
| `sdk-smoke-2a` (installed ARM consumer) | `c05b8886bd177d7ef89d641dbfbdbe4f183f26f56f0b2fedd96d4fd0d79fec67` |
| `stress-demo-sdk` | `16e94b09f79dcca427a314758f6556f9219822f106e371412c94f9671e995b72` |

An extended hardware run on the same binaries completed 905 frames in
60 seconds (15.1fps). A concurrent smoke consumer was rejected with
`EBUSY` and exit status 1 while the original producer continued normally.
Key-checker with 64 sprites at 128x128 completed 301 frames in ten seconds
(30.1fps). A three-second uncapped run measured 74.89 Mpixel/s; this is a
short sample, not a controlled comparison with the older host tool.
Five-second clear/present and present-only runs reported 60.4fps and
60.3fps. A final smoke consumer reopened successfully and left the marker
clean. No unexpected failures or timeouts were reported.

These are host execution results, not a new visual acceptance or exhaustive
pixel comparison. Timeout and crash-recovery cases are covered by the
mocked host regression; no reset was induced on the device.
