# Sourced by the other helpers. Never signals anything.
WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
APP="$WORKTREE/build/Cornermark Dev.app"
BIN="$APP/Contents/MacOS/Cornermark"
VERIFY_DIR="$WORKTREE/build/verify"
STATE="$VERIFY_DIR/instance.env"
PROBE="$VERIFY_DIR/focus-probe"
SCHEME="cornermark-dev"
SUBSYSTEM="local.emretufan.cornermark"

# Each ActionTable urlPath belongs to exactly one list. doctor.sh fails on a path in neither.
SAFE_LINKS="history settings whats-new check-for-updates restore-overlay hide-overlays open"
REFUSED_LINKS="all-in-one capture-area capture-window capture-fullscreen previous-area scrolling ocr timer"

die() { echo "$*" >&2; exit 1; }
is_protected_path() { case "$1" in "$HOME/Documents"*|"$HOME/Desktop"*|"$HOME/Downloads"*) return 0 ;; *) return 1 ;; esac; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
action_table_paths() { sed -n 's/.*urlPath: "\([a-z-]*\)".*/\1/p' "$WORKTREE/Sources/CornermarkShell/AppAction.swift"; }

comm_of() { ps -p "$1" -o comm= 2>/dev/null || true; }
started_of() { ps -p "$1" -o lstart= 2>/dev/null || true; }
pids_of_worktree_binary() {
    ps -axo pid=,comm= | while read -r pid comm; do
        if [ "$comm" = "$BIN" ]; then echo "$pid"; fi
    done
}

load_state() {
    [ -f "$STATE" ] || return 1
    # shellcheck disable=SC1090
    source "$STATE"
}

# dead: nothing has the recorded PID. ours: it is this worktree's binary, started when launch.sh recorded. foreign: anything else.
instance_status() {
    local comm
    comm="$(comm_of "$PID")"
    if [ -z "$comm" ]; then
        echo dead
    elif [ "$comm" = "$BIN" ] && [ "$(started_of "$PID")" = "$STARTED" ]; then
        echo ours
    else
        echo foreign
    fi
}

require_ours() {
    load_state || die "no recorded instance. Run launch.sh."
    [ "$(instance_status)" = ours ] || die "recorded PID $PID is $(instance_status), not this worktree's instance. Nothing was sent."
}

app_log() {
    /usr/bin/log show --style compact --start "$1" \
        --predicate "processID == $PID AND subsystem == \"$SUBSYSTEM\"" | grep -v -e '^Timestamp' -e '^Filtering' || true
}

tcc_log() {
    /usr/bin/log show --style compact --start "$1" \
        --predicate 'process == "tccd" AND eventMessage CONTAINS "cornermark.dev"' | grep -v -e '^Timestamp' -e '^Filtering' || true
}

# A dialog, or sandboxd asking on this instance's behalf about a protected folder. An old answer to the dialog hides the first but not the second.
tcc_alarms() { tcc_log "$1" | grep -e AUTHREQ_PROMPTING -e "pid=$PID, .*com\.apple\.sandboxd" || true; }
