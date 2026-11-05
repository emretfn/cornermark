# Import an image

Opening an image adds it to Capture History as an imported capture and opens it in the editor.

## Sub-features

- `import-link` imports through the `open` link.
- `import-store` writes a record and an image to history.
- `import-editor` opens the editor.
- `import-refuse` ignores a file that is not an image.

## How to get to it (user POV)

- Open an image with Cornermark in Finder.
- Open `cornermark-dev://open?path=<absolute path>`.

## Driving it with link.sh

Preconditions:

- The baseline in [the map](./README.md) holds.
- `ROOT` comes from `build/verify/instance.env`.

- **Import.** Run `$V/link.sh open docs/screenshots/capture.png`. The output has `handled URL cornermark-dev://open?path=<ROOT>/import/capture.png`.
- **Stored record.** Run `grep '"kind"' "$ROOT/History/index.json"`. The output has `"kind" : "imported"`.
- **Stored image.** Run `find "$ROOT/History" -name image.png`. The file is a PNG with the source's pixel size, shown by `sips -g pixelWidth -g pixelHeight <file>`.
- **Listed in history.** Run `$V/link.sh history`. The output has `present window=Capture History`.
- **Refuse a non-image.** Run `$V/link.sh open README.md`. It fails with `FAIL: pid <pid> ignored the link`, and the log has `invalidFile`. The record count does not change.
- **Editor and round trip.** Run the `HarnessShell` section `open image from Finder, editor project round trip through history`. Every line is `PASS`.

## Gotchas

- Send this link only through `link.sh`. A path under `~/Documents`, `~/Desktop`, or `~/Downloads` raises a permission dialog as soon as the app checks the file, before it reads any pixels.
- The editor window is never drawn and logs no `present` line, so `import-editor` is harness-only.
- The Finder entry is unreachable here. It reads whatever path Finder hands over.
