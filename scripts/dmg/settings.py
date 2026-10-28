# dmgbuild settings for PowerToys' DMG; scripts/build.sh passes the paths with -D.
# The window size and icon positions match scripts/dmg/background.swift.
import os.path

app = defines["app"]

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon_locations = {os.path.basename(app): (160, 150), "Applications": (420, 150)}

background = defines["background"]
# The window height includes the 28 pt title bar, so the 360 pt background shows in full.
window_rect = ((200, 200), (580, 388))
icon_size = 112
text_size = 13
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
