# 0652: Gherkin mac gui: build CI without the Icon Composer icon

Status: worked around in CI; the actool error text is still unseen.

The develop Gherkin run (44566520821, Xcode 26.3, macos-15) fails at `CompileAssetCatalogVariant` for target Star while compiling
`gui/star/StarIcon.icon` with two `Assets.xcassets`, and `ibtoold` (Icon Composer's daemon) is left orphaned. The job has been
red since the `.icon` landed (7136c5e0, 2026-11-17); nothing else in the asset area changed. The log tail held only the command
line because the evidence step never grepped `error:`.

Root cause (best evidence, not a captured message): hosted macOS runners cannot compile an Icon Composer bundle through
actool/ibtoold. The local run could not be done here (the compile queue was held for 16+ minutes).

Decision: the two mac gui Gherkin jobs run `scripts/ci/strip-app-icon.sh` before `xcodebuild test`. It deletes the StarIcon.icon
references and the `ASSETCATALOG_COMPILER_APPICON_NAME`/`INCLUDE_ALL_APPICON_ASSETS` settings from the CI checkout's pbxproj only,
so the UI tests build without the icon. The committed project and `art/export.py` output are unchanged (the art check still passes).
Release builds and `local_release.sh` keep the icon. The failure-evidence step now prints `error:|actool|ibtoold` lines, so if the
job is still red the real error shows; the next step would then be the icon.json candidates (Icon Composer keys, re-exported layer).
