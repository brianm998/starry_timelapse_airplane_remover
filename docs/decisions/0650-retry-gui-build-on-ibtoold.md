# 0650: retry the gherkin gui build once on an ibtoold failure

Decision: retry the gui Gherkin build once, only when `CompileAssetCatalogVariant` or ibtoold failed before any test ran.

Why: the icon bundle compiles with actool here, the failing log shows only an ibtoold termination, and the sandbox could not reproduce the runner build. A retry is the smallest repair that does not touch the icon. Reverting to `AppIcon.appiconset` is the fallback if the failure repeats (see docs/stages/s657.md).
