#!/bin/bash
# stop.sh: stop the recorded instance by PID, after proving it is this worktree's binary. Safe to run twice.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

load_state || { echo "no recorded instance, nothing to stop."; exit 0; }
case "$(instance_status)" in
    dead) echo "pid $PID is already gone." ;;
    foreign) die "refused: pid $PID is not this worktree's instance ($(comm_of "$PID")). No signal sent." ;;
    ours)
        kill -TERM "$PID"
        for _ in $(seq 1 50); do
            [ "$(instance_status)" = dead ] && break
            sleep 0.1
        done
        if [ "$(instance_status)" = ours ]; then
            kill -KILL "$PID"
            echo "pid $PID ignored SIGTERM for 5 s and got SIGKILL."
        else
            echo "stopped pid $PID."
        fi
        ;;
esac

alarms="$(tcc_alarms "$SINCE")"
[ -z "$alarms" ] || die "FAIL: tccd logged a dialog or a protected-folder request during this run. Report this, do not launch again:
$alarms"
echo "tccd: no dialog and no protected-folder request since launch."
