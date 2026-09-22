#!/bin/sh
# Copy the spike to the MiSTer. Default login is root, password "1".
#   scripts/deploy.sh 192.168.1.42
set -e

HOST="${1:-${MISTER_HOST:-mister.local}}"
DEST="${DEST:-/media/fat/pet}"
BINS="build/arm/misterpet-spike build/arm/fbterm-toggle build/arm/link-push build/arm/link-slot-dump build/arm/mem-scan"

for b in $BINS; do [ -f "$b" ] || { echo "missing $b -- run make first" >&2; exit 1; }; done

ssh "root@$HOST" "mkdir -p $DEST"
scp $BINS "root@$HOST:$DEST/"
echo
echo "on the MiSTer (Menu core, press F9 first to hand the framebuffer to Linux):"
echo "  $DEST/misterpet-spike --info"
echo "  $DEST/misterpet-spike --pattern --seconds 15"
echo "  $DEST/misterpet-spike --fbcmd 320 240 --seconds 30"
echo
echo "after loading the Noodles core, push a real host-driven command into LINK's ring buffer:"
echo "  $DEST/link-push"
echo
echo "diagnostics: dump a ring slot's raw words, or scan memory for a value:"
echo "  $DEST/link-slot-dump [slot_index]"
echo "  $DEST/mem-scan [base_hex] [size_bytes_hex] [target_value_hex]"
