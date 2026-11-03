# dmgbuild settings for build/Cornermark.dmg. scripts/build-dmg.sh passes app, icns and background with -D.
# Icon positions match appIcon and applicationsIcon in make-dmg-background.swift.

app = defines["app"]

format = "ULMO"
files = [app]
symlinks = {"Applications": "/Applications"}
# hide_extensions is left unset: it writes a Finder attribute onto the app that fails codesign --verify --strict.

icon = defines["icns"]
background = defines["background"]

# The window frame includes a 28 point title bar, so the 660x420 background fills the content area. Newer macOS draws a taller bar and crops the empty bottom margin.
window_rect = ((200, 120), (660, 448))
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_pathbar = False
show_status_bar = False
icon_size = 128
text_size = 13
icon_locations = {
    "Cornermark.app": (180, 190),
    "Applications": (480, 190),
    # Finder shows these when hidden files are on, so keep them out of the window.
    ".background.tiff": (180, 900),
    ".VolumeIcon.icns": (480, 900),
    ".DS_Store": (780, 900),
}
