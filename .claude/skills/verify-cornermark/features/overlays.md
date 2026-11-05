# Overlays

Quick Access cards appear in a screen corner after a capture and close by themselves. The user can hide all of them, or bring back the last one that closed.

## Sub-features

- `overlay-restore-empty` says so when no card closed.
- `overlay-hide` hides and shows all cards.
- `overlay-lifecycle` covers the countdown, hover pause, and stack layout.
- `overlay-actions` covers copy, save, annotate, pin, text, and close.
- `overlay-recording` is a finished recording's card: Copy, Play, Reveal in Finder, and Close. The instance logs `recording listed ... card=true` when it adds one.

## How to get to it (user POV)

- Choose `Restore Last Overlay` or `Hide Overlays` in the menu bar panel.
- Open `cornermark-dev://restore-overlay` or `cornermark-dev://hide-overlays`.
- A card appears after a capture, or from `Show Overlay` in Capture History.

## Driving it with link.sh

Preconditions:

- The baseline in [the map](./README.md) holds.
- The instance has no cards.

- **Restore with nothing closed.** Run `$V/link.sh restore-overlay`. The output has `hud No closed overlay to restore`.
- **Hide delivery.** Run `$V/link.sh hide-overlays`. The output has `handled URL cornermark-dev://hide-overlays`. This proves delivery only.
- **Card behavior.** Run the `HarnessShell` sections `Quick Access lifecycle (injected clock)`, `hide all, drag pause, stack order`, `card panels never take focus`, `swipe to dismiss`, `Quick Access card actions`, `finished recordings in Quick Access`, and `Pin windows`. Every line is `PASS`. Snapshots are in `build/harness/shell/card-*.png`.

## Gotchas

- The instance cannot get a card. Capture links are refused and `Show Overlay` needs a click. So hiding, restoring a real card, and every card action are harness-only.
- `hide-overlays` logs nothing beyond delivery. Do not report it as proof that cards hid.
