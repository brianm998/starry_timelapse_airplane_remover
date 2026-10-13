# App icons

`star.icns` / `star.ico` / `star.png` are the same icon as the macOS gui's
`gui/star/Assets.xcassets/AppIcon.appiconset`, converted to each OS's native
format for jpackage (via `nativeDistributions { macOS/windows/linux { iconFile.set(...) } }`
in `build.gradle.kts`). Regenerate them from that source whenever the gui's icon changes:

```bash
SRC=../gui/star/Assets.xcassets/AppIcon.appiconset

# macOS: build a .iconset dir from the appiconset's PNGs, then compile it (macOS only, needs iconutil)
rm -rf /tmp/star.iconset && mkdir -p /tmp/star.iconset
for f in icon_16x16.png icon_16x16@2x.png icon_32x32.png icon_32x32@2x.png \
         icon_128x128.png icon_128x128@2x.png icon_256x256.png icon_256x256@2x.png \
         icon_512x512.png icon_512x512@2x.png; do
  cp "$SRC/$f" "/tmp/star.iconset/$f"
done
iconutil -c icns /tmp/star.iconset -o star.icns

# Windows: multi-resolution .ico (needs ImageMagick, `brew install imagemagick`)
magick "$SRC/icon_16x16.png" "$SRC/icon_32x32.png" "$SRC/icon_128x128.png" \
       "$SRC/icon_256x256.png" "$SRC/icon_512x512.png" star.ico

# Linux: jpackage on Linux just wants a single PNG
cp "$SRC/icon_512x512@2x.png" star.png
```
