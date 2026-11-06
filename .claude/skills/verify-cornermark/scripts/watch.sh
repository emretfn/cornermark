#!/bin/bash
# watch.sh <seconds>: samples focus for that long and holds it to the recording rule. Run it in the background around a recording.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[ $# -eq 1 ] || die "usage: watch.sh <seconds>"
require_ours
out="$("$PROBE" "$PID" "$1")"
echo "$out" >> "$ROOT/focus.jsonl"
echo "focus $out"
violation="$(recording_focus_violation "$out")"
[ -z "$violation" ] || die "FAIL: $violation."
echo "recording focus rule holds: only the test window on screen, no focus change."
