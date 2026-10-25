# dmgbuild settings for SubFloor (see scripts/make_dmg.sh). `defines` come from the command line:
# app (the .app path), background (the TIFF), icon (the volume icon .icns).
import os

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]
format = "ULMO"            # LZMA-compressed, read-only
filesystem = "HFS+"     # Finder shows the background reliably on HFS+ images
window_rect = ((200, 120), (660, 452))   # 420 pt of content under the title bar
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {os.path.basename(app): (180, 196), "Applications": (480, 196)}
