#!/bin/bash
# doctor.sh: read-only answer to "is this instance worth driving?". Exit 0 only when every check passes.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

failed=0
report() {
    if [ "$1" = 0 ]; then echo "PASS $2"; else echo "FAIL $2"; failed=1; fi
}

load_state || { echo "FAIL no recorded instance, run launch.sh"; exit 1; }
status="$(instance_status)"
[ "$status" = ours ]; report $? "recorded pid $PID is this worktree's binary, same start time (status: $status)"

line="$(app_log "$SINCE" | grep "launch pid=$PID " || true)"
case "$line" in *"isolated=true"*) report 0 "app says: ${line##*launch }" ;; *) report 1 "launch line with isolated=true for pid $PID" ;; esac

! is_protected_path "$ROOT"; report $? "isolated root is outside folders that raise a permission dialog"

alarms="$(tcc_alarms "$SINCE")"
[ -z "$alarms" ]; report $? "tccd logged no dialog and no protected-folder request since launch"
[ -z "$alarms" ] || echo "$alarms"

others="$(pids_of_worktree_binary | grep -v -x "$PID" | tr '\n' ' ')"
[ -z "$others" ]; report $? "no other process runs this worktree's binary, so links reach only pid $PID (others: ${others:-none})"

newer="$(find "$WORKTREE/Sources" "$WORKTREE/Resources" -type f -newer "$BIN" 2>/dev/null | wc -l | tr -d ' ')"
[ "$newer" = 0 ]; report $? "the app is newer than Sources and Resources ($newer newer files)"

authority="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[ "$authority" = "Cornermark Dev Self-Signed" ]; report $? "signed by the development certificate (authority: ${authority:-none})"

unclassified=""
for path in $(action_table_paths); do
    in_list "$path" "$SAFE_LINKS" || in_list "$path" "$REFUSED_LINKS" || unclassified="$unclassified $path"
done
[ -z "$unclassified" ]; report $? "link.sh classifies every ActionTable path (unclassified:${unclassified:- none})"

echo "note: built from commit $COMMIT, root $ROOT"
exit "$failed"
