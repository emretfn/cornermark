# Video editor

A recording made for editing opens in the video editor. The window has a settings rail on the left (Cursor, Keystrokes, Audio, Camera, Background, Motion Blur), the preview in the middle with playback under it, and the timeline at the bottom: a ruler, a zoom lane, and a clip lane with pictures of the recording. The preview draws each frame from the project through `frameState`, so the pointer is a layer over the untouched `screen.mp4`. Space plays and pauses. Full Screen Preview hides the settings and the timeline. Closing the window writes changed edits to `project.json`. Export, top right, renders the edited video through the same `frameState` with VideoToolbox's hardware H.264 encoder and lists it in History with a Quick Access card.

## Sub-features

- `editor-open` opens a project folder from the Quick Access card's Edit, History's Edit, or `edit-recording?path=<folder>`. A plain `.mp4` keeps Play.
- `editor-layout` is the rail, the panel, the preview, the playback row, and the timeline lanes.
- `editor-sections` switches the panel. Cursor has Show cursor and Size; the others say what the recording holds.
- `editor-playback` is Space, Go to Start, Go to End, clicking or dragging the timeline, arrow keys on the focused timeline, and the volume, which is off for a recording without sound.
- `editor-fullscreen` is Full Screen Preview. Esc or the same button returns.
- `editor-save` writes changed edits to `project.json` on close and never touches `screen.mp4`.
- `editor-export` is Export: the panel (Resolution, Quality, the size estimate), the progress with Cancel, and the export's card with Copy, Save, Play and Close. Export saves changed edits first. A cancelled or failed export leaves no file. The export lives in its History entry's folder until Save copies it to the save folder.

## How to get to it (user POV)

- Record for Editing, then choose **Edit** on the recording's Quick Access card.
- Select the recording in Capture History and choose **Edit**, or double-click it.
- Open `cornermark-dev://edit-recording?path=<project folder>`.

## Driving it with link.sh

Preconditions:

- The baseline in [the map](./README.md) holds.
- The instance has a project folder. Record one from the synthetic display as [Recording](./recording.md) describes.

- **Open by link.** Run `$V/link.sh edit-recording "<root>/saved/Cornermark Recording <date>"`. The output has `video editor opened project=<name> seconds=<s> size=<w>x<h> pointerSamples=<n>`, then `present window=<name> visible=false appActive=false`, and `"onScreenWindowsMax":0`. A folder outside the root is copied to `<root>/import/` first.
- **Export by link.** Run `$V/link.sh edit-recording "<project folder>" export`. It sends `edit-recording?path=<folder>&export=1`, which opens the editor and exports with the default choices. The log has `video export started ... estimatedBytes=` and then `video exported ... frames= seconds= projectSeconds= bytes= hardware=true encoder=com.apple.videotoolbox.videoencoder.ave.avc renderSeconds=`. The file is in `<root>/History/<entry>/`, and `<root>/History/.incoming` is empty afterwards.
- **Refusal.** A folder without `project.json` is refused by `link.sh` before anything is sent.
- **Everything else.** The window is built but never drawn in the instance, so the rest is harness-only. Run `swift run HarnessShell` and read the sections `video editor: opening`, `video editor: layout and sections`, `video editor: playback`, `video editor: full screen preview`, `video editor: edits and the project file`, and `video editor: preview frame time`. Snapshots are `build/harness/shell/video-editor.png`, `video-editor-dark.png`, and `video-editor-min.png`.
- **Export, harness.** `swift run HarnessShell` sections `video export: panel`, `progress and the file`, `size estimate`, `Quick Access card`, `the file matches the preview`, `cancel`, `closing the window` and `by link`. `EXPORT`, `ESTIMATE` and `PARITY` lines carry the numbers. Snapshots are `video-export-panel.png`, `video-export-panel-dark.png`, `video-export-progress.png` and `parity-<t>-preview|drawn|file.png`.
- **Film export.** `CORNERMARK_EXPORT_FILM=<folder> swift run HarnessShell` films the real editor, export panel and card offscreen into `X1.mp4`, `X2.mp4`, `X3.mp4` and `X6.mp4`, next to frames read back from the exported files. The export runs at its own speed while the film samples it.
- **Film it.** `CORNERMARK_EDITOR_FILM=<folder> swift run HarnessShell` records a project from the fixture display, opens it the way a user would, and films the real editor offscreen into `E2.mp4`, `E3.mp4`, `E4.mp4`, and `E10.mp4`. The harness decodes the source on a scripted clock so playback runs at its own speed.

## Gotchas

- The instance never orders the editor in, so `visible=false` is correct. A `visible=true` line means isolation is broken.
- The preview's picture and pointer are Core Animation layers. `cacheDisplay` leaves them out, so a snapshot of the window renders the preview's layer tree on top. `editorImage` in `ChecksVideoEditor.swift` does that.
- An offscreen window cannot enter macOS full screen. The harness checks the layout and the dark appearance of Full Screen Preview, and the film resizes the window to the display's size in its place.
- The `PERF` line measures the live decoder and one tick, layer commit included, on a 60 Hz timer in the harness. Core Animation's compositing runs outside the main thread and is not in the number.
