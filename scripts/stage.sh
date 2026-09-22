#!/bin/sh
# Copy the binaries to /tmp/pet on the MiSTer -- RAM only, nothing on the SD
# card, gone on reboot. Use this while the SD is off limits; scripts/deploy.sh
# is the real install to /media/fat/pet.
set -e

HOST="${HOST:-10.10.0.30}"
MSH="${MSH:-ssh root@$HOST}"
REMOTE="${REMOTE:-/tmp/pet}"

$MSH "mkdir -p $REMOTE"
for b in misterpet-spike fbterm-toggle; do
	[ -f "build/arm/$b" ] || { echo "missing build/arm/$b -- run make first" >&2; exit 1; }
	$MSH "cat > $REMOTE/$b; chmod +x $REMOTE/$b" < "build/arm/$b"
	echo "staged $b"
done
$MSH "ls -l $REMOTE"
