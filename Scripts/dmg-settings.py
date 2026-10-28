# dmgbuild's settings for Pilot's DMG (SH25), read by Scripts/release.sh:
#   dmgbuild -s Scripts/dmg-settings.py -D app=<Pilot.app> -D root=<repo> Pilot <out.dmg>
# dmgbuild writes the window's .DS_Store itself, without Finder. The window is the background's size with no toolbar,
# sidebar, path bar or status bar, and the icons sit at the centres in Packaging/dmg/layout.json, the file
# Packaging/dmg/draw-background.swift draws the background from (SH24). dmgbuild joins background@2x.png beside it
# into one HiDPI image, and copies the app with ditto, which keeps pilot-agent-shell's signature xattrs (notes §1).
import json
import os.path

art = os.path.join(defines["root"], "Packaging", "dmg")  # noqa: F821 (dmgbuild passes defines)
with open(os.path.join(art, "layout.json")) as f:
    layout = json.load(f)

# Read-only, LZFSE-compressed, APFS: as hdiutil made it before (SH4).
format = "ULFO"
filesystem = "APFS"
files = [defines["app"]]  # noqa: F821
symlinks = {"Applications": "/Applications"}
# No hide_extensions: its Finder flag on the bundle fails codesign --verify --strict; Finder hides .app on its own.

background = os.path.join(art, layout["background"])
window_rect = ((200, 120), (layout["window"]["width"], layout["window"]["height"]))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
show_icon_preview = False
label_pos = "bottom"
icon_size = layout["icon_size"]
text_size = layout["text_size"]
icon_locations = {name: (at["x"], at["y"]) for name, at in layout["icons"].items()}
