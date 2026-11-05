# Recording

Cornermark records a window or a display to an H.264 MP4 file in the save folder, without the cursor in the picture, and stops on request.

## Sub-features

- `record-window` records one window by its window number, with `record?window=<id>`.
- `record-display` records a display, or an area of it, with `record?display=<id>` and `x`, `y`, `width`, `height` in global points with a bottom-left origin.
- `record-stop` finishes the file with `record/stop`.
- `record-test-window` shows the instance's own synthetic window with `record/test-window`. A scripted instance has one, and no other instance does.
- `record-refusal` keeps a scripted instance from filming anything but its test window.

## How to get to it (user POV)

- Open `cornermark-dev://record?window=<id>` or `cornermark-dev://record?display=<id>&x=<x>&y=<y>&width=<w>&height=<h>`, then `cornermark-dev://record/stop`.
- There is no menu row, hotkey, or toolbar yet.

## Driving it with link.sh

Preconditions:

- The baseline in [the map](./README.md) holds, and Cornermark Dev has Screen Recording permission (`screenPermission=true` in the launch line).
- `CORNERMARK_EVIDENCE_DIR` is a folder outside the repo, for the proof below.

- **Window.** Run `$V/link.sh record/test-window`. The output has `test window id=<n>` and `"onScreenWindowIDs":[<n>]`. Run `$V/watch.sh 14 &`, then `$V/link.sh record window=<n>`, wait, and `$V/link.sh record/stop`. The log has `recording started ... source=screen` and `recording finished ... frames= dropped= dropPercent=`. The file is `<root>/saved/Cornermark Recording <date>.mp4`.
- **Display and area.** With no test window open, run `$V/link.sh record "display=1&x=0&y=0&width=960&height=540"`. The log must say `source=fixture`. The instance films its synthetic display, so the line proves the link, the area crop, and the writer, not live display capture.
- **Check the file.** Run `ffprobe -count_frames -select_streams v -show_entries stream=codec_name,width,height,nb_read_frames,duration <file>`. Extract frames with `ffmpeg -ss <t> -i <file> -frames:v 1 <png>` and look at them. Only the synthetic scene may appear: dark background, a sweeping bar, a clock, and four colored corners (red top left, green top right, blue bottom left, yellow bottom right).
- **Focus.** `link.sh` and `watch.sh` hold a recording to this rule: the instance's only on-screen window is the test window, the instance is never frontmost, and the frontmost app never changes. A display recording shows no window of the instance at all.
- **Keep the proof.** Run `$V/evidence.sh <name>` before `stop.sh`. It copies `<root>/saved` too.
- **Everything else.** Run `swift run HarnessCapture` (sections `recording engine`, `stream geometry`) and `swift run HarnessShell` (sections `recording links`, `recording policy of an isolated instance`, `recording flow`, `recording in a scripted instance`).

## Gotchas

- `link.sh record` refuses a window that is not the test window, and a display link with anything but `display=1` and whole-number area values. Never work around it. A display link in a scripted instance never builds a content filter on a real display. The harness check `recording policy of an isolated instance` proves that.
- The test window sits in the bottom-left corner of the main display, behind every other window, and may show when the desktop is exposed. It holds no real content. `record/stop` closes it.
- A window parked beyond the last display is captured too, but arrives unevenly: 7% of the frames at 60 fps were missing. The test window stays on screen for that reason.
- A scripted instance runs a debug build. The dropped-frame number is for a 480x270 window on a 120 Hz display.
- `record/stop` with nothing recording logs `recording refused`, and `link.sh` fails on it. Run it only after a start.
- If tccd logs a dialog, stop, run `stop.sh`, and report it. Never trigger the microphone or the camera.
