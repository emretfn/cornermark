# History

Capture History lists past captures grouped by date, filters them by kind, and acts on a selection: show overlay, edit, copy, reveal in Finder, and delete.

## Sub-features

- `history-open` opens the window.
- `history-list` lists stored records, or `No captures yet` when empty.
- `history-filter` filters records by kind.
- `history-actions` acts on the selected records.
- `history-prune` deletes captures older than the retention window.
- `history-recordings` lists recordings under their own filter. Edit opens a recording for editing in the video editor and is off for a plain video. Deleting or pruning one removes its entry and keeps its video.

## How to get to it (user POV)

- Choose `Capture History…` in the menu bar panel.
- Open `cornermark-dev://history`.

## Driving it with link.sh

Preconditions:

- The baseline in [the map](./README.md) holds.

- **Open the window.** Run `$V/link.sh history`. The output has `present window=Capture History visible=false appActive=false` and `"onScreenWindowsMax":0`.
- **List a record.** Run `$V/link.sh open docs/screenshots/capture.png`, then `grep -c '"id"' "$ROOT/History/index.json"` with `ROOT` from `build/verify/instance.env`. The count grows by one.
- **Everything else.** Run the `HarnessShell` sections `History: grouping, filter, thumbnails, actions`, `History: title row, grid, bottom bar`, `retention prune`, and `recordings in History`. Every line is `PASS`. Snapshots are in `build/harness/shell/history-*.png`.

## Gotchas

- `history-list`, `history-filter`, and `history-actions` need clicks in a window that is never drawn, so they are harness-only.
- The menu panel entry is unreachable, because the instance has no status item.
- `visible=false` is correct here. A `visible=true` line means isolation is broken.
- Reveal in Finder does nothing in the instance.
