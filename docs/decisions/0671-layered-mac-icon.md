# 0671: layered macOS icon, compiled into the desktop .app

Status: accepted. Task #669.

- icon.json lists one group per layer, star first, then mountains, then sky (topmost first); actool's icns output confirms the star renders in front.
- jpackage cannot take a `.icon`, so `fixBundledBinaries` runs actool on the gui's bundle for each `.app` and sets `CFBundleIconName`. CI fails if that breaks; locally it warns.
- star.icns is composited and masked in art/export.py (rounded radius 22.4%, tile at 824/1024). star.ico and star.png are unchanged.
