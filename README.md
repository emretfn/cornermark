<p align="center">
  <img src="docs/logo.png" width="128" alt="Cornermark app icon">
</p>

<h1 align="center">Cornermark</h1>

<p align="center">
  A local screenshot and screen recording app for the macOS menu bar.<br>
  Capture, record, edit. Your captures never leave your Mac.
</p>

<p align="center">
  <img src="docs/screenshots/hero.png" alt="The editor showing a sales dashboard with a highlighted card, an arrow to the chart's peak, and a pixelated email column">
</p>

Cornermark is a personal screenshot and screen recording tool for the macOS menu bar. It has no Dock icon, no account, and no cloud storage, and it never uploads a capture or a recording. Its only network requests go to GitHub: the update check, which asks for the latest release, and the release notes you see when you open What's New. Neither sends personal data. You can turn the update check off in Settings > General. Cornermark requires macOS 14 or later, runs on Apple silicon and Intel Macs, and you can install a release or build it from source with Swift Package Manager.

## Install

1. Download [Cornermark.dmg](https://github.com/emretfn/cornermark/releases/latest/download/Cornermark.dmg). Earlier versions and release notes are on the [Releases](https://github.com/emretfn/cornermark/releases) page.
2. Open the DMG and drag Cornermark to Applications.
3. Open Cornermark from Applications. The app is not notarized, so macOS blocks the first launch. Open System Settings > Privacy & Security, scroll down to the message about Cornermark, and click **Open Anyway**.
4. [Grant the Screen Recording permission](#grant-the-screen-recording-permission).

Steps 1 to 3 are for the first install only. After that, Cornermark updates itself from the menu bar.

Releases are signed with a self-signed certificate, not an Apple developer certificate. The certificate stays the same between releases, because macOS ties the Screen Recording permission to it.

### Update

Cornermark asks GitHub for the latest release when it starts and once a day. When a newer one is ready, a short message says so, the menu bar shows **Update** next to the icon, and the menu panel starts with an update row and an **Update** button. You can also choose **Check for Updates…** yourself. **What's New…** in the panel lists what each version brought, in plain language. Cornermark reads the notes from the GitHub releases each time you open it, and it never opens that window by itself. The first launch after an update shows a short "Updated to Cornermark X" message.

When you confirm, Cornermark downloads `Cornermark.dmg`, checks that the app inside is signed with the same certificate as the running one and has the version the release announced, swaps it in for itself, and reopens. You do not repeat step 3, and your Screen Recording permission stays. Cornermark closes open editors first and keeps their edits.

If anything fails, an alert says why and offers the release page, where you can download the DMG by hand. That happens for a copy you built with another certificate, and for a copy that sits where Cornermark cannot write, such as a mounted DMG. Turn off the automatic check in Settings > General. The request carries the app name and version in its `User-Agent`, and GitHub sees your IP address as it does for any request.

## What it does

### Capture an area, a window, or the full screen

`Ctrl+Shift+1` opens a single overlay. Drag to select an area, type an exact size, or lock an aspect ratio. The toolbar switches to window, full screen, scrolling, and timed capture.

<img src="docs/screenshots/capture.png" alt="The capture overlay with a chart card selected, showing handles, a size label, and the toolbar">

### Keep results at hand with Quick Access

Each capture appears as a card in a corner of the screen. Hover a card to get Copy, Save, Edit, Pin, OCR, and Close buttons. Drag a card into another app to drop it as a PNG file. Cards never take focus from the app you are using.

<img src="docs/screenshots/quick-access.png" alt="Three Quick Access cards in the bottom right corner of the desktop, one showing its action buttons">

### Mark up and redact in the editor

The editor has arrows, lines, rectangles, ellipses, text, numbered steps, a pen, and a highlighter. You can blur or pixelate sensitive areas, crop the image, and place it on a background. The editor follows the system light or dark appearance.

<img src="docs/screenshots/editor-dark.png" alt="The editor in dark appearance showing a code window with a blurred API key">

### Pin a screenshot above everything

A pinned screenshot becomes an always-on-top window that you can keep next to your work. Scroll or pinch to zoom, Option-scroll to change opacity, and use the arrow keys to move it by 1 point (10 with Shift). Lock mode passes clicks through to the window behind it.

<img src="docs/screenshots/pin.png" alt="A pinned chart floating in front of a code window">

### Find old captures in History

Cornermark writes every capture to History. You can filter by type, bring a capture back to Quick Access, or reopen it in the editor with your edits intact. By default, Cornermark deletes captures older than 30 days.

<p align="center">
  <img src="docs/screenshots/history.png" width="640" alt="The History window with captures grouped by date">
</p>

### Read text and QR codes

Press `Ctrl+Shift+7` and select an area. Vision recognizes the text on your device, detects the language, and Cornermark copies the result to the clipboard with the line order intact. QR code contents are copied as text too.

### Record the screen

Press `Ctrl+Shift+9` and select an area, a window, or a whole display. **Record Video** writes one MP4 file with the pointer in the picture, **Record GIF** writes an animated GIF, and **Record for Editing** keeps the video, the pointer, the clicks, and the keys apart so you can change how they look afterwards. An optional countdown runs first, and a small bar lets you pause, restart, or stop. Cornermark can record the microphone, the sound your Mac plays, and your camera in a bubble, and it can show clicks and keystrokes on the video. Notifications stay out of the recording.

### Edit recordings in the video editor

A recording made for editing opens in the video editor: settings on the left, the preview in the middle, and the timeline at the bottom. You can:

- Split, delete, and trim clips, and undo every edit.
- Add zooms on the timeline. The camera eases in and out, and zooms that follow each other hand over without returning to full size.
- Resize, restyle, smooth, or hide the pointer, and show clicks with a press effect and a ripple.
- Move or restyle the camera bubble and the keystroke badge, and set the level of each sound track.
- Put the video on a gradient, a wallpaper, a picture, or a colour, with padding, a shadow, rounded corners, and an aspect ratio such as 16:9 or 9:16.
- Add motion blur to zooms and the pointer.
- Export an MP4 with the hardware H.264 encoder, or export the frame at the playhead as a PNG. Both go to Quick Access and History.

The source video is written once and never changed, so every edit can be undone or changed later. Settings > Shortcuts lists every key the editor answers.

## Build

```sh
scripts/build-app.sh            # debug build, creates "build/Cornermark Dev.app"
scripts/build-app.sh --release  # release build, creates build/Cornermark.app
scripts/build-app.sh --universal  # arm64 and x86_64 in one binary
scripts/build-app.sh --no-sign  # skips signing
scripts/build-dmg.sh            # release, universal, and packed into build/Cornermark.dmg
```

The script runs `swift build`, assembles `build/Cornermark.app`, and signs it. Move `build/Cornermark.app` to your Applications folder and open it. The version comes from `version.txt`. `scripts/build-dmg.sh` needs [pipx](https://pipx.pypa.io), which runs dmgbuild.

### Develop next to an installed release

`scripts/build-app.sh` without `--release` creates `build/Cornermark Dev.app`, which runs beside an installed Cornermark. It has an amber icon and a DEV label in the menu bar, and its own bundle ID, settings, history folder, and `cornermark-dev://` links. Its default shortcuts add Option, such as `Ctrl+Option+Shift+4`, and it never updates itself.

macOS ties the Screen Recording permission to the app's code signature, so development builds need a certificate that stays the same. Create it once:

```sh
scripts/make-dev-signing-cert.sh
```

It adds a self-signed certificate to your login keychain and belongs to no Apple account. The first build asks for your login password to use the key. Choose **Always Allow**, or it asks on every build. Grant the permission to Cornermark Dev once, and it survives rebuilds.

`--release` builds use the identity in `CORNERMARK_SIGN_IDENTITY`, and fall back to an ad-hoc signature that changes with every build. Neither mode picks an identity from your keychain on its own.

## Grant the Screen Recording permission

1. Open Cornermark and try a capture. If the permission is missing, Cornermark shows an explanation window.
2. Click **Open System Settings**. It opens Privacy & Security > Screen & System Audio Recording.
3. Turn on Cornermark in the list.
4. Quit and reopen Cornermark. macOS applies the permission only after a restart.

Settings > Permissions also shows the current state.

## Shortcuts

The defaults use `Ctrl+Shift+number` and do not conflict with system shortcuts. You can change them in Settings > Shortcuts, which shows a red warning if another app already uses a shortcut. Cornermark registers shortcuts with Carbon `RegisterEventHotKey`, so it does not need the Accessibility permission.

| Shortcut | Action |
| --- | --- |
| Ctrl+Shift+1 | All-in-one (area, window, full screen) |
| Ctrl+Shift+2 | Capture area |
| Ctrl+Shift+3 | Capture window |
| Ctrl+Shift+4 | Capture full screen |
| Ctrl+Shift+5 | Capture the previous area again |
| Ctrl+Shift+6 | Scrolling capture |
| Ctrl+Shift+7 | Capture text (OCR) |
| Ctrl+Shift+8 | Timed capture |
| Ctrl+Shift+9 | Record the screen: an area, a window, or a whole display. Press it again to stop |

The video editor has its own keys, listed under the global ones in Settings > Shortcuts. They work while an editor window is in front:

| Shortcut | Action |
| --- | --- |
| Space | Play or pause |
| Command-B | Split the clip at the playhead |
| Delete | Delete the picked clip or zoom |
| Z | Add a zoom at the playhead |
| Command-D | Duplicate the picked zoom |
| Control-Command-F | Full Screen Preview |
| Command-Z, Shift-Command-Z | Undo, Redo |
| Command-S, Shift-Command-S | Save, Save As |
| Command-E | Export |
| Shift-Command-E | Export Current Frame as Image |
| Arrow keys on the timeline | Step a frame, or a second with Shift. Option trims the clip's start, Option-Command its end |

<p align="center">
  <img src="docs/screenshots/settings.png" width="640" alt="The Shortcuts section of the Settings window">
</p>

## Details

- **Menu bar panel.** Click the icon for a panel with the capture modes and their shortcuts, your latest captures, the overlay controls, pinned screenshots, and Settings. It takes arrow keys, Return, and Escape without taking focus from the app in front.
- **After capture.** Cornermark can show a Quick Access card, copy to the clipboard, save to a folder (`Cornermark YYYY-MM-DD at HH.MM.SS.png`), or open the editor. Every capture also goes to History.
- **Quick Access.** Swipe a card toward the screen edge with two fingers to dismiss it, or double-click it to open the editor. The auto-dismiss timer is adjustable and pauses while the pointer is over the card. You can restore the last closed card and hide all cards temporarily.
- **Pins.** To unlock a locked pin, use the "Pinned screenshots" list in the menu bar panel. Escape or the close button removes a pin.
- **History.** You can also copy a capture, reveal it in Finder, and delete it. Cornermark removes old captures at launch and once a day. Recordings are listed too, under their own filter, with their length on the picture. Deleting a recording from History keeps its video in the save folder.
- **Finished recordings.** A recording shows a Quick Access card with its first frame, length, and size. Copy puts the video file on the clipboard, Play opens a plain video or a GIF, Edit opens a recording made for editing, and Reveal in Finder shows it. Dragging the card drags the video.
- **Video editor.** Edit on the card or in History opens a recording made for editing, and File > Open Video opens an MP4 or MOV file as a new project. Settings sit in a rail on the left, the preview in the middle, and the timeline at the bottom with a ruler, a zoom lane, and a clip lane with pictures of the recording. Space plays and pauses, the timeline takes a click, a drag, or the arrow keys, and Full Screen Preview shows only the video. The Cursor section shows, hides, and resizes the pointer, draws it as a white arrow, a black arrow, or a translucent dot, smooths a shaky path, and can fade it out while it rests or while you type. Command-B splits the clip at the playhead, Delete removes a clip, and dragging a clip's edge trims it; Option with the arrow keys trims from the keyboard. Each cut is marked on the clip lane, and Command-Z undoes any edit. A project is a `.cornermarkvideo` package: Command-S saves, Save As copies it, and closing the window keeps the changes without asking. Export writes a video of only the clips that are left, and the video file itself is never rewritten.
- **Export Current Frame as Image.** File > Export Current Frame as Image, or Shift-Command-E, draws the frame at the playhead the way the video export draws it, sharp and at the video's full size, and treats it like a screenshot: it goes to History, and then to Quick Access, the clipboard, or the save folder, as After capture says. Nothing is uploaded.
- **GIF.** Record GIF, or Option-Return in the recording overlay, records like a video and saves an animated GIF at 15 frames a second, at most 960 pixels on its longest side, looping forever. A paused stretch is left out. Convert to GIF on a video's Quick Access card or in History makes a GIF beside an existing Record Video recording and keeps the video.
- **Settings.** Launch at login, automatic update checks, save folder, PNG or JPEG, sound, shortcuts, card corner and size, window shadow, timer length, retention period, and permission state. The Recording pane sets the frame rate (30 or 60), quality, Retina or standard resolution, a largest size (4K, 1440p, 1080p, or 720p), whether the cursor shows, and whether a finished recording gets a Quick Access card.
- **Updates.** Cornermark checks GitHub at launch and once a day, and installs a release only after you confirm. See [Update](#update).
- **Open from Finder.** "Open With" opens PNG, JPEG, and HEIC files in the editor.
- **URL scheme.** `cornermark://capture-area`, `capture-window`, `capture-fullscreen`, `all-in-one`, `previous-area`, `scrolling`, `ocr`, `timer?seconds=5`, `history`, `settings`, `check-for-updates`, `whats-new`, `restore-overlay`, `hide-overlays`, `open?path=/full/path/image.png`. The `open` path must be an existing image file. Cornermark logs and ignores unknown paths.
- **Recording.** `cornermark://record?window=<id>` records one window. `cornermark://record?display=<id>&x=<x>&y=<y>&width=<w>&height=<h>` records a display or an area of it, in points from the bottom-left corner of the screen, and `display` or the area may be left out but not both. Add `&style=video` for one MP4 file or `&style=gif` for an animated GIF. `cornermark://record/stop` ends the recording. `cornermark://edit-recording?path=<folder>` opens a recording's folder in the video editor. The recording lands in the save folder as a folder named after the time, holding `screen.mp4`, an H.264 video at up to 60 frames a second without the cursor, and `project.json`, which keeps where the pointer was as its own track and how it should be drawn. The video is written once and never changed, so the pointer can be hidden or resized later without re-encoding anything. Nothing leaves your Mac.

## What it leaves out

- No cloud, accounts, or share links.
- The video editor cannot turn a recording for editing into a GIF.
- No App Store version or notarization.

## Develop

```sh
swift build                                  # builds everything
swift test                                   # CornermarkCore tests
swift run HarnessShell                       # shell checks, opens no windows on screen
swift run HarnessReadme                      # regenerates docs/screenshots
swift scripts/make-icon.swift docs/logo.png  # regenerates the icon in this README
```

`HarnessShell` sets the activation policy to `.prohibited`, orders no windows, and takes no focus. It replaces the pasteboard, UserDefaults, and the history folder with temporary objects, and writes snapshots to `build/harness/shell/`.

`HarnessReadme` produces the images on this page. The windows and cards are the app's real interface. The desktop, menu bar, Dock, dashboard, and code window are drawn sample content, and the companies and figures are fictional.

## Release

Commits to `main` follow [Conventional Commits](https://www.conventionalcommits.org), and a check on each pull request validates its title. Before 1.0, `feat:` raises the minor version and `fix:` raises the patch version. Other types, such as `docs:`, `build:` and `ci:`, and commits that do not follow the format do not trigger a release.

[release-please](https://github.com/googleapis/release-please-action) keeps a release pull request open with the next version in `version.txt` and the changelog. Merge it to publish: it tags `v<version>`, creates the GitHub release, and a macOS job builds `Cornermark.dmg` and attaches it. Until it does, the app does not offer the release. With squash merges, the pull request title is the commit message that counts.

The subject of that title is what users read in What's New, under **New** for `feat:` and **Fixed** for `fix:` and `perf:`. Write it as a plain sentence about what changes for them, for example `fix: stop the crop handle from jumping`. A note can be corrected after the release by editing the GitHub release, because the app reads the notes from there each time.

The release job signs with the certificate in the `CORNERMARK_CERT_P12` and `CORNERMARK_CERT_PASSWORD` secrets. `scripts/make-signing-cert.sh <backup.p12>` creates them. Replace the certificate only if you must. Users then grant Screen Recording again, and the updater refuses a release signed with a different certificate, so they install that release by hand.

## License

[MIT](LICENSE)
