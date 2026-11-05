# Settings

Settings has five panes: General, Shortcuts, Quick Access, Capture, and Permissions. Each change is stored at once and takes effect in the running app.

## Sub-features

- `settings-open` opens the window.
- `settings-store` keeps the instance's settings apart from the developer's.
- `settings-panes` changes values in each pane.
- `settings-permission` shows the Screen Recording state.

## How to get to it (user POV)

- Choose `Settings…` in the menu bar panel.
- Open `cornermark-dev://settings`.

## Driving it with link.sh

Preconditions:

- The baseline in [the map](./README.md) holds.

- **Open the window.** Run `$V/link.sh settings`. The output has `present window=Cornermark Settings visible=false appActive=false` and `"onScreenWindowsMax":0`.
- **Separate store.** Run `stat -f %m ~/Library/Preferences/local.emretufan.cornermark.dev.plist` before `launch.sh` and after `stop.sh`. The value does not change.
- **Permission state.** Read the `launch pid=...` line from `doctor.sh`. `screenPermission=` is the real grant.
- **Everything else.** Run the `HarnessShell` sections `settings model`, `Settings window`, `Settings: General`, `Settings: Shortcuts`, `Settings: Quick Access, Capture, Permissions`, and `Settings: window, sidebar, form layout`. Every line is `PASS`. Snapshots are in `build/harness/shell/settings-window-*.png`.

## Gotchas

- Changing a value needs a click in a window that is never drawn, so `settings-panes` is harness-only.
- The folder picker returns nothing, the login item is a fake, and the hot key status is empty in the instance.
- Each launch resets the instance's settings to defaults.
- The instance's plist in `~/Library/Preferences` has one fixed name, so repeated launches add no files. The harness keeps settings in memory.
