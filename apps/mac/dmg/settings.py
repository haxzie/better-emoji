# dmgbuild settings — the installer window. Used by scripts/make-dmg.sh.
#   dmgbuild -s settings.py -D app="…/Better Emoji.app" "Better Emoji" out.dmg
import os.path

app = defines["app"]
appname = os.path.basename(app)
here = defines.get("here", "dmg")  # passed by make-dmg.sh; dmgbuild exec()s this file without __file__

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
badge_icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

# Window: 660×400, matching background.png. Origin is the window's top-left on screen.
window_rect = ((240, 160), (660, 400))
background = os.path.join(here, "background.tiff")  # 1x + 2x, built by make-dmg.sh
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0

icon_size = 128
text_size = 14
arrange_by = None
icon_locations = {
    appname: (160, 200),
    "Applications": (500, 200),
}
