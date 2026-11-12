# art

`masters/` holds the received images (named by brief ID), `slots.json` the runtime slots.
`python3 art/export.py` writes the gui imagesets, `star-desktop/src/main/resources/art/` and the generated
`StarArt.swift` / `StarArt.kt`; `--check` exits 1 if anything would change; `--sheet out.png` writes a contact sheet on #050A17.
`import_masters.py <first_41 dir>` was the one-off that copied the masters in (sha256 against MANIFEST.csv).
Needs Python 3 with Pillow and numpy.
