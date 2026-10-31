"""Finder layout, written by dmgbuild without opening or scripting Finder."""
from pathlib import Path

application = Path(defines["app"])
files = [str(application)]
symlinks = {"Applications": "/Applications"}
icon = str(application / "Contents/Resources/Circe.icns")
background = defines["background"]
format = "UDZO"
filesystem = "HFS+"
compression_level = 9
window_rect = ((180, 140), (720, 480))
icon_locations = {"Circe.app": (180, 270), "Applications": (540, 270)}
hide_extension = ["Circe.app"]
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
label_pos = "bottom"
scroll_position = (0, 0)
include_icon_view_settings = True
include_list_view_settings = False
