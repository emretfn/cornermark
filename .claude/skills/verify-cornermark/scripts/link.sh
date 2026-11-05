#!/bin/bash
# link.sh <path> | link.sh open <image-path> | link.sh unknown-link
# Sends one link to the recorded instance only, watches focus while it lands, and prints what the app logged.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

[ $# -ge 1 ] || die "usage: link.sh <path> | link.sh open <image-path> | link.sh unknown-link"
path="$1"
if in_list "$path" "$REFUSED_LINKS"; then
    die "refused: $path is a capture link. It never goes to a live instance. Use HarnessCapture and HarnessShell."
fi
in_list "$path" "$SAFE_LINKS unknown-link" || die "refused: $path is not classified in lib.sh."

require_ours
url="$SCHEME://$path"
if [ "$path" = open ]; then
    [ $# -eq 2 ] || die "usage: link.sh open <image-path>"
    # The app reads only inside the isolated root, so the link cannot raise a permission dialog.
    mkdir -p "$ROOT/import"
    cp "$2" "$ROOT/import/"
    encoded="$(printf %s "$ROOT/import/$(basename "$2")" | perl -pe 's/([^A-Za-z0-9\/._-])/sprintf("%%%02X", ord($1))/ge')"
    url="$url?path=$encoded"
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
for _ in $(seq 1 10); do
    lines="$(app_log "$since")"
    case "$lines" in *"URL $SCHEME://$path"*) break ;; esac
    sleep 1
done

echo "sent $SCHEME://$path to pid $PID"
echo "focus $focus"
echo "$lines"
case "$lines" in *"URL $SCHEME://$path"*) ;; *) die "FAIL: pid $PID logged no line for this link." ;; esac
case "$focus" in *'"onScreenWindowsMax":0'*'"frontmostWasOurs":false'*) ;; *) die "FAIL: the instance came forward." ;; esac
if [ "$path" != unknown-link ]; then
    case "$lines" in *"ignored URL"*) die "FAIL: pid $PID ignored the link." ;; esac
fi
alarms="$(tcc_alarms "$SINCE")"
[ -z "$alarms" ] || die "FAIL: tccd logged a dialog or a protected-folder request. Stop driving, run stop.sh, report this:
$alarms"
