# art

`masters/` holds the received images (named by brief ID), `slots.json` the runtime slots.
`python3 art/export.py` writes the gui imagesets, `star-desktop/src/main/resources/art/` and the generated
`StarArt.swift` / `StarArt.kt`, plus the app icon (mac `AppIcon.appiconset`, desktop `star.icns`/`star.ico`/`star.png`) from BR-1 and BR-2; `--check` exits 1 if anything would change; `--sheet out.png` writes a contact sheet on #050A17.
`import_masters.py <first_41 dir>` was the one-off that copied the masters in (sha256 against MANIFEST.csv).
Needs Python 3 with Pillow and numpy.

Installer and README art, also written by `export.py`: `docs/readme-hero.jpg` (BR-7c, JPEG, at most 400 KB; the
README's first image), and `star-desktop/packaging/dmg/{Star-background.png,Star-dmg-setup.scpt}` (BR-7a at 144 dpi,
and the Finder layout that puts the app in the left third and the Applications link in the right third).
BR-7b (Windows installer side panel) is not used: see `star-desktop/packaging/README.md`.
