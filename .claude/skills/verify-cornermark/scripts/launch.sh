#!/bin/bash
# launch.sh: start one isolated, background Cornermark Dev from this worktree and record its PID.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

if load_state && [ "$(instance_status)" = ours ]; then
    echo "already running: pid=$PID root=$ROOT"
    exit 0
fi

others="$(pids_of_worktree_binary | tr '\n' ' ')"
[ -z "$others" ] || die "this worktree's app is already running outside the skill (pid $others). A link could reach it, so nothing was started. Ask its owner to quit it."

if [ ! -x "$BIN" ] || [ -n "$(find "$WORKTREE/Sources" "$WORKTREE/Resources" -type f -newer "$BIN" | head -1)" ]; then
    "$WORKTREE/scripts/build-app.sh"
fi

mkdir -p "$VERIFY_DIR"
if [ ! -x "$PROBE" ] || [ "$(dirname "$0")/focus-probe.swift" -nt "$PROBE" ]; then
    swiftc -O "$(dirname "$0")/focus-probe.swift" -o "$PROBE"
fi

RUN="$(date +%Y%m%d-%H%M%S)-$$"
# CORNERMARK_VERIFY_ROOT reopens an earlier run's root, so a relaunch finds what the last instance left, such as a cut-off recording.
ROOT="${CORNERMARK_VERIFY_ROOT:-${TMPDIR%/}/cornermark-verify/$RUN}"
is_protected_path "$ROOT" && die "refused: root $ROOT would raise a permission dialog. Nothing was started. Point TMPDIR elsewhere."
mkdir -p "$ROOT"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
open -n -g --env CORNERMARK_ISOLATED_ROOT="$ROOT" -a "$APP"

PID=""
for _ in $(seq 1 100); do
    PID="$(pids_of_worktree_binary | head -1)"
    [ -n "$PID" ] && break
    sleep 0.1
done
[ -n "$PID" ] || die "the app did not start within 10 s."

STARTED="$(started_of "$PID")"
{
    printf 'PID=%q\nSTARTED=%q\nROOT=%q\nSINCE=%q\nCOMMIT=%q\n' \
        "$PID" "$STARTED" "$ROOT" "$SINCE" "$(git -C "$WORKTREE" rev-parse --short HEAD)"
} > "$STATE"

for _ in $(seq 1 30); do
    line="$(app_log "$SINCE" | grep "launch pid=$PID " || true)"
    if [ -n "$line" ]; then
        case "$line" in
            *"isolated=true"*) echo "ready: pid=$PID root=$ROOT"; echo "$line"; exit 0 ;;
            *) die "pid $PID did not start isolated: $line. Run stop.sh." ;;
        esac
    fi
    sleep 1
done
die "pid $PID wrote no launch line within 30 s. Run doctor.sh, then stop.sh."
