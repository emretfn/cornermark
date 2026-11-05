#!/bin/bash
# evidence.sh <name>: copy the proof of this run to $CORNERMARK_EVIDENCE_DIR/<name>. Run it before stop.sh, because doctor.txt fails once the instance is gone.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

[ $# -eq 1 ] || die "usage: evidence.sh <name>"
[ -n "${CORNERMARK_EVIDENCE_DIR:-}" ] || die "set CORNERMARK_EVIDENCE_DIR first."
load_state || die "no recorded instance."
out="$CORNERMARK_EVIDENCE_DIR/$1"
mkdir -p "$out"

app_log "$SINCE" > "$out/app.log"
tcc_log "$SINCE" > "$out/tccd.txt"
"$(dirname "$0")/doctor.sh" > "$out/doctor.txt" 2>&1
(cd "$ROOT" && find . -type f | sort) > "$out/root-files.txt"
[ -f "$ROOT/focus.jsonl" ] && cp "$ROOT/focus.jsonl" "$out/focus.jsonl"
ditto "$ROOT/History" "$out/History"
[ -d "$ROOT/saved" ] && ditto "$ROOT/saved" "$out/saved"
echo "evidence in $out"
