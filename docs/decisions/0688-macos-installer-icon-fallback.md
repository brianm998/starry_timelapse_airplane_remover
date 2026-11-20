# 0688: macOS installer icon is best-effort on CI

Hosted macos-15 runners cannot reliably compile an Icon Composer bundle (ibtoold crash; same as 0652 for the gui build). Failing the installer for a cosmetic asset kept develop red.

Decision: `fixBundledBinaries` tries actool twice, deletes any partial Assets.car on failure, prints the error lines plus a `::warning::` on CI, and keeps `star.icns` (the pre-macOS-26 fallback). Signing and notarization proceed. CFBundleIconName is only set when Assets.car was produced.
