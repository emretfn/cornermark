#!/bin/bash
# link.sh <path> | link.sh open <image-path> | link.sh unknown-link
# link.sh record/test-window | link.sh record window=<test window id> | link.sh record/pause | record/resume | record/restart | link.sh record/stop
# Sends one link to the recorded instance only, watches focus while it lands, and prints what the app logged.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[ $# -ge 1 ] || die "usage: link.sh <path> | link.sh open <image-path> | link.sh unknown-link | link.sh record/test-window | link.sh record window=<id> | link.sh record/stop"
path="$1"
if in_list "$path" "$REFUSED_LINKS"; then
    die "refused: $path is a capture link. It never goes to a live instance. Use HarnessCapture and HarnessShell."
fi
in_list "$path" "$SAFE_LINKS unknown-link" || die "refused: $path is not classified in lib.sh."

require_ours
url="$SCHEME://$path"
recording=0
fixture=0
want=""
replaced="$(test_window_id)"
if [ "$path" = open ]; then
    [ $# -eq 2 ] || die "usage: link.sh open <image-path>"
    # The app reads only inside the isolated root, so the link cannot raise a permission dialog.
    mkdir -p "$ROOT/import"
    cp "$2" "$ROOT/import/"
    encoded="$(printf %s "$ROOT/import/$(basename "$2")" | perl -pe 's/([^A-Za-z0-9\/._-])/sprintf("%%%02X", ord($1))/ge')"
    url="$url?path=$encoded"
elif in_list "$path" "$RECORDING_LINKS"; then
    recording=1
    case "$path" in
        record)
            [ $# -eq 2 ] || die "usage: link.sh record window=<test window id> | link.sh record display=1[&x=..&y=..&width=..&height=..][&style=video|editing|gif]"
            if [[ "$2" =~ ^window=[0-9]+(&style=(video|editing|gif))?$ ]]; then
                ! screen_locked || die "refused: the screen is locked, so a window recording would end after under a second. Record the synthetic display (display=1) or wait until the session is unlocked."
                [ -n "$(test_window_id)" ] || die "refused: this instance has no test window. Send record/test-window first."
                window="${2#window=}"; window="${window%%&*}"
                [ "$window" = "$(test_window_id)" ] || die "refused: window $window is not this instance's test window ($(test_window_id))."
            elif [[ "$2" =~ ^display=1(&(x|y|width|height)=[0-9]+)*(&style=(video|editing|gif))?$ ]]; then
                # The isolated instance maps a display link to its synthetic display and never to a real one. The log must say so.
                [ -z "$(test_window_id)" ] || die "refused: close the test window first (record/stop), so a display recording shows no window of the instance."
                fixture=1
            else
                die "refused: record takes window=<id> of this instance's test window, or display=1 with whole-number x, y, width, height of the synthetic display."
            fi
            url="$url?$2"
            want="recording started" ;;
        record/test-window)
            [ $# -eq 1 ] || die "usage: link.sh record/test-window"
            want="test window id=" ;;
        record/stop)
            [ $# -eq 1 ] || die "usage: link.sh record/stop"
            want="recording finished" ;;
        record/pause|record/resume)
            [ $# -eq 1 ] || die "usage: link.sh $path"
            want="recording ${path#record/}d" ;;
        record/restart)
            [ $# -eq 1 ] || die "usage: link.sh record/restart"
            want="recording restarted" ;;
    esac
fi

since="$(date '+%Y-%m-%d %H:%M:%S')"
probe_out="$ROOT/probe.tmp"
"$PROBE" "$PID" 2 > "$probe_out" &
probe=$!
sleep 0.2
# --env keeps the instance isolated even if it died a moment ago and this send starts a new one.
open -g --env CORNERMARK_ISOLATED_ROOT="$ROOT" -a "$APP" "$url" >/dev/null 2>&1 || die "open failed for $url"
wait "$probe"
focus="$(cat "$probe_out")"
echo "$focus" >> "$ROOT/focus.jsonl"

lines=""
for _ in $(seq 1 15); do
    lines="$(app_log "$since")"
    case "$lines" in *"URL $SCHEME://$path"*) ;; *) sleep 1; continue ;; esac
    [ -z "$want" ] && break
    case "$lines" in *"$want"*|*"recording refused"*|*"recording failed"*|*"ignored URL"*) break ;; esac
    sleep 1
done

echo "sent $url to pid $PID"
echo "focus $focus"
echo "$lines"
case "$lines" in *"URL $SCHEME://$path"*) ;; *) die "FAIL: pid $PID logged no line for this link." ;; esac
case "$path" in
    record/test-window) printf %s "$(printf %s "$lines" | sed -n 's/.*test window id=\([0-9]*\) .*/\1/p' | tail -1)" > "$ROOT/test-window.id" ;;
    record/stop) rm -f "$ROOT/test-window.id" ;;
esac
if [ "$recording" = 1 ]; then
    violation="$(recording_focus_violation "$focus" "$replaced")"
    [ -z "$violation" ] || die "FAIL: $violation."
else
    case "$focus" in *'"onScreenWindowsMax":0'*'"frontmostWasOurs":false'*) ;; *) die "FAIL: the instance came forward." ;; esac
fi
if [ "$path" != unknown-link ]; then
    case "$lines" in *"ignored URL"*) die "FAIL: pid $PID ignored the link." ;; esac
fi
if [ -n "$want" ]; then
    case "$lines" in *"recording refused"*|*"recording failed"*) die "FAIL: the app refused or failed the recording." ;; esac
    case "$lines" in *"$want"*) ;; *) die "FAIL: pid $PID did not log \"$want\"." ;; esac
    if [ "$fixture" = 1 ]; then
        case "$lines" in *"source=fixture"*) ;; *) die "FAIL: a display link did not film the synthetic display. Run stop.sh and report this." ;; esac
    fi
fi
alarms="$(tcc_alarms "$SINCE")"
[ -z "$alarms" ] || die "FAIL: tccd logged a dialog or a protected-folder request. Stop driving, run stop.sh, report this:
$alarms"
