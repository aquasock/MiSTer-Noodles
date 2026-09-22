# How the MiSTer gets pixels on screen

Notes from reading Main_MiSTer and Menu_MiSTer. Line numbers are from master as
of 2026-08-30.

## The static is FPGA-generated, so we replace it rather than draw over it

`Menu_MiSTer/menu.sv` (lines ~325-405) generates the menu background in RTL:

    rnd_c   = {rnd[0], rnd[1], rnd[2], rnd[2], rnd[2], rnd[2]}   // 6-bit noise
    cos_g   = cos(vvc + vc*4)[7:3] + 32                          // 6-bit gradient
    comp_v  = (cos_g >= rnd_c) ? (cos_g - rnd_c) << 2 : 0        // 8-bit grey
    VGA_R = VGA_G = VGA_B = comp_v

`vvc += 6` every frame, which is the slow vertical drift. The noise source
(`rtl/lfsr.v`) is a free-running combinational ring of `lcell`s sampled at pixel
clock -- genuinely random, not a reproducible sequence, so any decent PRNG is a
faithful stand-in. `rtl/cos.sv` is a 256-entry quarter table addressed by a
10-bit angle:

    ival = x[9] ^ x[8]
    y    = qcos[x[7:0] ^ {8{x[8]}}] ^ {~ival, {7{ival}}}
    qcos[i] = round(127.5 * cos(pi/2 * i/256)), clamped to 127

There is no alpha path from Linux into that video. When Main enables the MiSTer
framebuffer the ascal scaler outputs the framebuffer *instead of* the core's
video -- which is why setting a wallpaper makes the static disappear. So the pet
daemon draws its own static and owns the whole frame.

`src/spike_fb.c` ports all of the above (`cos_init`, `cos8`, `draw_static`).

## The framebuffer

`Main_MiSTer/video.cpp`:

- `FB_ADDR = 0x20000000 + 32MB = 0x22000000`, `FB_SIZE = 1920*1080` pixels
  (video.cpp:36-37), mapped as three buffers via `shmem_map` (video.cpp:2414).
- Slot 0 is the Linux framebuffer, `/dev/fb0`, backed by the `MiSTer_fb` kernel
  module. Main writes the mode to `/sys/module/MiSTer_fb/parameters/mode` as
  `fmt rb width height stride` (video.cpp:3465, 4307).
- Slots 1 and 2 are Main's own wallpaper double-buffer (video.cpp:3948-3955);
  `menu_bgn` flips between them on every redraw.
- `video_fb_enable(enable, n)` (video.cpp:3474) points the scaler at slot `n` and
  calls `input_switch(0)` for slot 0, i.e. input goes to Linux while the Linux
  framebuffer is up.
- Framebuffer resolution is the video mode divided by `fb_size` from MiSTer.ini
  (video.cpp:3556). `fb_size=4` gives a cheap quarter-res buffer.

## Getting the framebuffer displayed

Only Main can flip the scaler over, and there is no command for it. It happens:

- on **F9** on the Menu core (or Ctrl+Alt+F9 in a core), gated by `fb_terminal=1`
  in MiSTer.ini -- `menu.cpp:1365-1372` does `video_chvt(1); video_fb_enable(!state)`;
- when a script is launched from the OSD -- `menu.cpp:7414` does `video_chvt(2);
  video_fb_enable(1)` and runs the script on tty2 via agetty.

For an unattended daemon the options are to inject an F9 keypress with `uinput`,
or to install the pet as a Script and start it that way. Deferred until the
spike proves the drawing path.

## /dev/MiSTer_cmd

A FIFO created by Main (`input.cpp:4051, 5141`). The whole command set
(`input.cpp:6236-6265`):

    fb_cmd0 <fmt> <rb> <div>        # fb = screen/div
    fb_cmd1 <fmt> <rb> <w> <h>      # explicit size, integer-scaled and centred
    fb_cmd2 <fmt> <rb> <div>        # like fb_cmd0, skips the MiSTer_fb mode write
    video_mode <modeline>
    load_core <path>
    screenshot [scaled] [path]
    volume <0-7|mute|unmute>

`fmt` is 8888 / 1555 / 565 / 8; `rb` swaps red and blue. `fb_cmd*` is silently
ignored unless the Linux framebuffer is already active (`video_cmd` checks
`video_fb_state()`, video.cpp:4181), and on the Menu core `video_fb_state()` is
only true for slot 0 -- not while a wallpaper is showing.

`fb_cmd1 8888 1 320 240` is the useful one for us: a small buffer the scaler
upscales, so animation stays cheap on the Cortex-A9.

## Open question for v2

Drawing into slots 1/2 through `/dev/mem` would put the pet on screen while the
menu is actually in use, OSD and all. It needs the Menu's Background option set
to something non-zero, it races with Main's redraws, and it has to track which
slot `menu_bgn` currently points at. Revisit after v1 works.
