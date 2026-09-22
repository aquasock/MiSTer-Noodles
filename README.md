# MiSTer-Noodles

A little character that lives on the MiSTer's menu background.

The MiSTer's black-and-white static is generated inside the FPGA by the Menu
core and there is no way to composite over it from Linux -- when Main hands the
scaler to the Linux framebuffer, the framebuffer *replaces* the core's video. So
MiSTer-Noodles draws its own static (ported pixel-for-pixel from the Menu core's
RTL) and puts the pet on top of it. See [docs/mister-framebuffer.md](docs/mister-framebuffer.md)
for the full picture, including the `/dev/MiSTer_cmd` command set.

## Status

Step 1 of the plan: `src/spike_fb.c`, a dependency-free spike that proves the
display path on real hardware. No SDL yet -- SDL2 has no fbdev backend, so once
the spike is confirmed it gets wrapped in SDL surfaces + SDL2_image sprites with
this same mmap present path underneath.

## Confirmed on hardware (DE10-Nano, kernel 5.15.1-MiSTer, 2026-08-30)

`--info` against the real `/dev/fb0`:

    fb: id="MiSTer_fb" 1920x1080 (virtual 1920x1080) 32 bpp
    fb: line_length=7680 smem_len=8294400 smem_start=0x22001000 type=0 visual=2
    fb: R off=16 len=8  G off=8 len=8  B off=0 len=8  A off=0 len=0

`smem_start` is `FB_ADDR + 4096`, exactly the slot-0 offset from video.cpp:3491,
which confirms the memory map in the notes. The device reports ARGB even though
`/sys/module/MiSTer_fb/parameters/mode` says `rb=1`, so it is reporting the
post-swap layout -- what actually lands on screen still needs the bar test.

Static generator, measured on the Cortex-A9 with `--fake` (no framebuffer
touched, so this is generator cost only, excluding the present memcpy):

    320x240      327 fps
    640x480       82 fps
    1920x1080     12 fps

The framebuffer's default mode is 1920x1080, where full-screen animated static
cannot hold a frame rate. `fb_cmd1` at a small size is therefore required, not
just convenient -- and 320x240 leaves roughly 10x headroom for the sprite layer.

Still unverified, because both need the display: channel order as actually
scanned out, and whether Main picks up the synthetic F9 from a uinput device
created after boot.

## Build

    make          # static armv7 binary -> build/arm/misterpet-spike
    make host     # native binary for offscreen testing

The cross build uses `arm-linux-gnueabihf-gcc` and links statically: the MiSTer's
userland is glibc ~2.31, so a dynamically linked binary from a modern distro will
not load there.

## Try it without hardware

    ./build/host/misterpet-spike --fake 320x240 --seconds 2 --ppm /tmp/frame.ppm

Renders the static and the pet offscreen and dumps the last frame.

## Run it on the MiSTer

    make deploy HOST=192.168.1.42        # scp to /media/fat/pet (root / "1")

While the SD card is off limits, stage into RAM instead -- nothing touches
/media/fat and it is gone on the next reboot:

    HOST=10.10.0.30 scripts/stage.sh

Main only hands the scaler to `/dev/fb0` on an F9 keypress (`menu.cpp:1365`,
gated by `fb_terminal`, which defaults on). Either press F9 on the Menu core, or
synthesise it -- `build/arm/fbterm-toggle` creates a uinput keyboard and taps
F9, which is also how the boot daemon will do it. `scripts/hw-test.sh` drives
the whole sequence and restores the previously loaded core afterwards:

    MSH='ssh root@10.10.0.30' scripts/hw-test.sh pattern
    MSH='ssh root@10.10.0.30' scripts/hw-test.sh pet

Or step through it by hand. Over ssh:

    /media/fat/pet/misterpet-spike --info

Dumps what `/dev/fb0` actually is: resolution, bpp, stride, and the channel
offsets. If bpp is not 32, ask Main for an 8888 buffer first.

    /media/fat/pet/misterpet-spike --pattern --seconds 15

Four vertical bars, red / green / blue / white left to right, with a black
square in the top-left corner. If the colours come out in a different order the
framebuffer is misreporting its channel offsets -- rerun with `--pack argb`,
`--pack abgr`, etc. until they match, and note which one won.

    /media/fat/pet/misterpet-spike --fbcmd 320 240 --scale 3 --seconds 30

Asks Main for a 320x240 buffer (integer-upscaled and centred by the scaler),
then animates the static with the pet bouncing across it, and prints the frame
rate it managed. That number decides how much headroom there is for the real
thing.

Every run self-terminates after `--seconds` (default 20) and blanks the
framebuffer on the way out, so a bad run cannot leave the screen stuck. Press F9
again to give the display back to the Menu core.

Useful extras: `--vt 3` moves to an unused VT and sets KD_GRAPHICS so a getty
cannot scribble over the frame; `--fps N` caps the frame rate; `--keep` leaves
the last frame on screen.

## Boot integration

`install/user-startup.sh.example` goes to `/media/fat/linux/user-startup.sh`.
Nothing is installed into the rootfs -- MiSTer's Linux updates replace it.

## Layout

    src/spike_fb.c       the spike: fb open/mmap/present, MiSTer static, sprite
    src/fbterm_toggle.c  uinput F9 tap -- asks Main for the Linux framebuffer
    docs/                research notes on the MiSTer video path
    scripts/stage.sh     copy to /tmp on the MiSTer (RAM, no SD writes)
    scripts/hw-test.sh   full on-hardware run, restores the core afterwards
    scripts/deploy.sh    scp to /media/fat/pet
    install/             user-startup.sh example
# MiSTer-Noodles
