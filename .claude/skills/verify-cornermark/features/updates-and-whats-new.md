# Updates and What's New

Check for Updates looks for a newer release and offers to install it. What's New lists the release notes up to the running version.

## Sub-features

- `update-check` reports when the app is up to date.
- `update-install` asks, downloads, verifies, and replaces the app.
- `update-auto` checks in the background.
- `whatsnew-open` opens the window.
- `whatsnew-notes` shows the notes.

## How to get to it (user POV)

- Choose `Check for Updates…` or `What's New…` in the menu bar panel.
- Open `cornermark-dev://check-for-updates` or `cornermark-dev://whats-new`.

## Driving it with link.sh

Preconditions:

- The baseline in [the map](./README.md) holds.

- **Check.** Run `$V/link.sh check-for-updates`. The output has `hud Cornermark is up to date`.
- **Open What's New.** Run `$V/link.sh whats-new`. The output has `present window=What's New visible=false appActive=false`.
- **Everything else.** Run the `HarnessShell` sections whose names start with `update`, and `release notes parsing`, `release history parsing`, and `what's new`. Every line is `PASS`. Snapshots are in `build/harness/shell/whatsnew-*.png`.

## Gotchas

- A development build has no update service, so `check-for-updates` always ends as up to date and makes no network request. It proves delivery and the HUD, not a real check.
- What's New gets an empty history in the instance, so its content is the failure note. `whatsnew-notes` is harness-only.
- `update-install` is harness-only. Never run it against a real app.
