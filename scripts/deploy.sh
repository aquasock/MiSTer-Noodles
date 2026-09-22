#!/bin/sh
# Copy the host-side tools to the MiSTer. Default login is root, password "1".
#   scripts/deploy.sh 192.168.1.42
set -e

HOST="${1:-${MISTER_HOST:-mister.local}}"
DEST="${DEST:-/media/fat/pet}"
BINS="build/arm/link-push build/arm/link-slot-dump build/arm/mem-scan build/arm/blit-copy-push build/arm/solid-fill-push"

for b in $BINS; do [ -f "$b" ] || { echo "missing $b -- run make first" >&2; exit 1; }; done

ssh "root@$HOST" "mkdir -p $DEST"
scp $BINS "root@$HOST:$DEST/"
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
