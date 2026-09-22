#!/bin/sh
# Run the spike on a real MiSTer and put the machine back how it was found.
#
# Takes over the display: loads the Menu core, hands the scaler to the Linux
# framebuffer, draws, then restores both. Nothing is written to the SD card --
# the binaries are expected in /tmp/pet on the device (see scripts/stage.sh).
#
#   MSH='ssh root@10.10.0.30' scripts/hw-test.sh pattern
#   MSH='ssh root@10.10.0.30' scripts/hw-test.sh pet
#
# MSH is how to run a command on the MiSTer; default assumes key auth.
set -e

HOST="${HOST:-10.10.0.30}"
MSH="${MSH:-ssh root@$HOST}"
REMOTE="${REMOTE:-/tmp/pet}"
MODE="${1:-pet}"
SECONDS_RUN="${SECONDS_RUN:-20}"

say() { printf '\n== %s ==\n' "$1"; }

say "current state"
PREV_CORE=$($MSH 'cat /tmp/CORENAME 2>/dev/null || echo unknown')
echo "core: $PREV_CORE"
$MSH "cat /sys/module/MiSTer_fb/parameters/mode; echo"

say "switching to the Menu core"
$MSH 'echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd'
sleep 6
$MSH 'cat /tmp/CORENAME; echo'

say "handing the framebuffer to Linux (synthetic F9)"
$MSH "$REMOTE/fbterm-toggle -v"
sleep 2
$MSH "$REMOTE/misterpet-spike --info"

case "$MODE" in
pattern)
	say "colour bars -- expect RED GREEN BLUE WHITE left to right, black square top-left"
	$MSH "$REMOTE/misterpet-spike --pattern --seconds $SECONDS_RUN"
	;;
pet)
	say "static + pet at 320x240"
	$MSH "$REMOTE/misterpet-spike --fbcmd 320 240 --scale 3 --seconds $SECONDS_RUN"
	;;
*)
	echo "unknown mode: $MODE (want 'pattern' or 'pet')" >&2
	exit 2
	;;
esac

say "giving the display back"
$MSH "$REMOTE/fbterm-toggle" || true
sleep 1

if [ "$PREV_CORE" != "unknown" ] && [ "$PREV_CORE" != "MENU" ]; then
	say "restoring $PREV_CORE"
	RBF=$($MSH "ls /media/fat/${PREV_CORE}_*.rbf 2>/dev/null | tail -1")
	if [ -n "$RBF" ]; then
		$MSH "echo \"load_core $RBF\" > /dev/MiSTer_cmd"
		sleep 6
		$MSH 'cat /tmp/CORENAME; echo'
	else
		echo "could not find an rbf for $PREV_CORE -- reload it from the OSD" >&2
	fi
fi
