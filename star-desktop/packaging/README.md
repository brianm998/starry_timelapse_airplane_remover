# App icons

`star.icns` / `star.ico` / `star.png` are the same icon as the macOS gui's
`gui/star/Assets.xcassets/AppIcon.appiconset`, converted to each OS's native
format for jpackage (via `nativeDistributions { macOS/windows/linux { iconFile.set(...) } }`
in `build.gradle.kts`). They are generated, not hand-made: `python3 art/export.py` rebuilds them
and the gui's `AppIcon.appiconset` from `art/masters/BR-1.png` (128 px and up) and `BR-2.png`
(16 to 64 px, drawn to read small). The body is 824/1024 of the canvas (Apple's grid), also in the
`.ico`; `star.png` (Linux, no OS margin) is BR-1 at 512 px with the body at 94%. `.icns` and `.ico`
are written in pure Python, so `python3 art/export.py --check` runs anywhere. Sizes: icns 16-1024,
ico 16, 24, 32, 48, 64 (BR-2) and 128, 256 (BR-1).

# Folder choosers need no bundled native library

On Windows the folder picker is Explorer's own (`IFileOpenDialog`), reached by running the
`folder-picker.ps1` resource through `powershell.exe`, which ships with Windows. On Linux it is
`zenity` (else `kdialog`) from the system, so the `.deb` does not bundle or depend on a chooser:
a machine without either falls back to Swing's `JFileChooser`. See `ui/initial/FolderPickers.kt`.
