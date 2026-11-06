# Cornermark verification map

This directory is the maintained source for verifying the user-facing behavior of Cornermark Dev. Read the index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- `launch.sh` printed `ready` and `doctor.sh` exited 0.
- `$V` is `.claude/skills/verify-cornermark/scripts`, and the working directory is the checkout root.
- A developer's own Cornermark Dev may be open. Leave it alone. Only the PID that `launch.sh` recorded gets links and signals.

## Driving conventions

- Start from a fresh instance unless a recipe says otherwise. A new instance has an empty history and default settings.
- Send every link through `link.sh`. It refuses capture links and copies an imported image into the isolated root.
- Recording links follow their own focus rule: the instance's only on-screen window is its test window. See [Recording](./recording.md).
- Do not use the mouse, the keyboard, or global events.
- A harness section is `swift run HarnessShell | sed -n '/^== <section>/,/^$/p'`. It prints one `PASS` or `FAIL` line per check, and the run ends with `RESULT <n> passed, <n> failed`.

## Capture links are harness-only

Never send these links to a running instance: `all-in-one`, `capture-area`, `capture-window`, `capture-fullscreen`, `previous-area`, `scrolling`, `ocr`, `timer`.

The instance has no displays, so these links fail instead of imaging the screen. `HarnessShell` section `isolated environment` proves that each one ends as `Capture failed` and stores nothing. To verify capture itself, run `swift run HarnessCapture` and read its sections `area capture`, `all-in-one`, `window capture`, `fullscreen`, `timer`, `scrolling capture`, and `failures`. Both harnesses use fixture displays.

## Proof and skip reporting

- Capture the link, the resulting log line, and the side effect in the root.
- Keep `app.log`, `tccd.txt`, and `focus.jsonl` from `evidence.sh` with every proof.
- A `FAIL` from `link.sh` fails the journey. Report the reason. Do not weaken the journey to make it pass.
- Report a path the instance cannot reach as harness-only, with the harness section that covers it. Do not report it as verified in the running app.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with link.sh` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

## Features

- [History](./history.md) covers opening the window and the records it lists.
- [Settings](./settings.md) covers opening the window and the isolated settings store.
- [Import an image](./import-image.md) covers the image link, the stored record, and the editor.
- [Overlays](./overlays.md) covers restoring and hiding Quick Access cards.
- [Updates and What's New](./updates-and-whats-new.md) covers the update check and the release notes window.
- [Video editor](./video-editor.md) covers opening a project from its card, History, or a link, and the editor's offscreen films.
- [Recording](./recording.md) covers recording the instance's test window and its synthetic display into a project folder with a video and a pointer track.
