---
name: verify-cornermark
description: "Drive a scripted background instance of Cornermark Dev, the macOS menu bar app, through `cornermark-dev://` links and capture evidence from its log and files, with no window or focus change on the developer's screen. Use to prove a change in the running app, or to verify history, image import, settings, overlays, updates, or link handling. Capture flows are harness-only."
---

# Verify Cornermark

Run every command from the checkout root. The helpers are in `.claude/skills/verify-cornermark/scripts/`, written `$V` below.

```bash
V=.claude/skills/verify-cornermark/scripts
```

## Rules

- A developer's own Cornermark Dev may be open, and an installed Cornermark too. Leave them alone. Signal or send a link only to the PID that `launch.sh` recorded. Never use `killall`, `pkill`, or `osascript quit`.
- The running app must never read or write under `~/Documents`, `~/Desktop`, or `~/Downloads`. That puts a permission dialog on the developer's screen. Send every link through `link.sh`, and never pass a file or a hand-written `open?path=` link to the app.
- Do not use the mouse, the keyboard, or computer use. Do not change system settings, permissions, or the Keychain.
- If a helper reports a tccd alarm, or a permission or Keychain dialog appears, run `stop.sh`, report it, and do not launch again.

## Launch

```bash
$V/launch.sh
```

It builds with `scripts/build-app.sh` when `Sources` or `Resources` are newer than the app, then starts one background instance rooted at `$TMPDIR/cornermark-verify/<run>`. It records the PID, start time, and root in `build/verify/instance.env`.

The instance is ready when `launch.sh` prints `ready: pid=<pid> root=<root>` and the app's `launch pid=<pid> isolated=true screenPermission=<bool>` line. An empty root is a usable state. Run it again with the instance up and it prints `already running`. It refuses to start when this checkout's app already runs outside the skill, because a link could reach that process.

The instance has its own history, defaults suite, and pasteboard. It has no hot keys, no status item, no sound, no update service, and no displays, and it never orders a window in, except the recording test window that a recording link asks for. Screen Recording permission reads truthfully.

## Doctor

```bash
$V/doctor.sh
```

Run it first, and again whenever anything looks off. It only reads, and it exits 0 when all of these pass:

- The recorded PID is this checkout's binary with the recorded start time.
- The app logged `isolated=true` for that PID.
- The root is outside the three protected folders.
- tccd logged no dialog and no protected-folder request since launch.
- No other process runs this checkout's binary.
- The app is newer than `Sources` and `Resources`.
- The app is signed with `Cornermark Dev Self-Signed`.
- `lib.sh` classifies every `ActionTable` URL path as safe or refused.

## Drive

```bash
$V/link.sh history
$V/link.sh open docs/screenshots/capture.png
```

`link.sh` sends one link to the recorded instance, watches focus for 2 s, and prints the app's log lines. It fails when the app logged nothing, ignored the link, came forward, or caused a tccd alarm. `open` copies the image into the root first and sends the copy's path. `edit-recording` does the same with a project folder that is outside the root.

| Link | Log line that proves it |
| --- | --- |
| `history` | `present window=Capture History visible=false appActive=false` |
| `settings` | `present window=Cornermark Settings visible=false appActive=false` |
| `whats-new` | `present window=What's New visible=false appActive=false` |
| `check-for-updates` | `hud Cornermark is up to date` |
| `restore-overlay` | `hud No closed overlay to restore` |
| `hide-overlays` | `handled URL` only, which proves delivery and nothing else |
| `open <image>` | `handled URL`, plus a new record in `<root>/History/index.json` |
| `unknown-link` | `ignored URL` with `unknownPath`, which proves delivery |
| `record/test-window` | `test window id=<n> ... visible=true appActive=false` |
| `record window=<n>` | `recording started ... source=screen` |
| `record display=1&x=..` | `recording started ... source=fixture` |
| `edit-recording <project folder>` | `video editor opened project=<name> seconds= size= pointerSamples=`, then `present window=<name> visible=false appActive=false` |
| `record/stop` | `recording finished ... frames= dropped=` |

`link.sh` refuses capture links. Recording links are the one case where a window is on screen: only the instance's own synthetic test window, ordered in behind the others without activating the app. `link.sh` and `watch.sh` hold them to that. See [the feature map](features/README.md) for each feature's recipe and for the harnesses that cover capture.

## Evidence

```bash
export CORNERMARK_EVIDENCE_DIR=<a folder outside the repo>
$V/evidence.sh <name>
```

Run it before `stop.sh`. It writes these files to `$CORNERMARK_EVIDENCE_DIR/<name>`:

- `app.log` holds the instance's log since launch.
- `tccd.txt` holds every tccd line about Cornermark Dev since launch.
- `doctor.txt` holds the doctor result.
- `focus.jsonl` holds one focus sample per link.
- `saved/` holds the recordings.
- `root-files.txt` lists the root.
- `History/` is a copy of the instance's history.

A proof has the action, the resulting state, and the side effect. For a mutation, read the stored result too, such as `History/index.json`. A `handled URL` line alone proves delivery. Never commit evidence.

These limits apply to every proof:

- Capture and overlay flows are harness-only.
- `hide-overlays` proves delivery only.
- The menu panel is unreachable, because the instance has no status item.
- The focus probe sees this instance's windows and the frontmost app. It does not see another process's dialog, so use the tccd check for that.
- Windows are built but never drawn on screen, so this skill produces no pictures of them. The recording test window is the exception, and a recording is its picture. `swift run HarnessShell` writes window snapshots to `build/harness/shell/`.
- What's New and updates run against a service that returns no releases.

## Cleanup

```bash
$V/stop.sh
```

It stops only the PID that `launch.sh` recorded, after it confirms the binary path and start time. It refuses anything else. It then reports the tccd result for the whole run, and exits non-zero on an alarm. Run it after every failed attempt too.

Cleanup keeps the evidence and the root. Do not delete `$TMPDIR/cornermark-verify`.

## Helpers

| Helper | Use |
| --- | --- |
| `launch.sh` | Start and record the instance. |
| `doctor.sh` | Answer whether the instance is worth driving. |
| `link.sh <path>` | Send one link. Paths are in the Drive table. |
| `watch.sh <seconds>` | Sample focus around a recording and hold it to the recording rule. |
| `evidence.sh <name>` | Copy the proof to `$CORNERMARK_EVIDENCE_DIR/<name>`. |
| `stop.sh` | Stop the recorded PID and report tccd. |
| `lib.sh` | Sourced by the others. Holds `SAFE_LINKS`, `REFUSED_LINKS`, and `RECORDING_LINKS`. |
| `focus-probe.swift` | Compiled by `launch.sh` to `build/verify/focus-probe`, and run by `link.sh`. It reads window metadata and the frontmost PID, never pixels. |

When `doctor.sh` reports an unclassified path, add it to `SAFE_LINKS` only if the link can run with no display and no file outside the root. Otherwise add it to `REFUSED_LINKS`.
