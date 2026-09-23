#!/bin/sh
# Copy the host-side tools to the MiSTer. Default login is root, password "1".
#   scripts/deploy.sh 192.168.1.42
set -e

HOST="${1:-${MISTER_HOST:-mister.local}}"
DEST="${DEST:-/media/fat/pet}"
BINS="build/arm/link-push build/arm/link-slot-dump build/arm/mem-scan build/arm/blit-copy-push build/arm/solid-fill-push build/arm/blit-copy-key-push build/arm/bench build/arm/present-demo build/arm/sprite-demo build/arm/load-bmp build/arm/stress-demo build/arm/present-probe-dump"
ASSETS="assets/sprite.bmp"

for b in $BINS; do [ -f "$b" ] || { echo "missing $b -- run make first" >&2; exit 1; }; done

ssh "root@$HOST" "mkdir -p $DEST/assets"
scp $BINS "root@$HOST:$DEST/"
scp $ASSETS "root@$HOST:$DEST/assets/"
echo
echo "after loading the Noodles core, push a real host-driven command into LINK's ring buffer:"
echo "  $DEST/link-push"
echo
echo "diagnostics: dump a ring slot's raw words, or scan memory for a value:"
echo "  $DEST/link-slot-dump [slot_index]"
echo "  $DEST/mem-scan [base_hex] [size_bytes_hex] [target_value_hex]"
echo
echo "prove BLIT_COPY over LINK (fills a source rect, then copies it into view):"
echo "  $DEST/blit-copy-push [r_hex] [g_hex] [b_hex]"
echo
echo "fill an arbitrary rect (e.g. a sub-region of the visible surface):"
echo "  $DEST/solid-fill-push <dst_addr_hex> <pitch_dec> <width_dec> <height_dec> <r_hex> <g_hex> <b_hex>"
echo
echo "prove BLIT_COPY_KEY (colorkey transparency): a red square with a magenta"
echo "colorkey border, composited onto a blue background -- border shouldn't overwrite it:"
echo "  $DEST/blit-copy-key-push"
echo
echo "benchmark the real end-to-end command path (push -> dispatch -> execute -> fence):"
echo "  $DEST/bench"
echo
echo "prove OUT-004 double buffering: cycles through solid colors, filling the"
echo "current back buffer and presenting -- should look clean, no tearing:"
echo "  $DEST/present-demo [seconds_per_color]"
echo
echo "the real target: a sprite bouncing around the screen continuously,"
echo "the full per-frame game-loop pattern (clear, composite, present):"
echo "  $DEST/sprite-demo [seconds]"
echo
echo "load a real 24-bit uncompressed BMP and display it (noodles_link_upload,"
echo "mmap+memcpy straight into DDR3, no ring/BLIT engine involved):"
echo "  $DEST/load-bmp <file.bmp> [x] [y]"
echo
echo "stress test: N independently-bouncing copies of a loaded sprite asset,"
echo "composited every frame (default asset assets/sprite.bmp, a 48x48"
echo "magenta-colorkeyed smiley):"
echo "  $DEST/stress-demo [sprite.bmp] [count] [seconds]"
echo "  e.g.: cd $DEST && ./stress-demo assets/sprite.bmp 10 15"
