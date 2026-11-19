# 0652: Gherkin mac gui actool failure: expose the error first

Status: partial. Root cause NOT yet identified.

The develop Gherkin run (44566520821, Xcode 26.3, macos-15) fails at `CompileAssetCatalogVariant` for target Star, compiling
`gui/star/StarIcon.icon` with two `Assets.xcassets`. The log tail held only the command line, because the evidence step's
`tail -n 60` and grep printed multi-kilobyte SwiftCompile lines and never grepped `error:`.

Done: the failure-evidence step now prints `error:|actool|ibtoold` lines cut to 400 columns, and cuts the tail likewise.

Not done: reproducing locally (the compile queue was blocked for 16+ minutes) and so no icon change. Candidates, in order,
for the follow-up once the next red run shows the real error: (a) add Icon Composer keys (`fill`, layer `glass`) to icon.json via
`art/export.py icon_bundle_files`; (b) re-export the sky.png layer; (c) drop `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`;
(d) CI-only build without the .icon if ibtoold cannot run on hosted runners. Any icon change must be made in art/export.py.
