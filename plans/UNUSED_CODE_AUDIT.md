# Unused Swift and C++ code audit

Ticket #77. Audited at `f2e3109b` (develop) on 2026-11-01. This is a report only: no production source
was changed, and every removal is a follow-up the owner approves one at a time (§8).

## 1. Summary

| Kind | Finding groups | Approx. lines removable |
|---|---|---|
| Dead code (StarCore files and members, C bridge functions, C++ leftovers, daemon, logging) | 25 (about 130 symbols) | ~2,000 |
| Dead chain: `HomographyHorizonDetector`, its uncalled tuning method and its tests | 1 | ~1,790 |
| Abandoned tool packages | 3 broken, 1 unreferenced | ~1,610 |
| Orphaned gui files and unreferenced gui views | 5 | ~980 |
| Unused `Config` properties | 2 properties (F-30) | ~9 |
| Catalogue keys that belong to dead gui views | 25 keys x 22 tables | ~550 |
| Test-only code | 69 symbols; most are test hooks to keep (§6) | ~190 + their tests |
| Unreachable branch | none confirmed (§7) | - |

The big ones are `HomographyHorizonDetector` (743 lines + 846 lines of tests), three unreferenced StarCore
files that nothing imports (`Combinations.swift` 297, `HoughTransform.swift` 182, the
`ProcessorUsageReporter`/`ProcessorUsageTracker` pair 365), and the broken `horizon_tester` package (881).

Two claims in the ticket needed correcting:

* `HomographyHorizonDetector` is not simply "without a call site". It *is* constructed, in
  `FrameHorizonProcessor.maybeTuneHorizonParameters`, but that method is `private` and nothing calls it, so the
  whole chain is unreachable. Details and the parts that must be kept are in F-01.
* Several StarCore symbols that `periphery` reports as unused from the cli alone are live through the daemon, the
  gui or a live developer tool (e.g. `PreviewGenerationOp`, `ReferenceHorizonStatsRegistry`,
  `LimitedTaskGroup`, the decision-tree types). §7 lists what was checked and kept, so nobody re-audits it.

## 2. Scope and exclusions

In scope: `StarCore/Sources`, `StarCpp/Sources/{StarCpp,kht,StarCppBridge}`, `gui/star`, `cli/Sources`,
`daemon/Sources`, `logging`, `logging-objc`, `StarDecisionTrees`, and the ten standalone tool packages.

Out of scope, as in the ticket: `opencv/`, `external_binaries/`, `ffmpeg/`, `wgpu/`, `pipeline/`, generated
protobuf (`daemon/Sources/StarDaemonMessages/star.pb.swift`), the generated Gherkin kernel
(`gherkin/StarGherkin/.../Features.generated.swift`) and unused localization keys in general.

Not covered, and why:

* **gui was not scanned with periphery.** The gui builds only through `xcodebuild -scheme star`, which is one of
  the longest jobs on the shared heavy lock and was held by other work for most of this session. Instead the gui
  was audited by (a) `project.pbxproj` membership of every `.swift` file, (b) a repo-wide identifier count for
  every declaration in `gui/star`, and (c) reading each hit. That finds unreferenced declarations; it cannot find
  chains that are dead only transitively, so the gui list is probably shorter than the true one.
* **The C++ behind `STAR_HAVE_WGPU` was not compiled.** `wgpu/` holds only `fetch.sh` in this checkout, so
  `WGPUBackend.cpp`, `WGPUShaders.h` and `WGPUImageShaders.h` compile to (almost) nothing here. They are treated
  as live: their entry points are named from `GPUOps.swift` and reached by string lookup.
* **No linker `-dead_strip` / `-why_live` pass.** The bridge-header mapping in §3.3 answers the question the
  linker would answer ("does anything live reach this function?") at the source level and also names the Swift
  wrapper that has to go with it, and a dead-stripped release link of the cli would add a multi-minute heavy job
  for no extra finding. If a later audit wants it: `swift build -c release --package-path cli -Xlinker -dead_strip
  -Xlinker -map -Xlinker /tmp/cli.map` and diff the map against the C function list from §3.3.
* **Test targets of StarCore and StarCpp are not in the periphery index** (only the cli and daemon test bundles
  were built). "Test-only" is therefore decided by the identifier search over `*/Tests/`, not by periphery.
* **Assign-only properties (72) and redundant-public (363)** are periphery hints, not dead code; they are not
  triaged here except `Config.horizonMinY/horizonMaxY`, which are confirmed (F-30). Narrowing access is a style
  change and out of scope.

## 3. Commands

All builds and scans run under `pipeline/bin/starpipe heavy -- <cmd>`. A fresh worktree first needs the four
gitignored artifact symlinks from the memory note `gui-worktree-build` (opencv, StarDecisionTrees, gui/videos,
external_binaries/bin).

### 3.1 Swift: periphery

```bash
W=$(git rev-parse --show-toplevel)
# 1. build with the index store and with each package's test bundle
(cd $W/cli    && $W/pipeline/bin/starpipe heavy -- swift build --build-tests)     # several minutes cold
(cd $W/daemon && $W/pipeline/bin/starpipe heavy -- swift build --build-tests)     # several minutes cold
# 2. scan both index stores together, from a directory that holds a Package.swift (the cli)
cd $W/cli && $W/pipeline/bin/starpipe heavy -- periphery scan --skip-build \
    --index-store-path $W/cli/.build/debug/index/store \
    --index-store-path $W/daemon/.build/debug/index/store \
    --format csv --disable-update-check --quiet > combined.csv
```

* `--retain-public` was **not** used. StarCore, StarCppBridge and logging are libraries whose public API is
  consumed by the cli, the daemon, the gui and the tool packages; with `--retain-public` every public symbol would
  be live and nothing would be reported. Without it, public symbols used only by the gui or by a tool package
  show up as unused, which is why every row is cross-checked against the whole repo (§3.2).
* The first probe used the cli store alone (1,299 rows); the combined cli+daemon scan gave 1,230 rows
  (794 `unused`, 363 `redundantPublicAccessibility`, 72 `assignOnlyProperty`). Running it from the worktree root
  fails with "Failed to identify project" (no `Package.swift`).
* `periphery` was **not** run on `StarCpp`, `logging`, `StarDecisionTrees` or the tool packages separately: their
  code is already inside the cli/daemon index store (they are dependencies of both), and the tool packages are
  decided by §3.5.

### 3.2 Second source for every Swift row: repo-wide identifier count

`xref.py` (Appendix A) tokenises every `.swift .kt .h .hpp .cpp .mm .m .c .metal .proto .wgsl .sh .py .yml`
file (skipping `.build`, `opencv`, `external_binaries`, `ffmpeg`, `wgpu`, `pipeline`, generated protobuf and the
generated Gherkin kernel) and, for each periphery `unused` row, records which files mention the identifier.
Each row is then classed:

| Class | Meaning | Treated as |
|---|---|---|
| A | name appears in no file but the declaring one | dead (if it occurs once in total: strict dead) |
| B | only in test files | test-only |
| C | only in `gui/` or `star-desktop/` | live through a client periphery cannot see |
| D | only in a standalone tool package | live iff that tool is live (§5) |
| E | in other production sources | name collision or real use; not a finding |

Of the 794 `unused` rows: A 205, B 69, C 83, D 20, E 417; after dropping generated code, test targets, operators and parameters, 90 rows are class A and 69 class B, and 57 of the A rows are strict dead (n=1).
**Only symbols whose name occurs exactly once in the whole repo (the declaration) are filed as strict dead.**
Rows of class A with another mention in their own file (helpers called from a function that is itself reachable
from the gui) were checked by hand and dropped unless the caller is dead (e.g. `farthestFirstOrder`, called from
the live `writeMissingImages`, is kept).

### 3.3 C and C++: bridge-header mapping and clang

```bash
# every function declared in StarCpp/Sources/StarCpp/include/*.h (160 names) and who references it
python3 -I cfuncs.py   # Appendix B: regex over the headers, then identifier count over all .swift/.cpp/.mm/.kt
# the Swift wrappers that are the *only* callers of a C function: Appendix C (cdead.py), joined with the
# periphery rows of StarCppBridge/*.swift
# unused-* warnings on every translation unit, with the flags SwiftPM itself uses (read from cli/.build/debug.yaml)
pipeline/bin/starpipe heavy -- bash clangwarn.sh        # Appendix D
```

`clangwarn.sh` runs `clang -fsyntax-only -Wunused-function -Wunused-member-function -Wunused-variable
-Wunused-const-variable -Wunused-private-field -Wunneeded-internal-declaration -Wunneeded-member-function
-Wunused-template -Wunused-local-typedef -Wunused-lambda-capture` over all 21 `.cpp` files of `StarCpp` and `kht`.
Result: two warnings in total, both real (F-40, F-41). A C++ function is only counted dead when the C function
that exposes it has no live Swift caller *and* no C++ caller (`kht_bridge_get_log_handler`, which has no Swift
caller, is live through `logging_impl.hpp` and `WGPUBackend.cpp`, and was dropped for that reason).

### 3.4 gui

```bash
# files that are not in the Xcode target
cd gui && find star starTests starUITests -name '*.swift' | while read f; do
  grep -q "[ /\"]$(basename $f) " star.xcodeproj/project.pbxproj || echo "NOT IN PBXPROJ: $f"; done
# declarations in gui/star that occur once in the repo: Appendix F
```

### 3.5 Standalone tool packages

References: `grep -rIl <tool>` over the repo excluding `.git`, `.build`, `opencv` and the tool's own directory;
last change: `git log -1 -- <tool>`; builds: `swiftc -typecheck` of the tool's sources against the Swift modules the
cli build produced (Appendix E), which avoids ten more cold StarCore builds:

```bash
pipeline/bin/starpipe heavy -- bash tc.sh      # Appendix E
```

`decision_tree_generator` and `trail_tools` cannot be type-checked this way (they need `StarDecisionTrees` and the
sibling `RemovalCore` module), so their verdict rests on references only. Both are referenced from scripts or CI.

## 4. Findings

Evidence codes: **P** periphery `unused` in the cli+daemon index; **X** identifier count (n = occurrences in the
whole repo, d = in the declaring file); **R** read the code; **C** clang warning; **B** bridge-header mapping
(§3.3); **G** `project.pbxproj` / gui identifier count (§3.4); **T** `swiftc -typecheck` result. Every row has at
least two. Line numbers are at `f2e3109b`; "lines" is the span including doc comments.

### 4.1 `HomographyHorizonDetector` chain

**F-01 `HomographyHorizonDetector` and its tuning method: dead chain** (batches C01-C04)

| Part | Where | Lines |
|---|---|---|
| detector | `StarCore/Sources/StarCore/HomographyHorizonDetector.swift` (whole file) | 743 |
| tuning entry point | `FrameHorizonProcessor.swift:1641-1824`, `private func maybeTuneHorizonParameters` and `private func tuneDetector` | 184 |
| its tests | `StarCore/Tests/StarCoreTests/HomographyHorizonDetectorTests.swift` (whole file, 41 tests) | 846 |
| harness use | `HorizonScoringMeasurement.swift:330` calls `HomographyHorizonDetector.score(algorithmY:referenceY:)`, a 12-line mean-absolute-error helper | ~15 |

Kind: dead. Evidence:

* **P** reports `maybeTuneHorizonParameters` unused; **X** `maybeTuneHorizonParameters` occurs 6 times, all in
  `FrameHorizonProcessor.swift` lines 1643-1734 (its own definition and its log messages), no call site in
  StarCore, cli, daemon, gui, the tool packages or any script; **R** it is `private`, so no other file can call it.
* `tuneDetector` is called only from `maybeTuneHorizonParameters` (line 1727). `HomographyHorizonDetector(` is
  constructed once, at line 1715, inside it. No tool package references the type (**X** over the repo: the only
  other mentions are plan documents `plans/CODE_REVIEW_*.md` and the memory note that Pass 2 is not wired).
* Memory `homography-horizon-detector-verdict` agrees: detector has no call site; do not wire Pass 2 for aurora.

**What must stay** (this is why the ticket's "no call site" shorthand is not enough):

* `HorizonTunedParameters` is live. `FrameHorizonProcessor.swift:1203` and `daemon/.../HorizonHandlers.swift:263`
  call `HorizonTunedParameters.effectiveMaxDownwardExtension`, `gui/star/HorizonPainterView.swift:630,908` holds a
  `HorizonTunedParameters` and writes the painter's "down N px" stepper into `horizonReference/tuned_parameters.json`,
  and `loadTunedHorizonParameters()` / `saveTunedHorizonParameters(_:)` (FrameHorizonProcessor.swift:1613,1619,
  FrameAirplaneRemover.swift:985,988) are used by the daemon and the gui. Its tests (`HorizonTests.swift:362-440`,
  `FrameHorizonProcessorTests.swift:61-114`, `FrameHorizonProcessorInteractiveTests.swift:604-650`) guard the
  stepper that ships.
* `tunedParametersDirectory()` (FrameHorizonProcessor.swift:1628) is used by those load/save methods. Keep.
* After the detector goes, the detector-mirroring fields of `HorizonTunedParameters` (`smoothingRadius`,
  `cannyMinThreshold`, ... the "Algorithm parameters" block) are never read by a stage. They are part of the
  persisted `tuned_parameters.json` and of `HorizonTests`' backward-compatibility test, so removing them is a
  format decision for the owner; it is not in any batch. `HomographyHorizonDetector.apply(_:)` is their only reader.

Removal order: C01 (the two private methods) -> C02, C03 (tests, in two seams) -> C04 (the detector file, and a
local MAE helper in `HorizonScoringMeasurement.swift`, whose measurement still ships as a skipped-without-fixtures
test).

### 4.2 Dead StarCore files and types

| ID | File and symbol | Kind | Lines | Evidence |
|---|---|---|---|---|
| F-02 | `StarCore/Sources/StarCore/Combinations.swift`: `CombinationsSequence`, `Collection.combinations(ofCount:)` (a copy of swift-algorithms) | dead | 297 | P (3 rows); X `combinations(ofCount` / `CombinationsSequence` occur only in this file; R no `import Algorithms`, no `.combinations(` call anywhere |
| F-03 | `HoughTransform.swift`: `class HoughTransform` | dead | 182 | P; X `HoughTransform` n=1,d=1 (whole repo); R the live Hough code is `HoughLineFinder`/kht, not this class |
| F-04 | `ProcessorUsageReporter.swift` (`actor ProcessorUsageReporter`) and `ProcessorUsageTracker.swift` (`actor ProcessorUsageTracker`), near-identical copies | dead | 182 + 183 | P both; X each name occurs once repo-wide (own declaration); R neither references the other |
| F-05 | `ProcessorUsage.swift` (`struct ProcessorUsage`) and `ProcessorUsageTests.swift` | dead after F-04; test-only until then | 135 + 268 | X `ProcessorUsage` (word) is referenced only by F-04's two actors and by `ProcessorUsageTests`; R the test's doc comment says the type "is what the task runner throttles on", but no source file outside F-04 mentions `ProcessorUsage` (identifier count over the whole repo). The test guards parsing a `top` line that nothing ships |
| F-06 | `BlobImageSaver.swift`: `struct BlobImageSaver` (two static filename constants) | dead | 25 | P; X `BlobImageSaver`, `outlierTiffFilename`, `outlierYAxisBinaryFilename` n=1 each; R its own comment says it exists only for these constants |
| F-07 | `HomographyLieMapping.swift`; `StarCppBridge/HomographyLie.swift`; `StarCpp/HomographyLie.cpp`; `include/HomographyLie.h` (+ its `#include` in `StarCppBridge.h`) | dead chain (Swift mapping -> Swift wrapper -> C -> C++) | 12 + 28 + 50 + 18 + 1 | P (`HomographyLieMapping` class, `HomographyLie.log/exp`); B `homography_lie_log/exp` are called only from `HomographyLie.swift`, which only `HomographyLieMapping` calls, which nobody calls; X no test, tool or script mentions either name. **Risk:** `plans/MOVING_STAR_ALIGNMENT_PROPOSAL.md:253` says "`HomographyLie` already exists" as a basis for future work, and memory `moving-horizon-reference-propagation` chose chained earth homographies over it. The owner should confirm the proposal no longer needs it before this lands (it is easy to restore from git) |

Tool-only, not findings (see §7): `LimitedTaskGroup`/`LimitedThrowingTaskGroup` (used through
`withLimitedTaskGroup` by `decision_tree_generator` and `outlier_feature_data_classifier`), `ClassifiedData`,
`DecisionTreeStruct`, `SwiftDecisionSubtree` (`decision_tree_generator`), `TileMLClass` (`tile_classifier_tester`).

### 4.3 Dead StarCore members (strict dead: name occurs once in the repo)

| ID | File: symbols (lines each) | Evidence |
|---|---|---|
| F-10 | `Blob.swift`: `blobLinePixelScore()` (1), `medianDistanceFromIdealLine()` (9), `intensityTrim(by:)` (8), `fancyLineTrim(by:)` (43), `neighboringPixelTrim(by:)` (34), `centralLineCoord` (19), `originZeroCentralLineCoord` (19), `medianIntensities(of:)` (9) | P; X n=1 each, so no selector or string lookup by that name can exist |
| F-11 | `BlobAnalyzer.swift`: `iterateOverAllBlobs(closure:)` (16), `logBlobs()` (10) | P; X n=1 each |
| F-12 | `BoundingBox.swift`: free function `distanceOn(box:slope:yIntercept:theta:)` (36) | P; X n=1 |
| F-13 | `OutlierGroup.swift`: `pixelOverlap(with:)` (46), `exisitingNeighborLineScores` (1); `OutlierGroupDecision.swift`: `StreakDirection` (4); `OutlierGroupFeature.swift`: free `hasPixelAt(x:y:with:and:)` (18) | P; X n=1 each |
| F-14 | `PixelatedImage.swift`: `isZero(atX:andY:)` (13), `horizonTest()` (11), `uInt32Array` (2), `uInt8Array` (2), `raiseLoweredBy(_:)` (11) | P; X n=1 each (`isZero` is a common name: the count includes Swift's `.isZero`, and still n=1) |
| F-15 | `CombinedHorizonDetector.swift`: `runGrabCut(scaled:image:gcWorkingWidth:iterations:)` (6), `runFFT(scaled:image:searchTopFraction:searchBottomFraction:...)` (9); `Horizon.swift`: `combinedHorizonExtents()` (18) | P; X n=1 each |
| F-16 | `FileSystemMonitor.swift`: global `finalFileSystemMonitor` (25); `FrameAirplaneRemover.swift`: global `maxFramesProcessing` (5), `removeSubtractionImages()` (11); `FrameGraphViewModel.swift`: `hasOperations(ofType:atMax:)` (22); `ImageCache.swift`: `CompletionBox` (6); `ImageSequence.swift`: `numberOfResidentImages` (4); `KeypointCache.swift`: `hitCount()` (1); `DecodedFrameStore.swift`: `unregisterSource(folder:)` (5) | P; X n=1 each |
| F-17 | `Localization/StarLanguage.swift`: `baseCode` (5); `Localization/StarLocalization.swift`: `allKeys()` (4); `RemoveReason.swift`: `testRemovePixel` (2); `ResizableGate.swift`: `withSlot(_:)` (6); `UpdatableProgressMonitor.swift`: `lastUpdateTime` (4); `VideoAccess.swift`: `evenlySpaced(frameCount:framesPerSecond:)` (5) | P; X n=1 each |
| F-18 | `daemon/Sources/stard/Session.swift:487`: `reprocessWithReferenceHorizon()` (7); `StdioTransport.swift:94`: global `protocolOutputClosed` (1); `logging/Sources/logging/Log.swift`: `struct LogTest` (4), `threadName` (17); `UpdatableLog.swift`: `setScreenWidth(_:)` (3) | P; X n=1 each; R the dispatcher's `Horizon.Reprocess` goes to `HorizonHandlers.reprocess`, which does not call it, and `star.proto` has no request that maps to it |

The `FileSystemMonitor` actor itself stays: `fileSystemMonitor` (same file) is used by `FrameAirplaneRemover`,
`FrameOutlierProcessor` and `FrameSaveQueue`.

### 4.4 Dead C bridge functions and C++ leftovers

For each C function the Swift wrapper is the only caller (B). Header lines include doc comments.

| ID | C function (impl) / Swift wrapper | Lines | Evidence |
|---|---|---|---|
| F-20 | `ia_median_merge_filenames` (`ImageAligner.cpp:793-805`, decl `ImageAligner.h:25-34`) / `ImageAligner.medianMergeFilenames` (`ImageAligner.swift:55-67`) | 13 + 10 + 13 | P wrapper; B only caller is the wrapper; X no test or tool; R `medianImageFromMats`, which it calls, has other callers, so only these three go |
| F-21 | `pib_mask_raised_by` (`PixelatedImageBridge.cpp:550-553`, `.h:50`) / `PixelatedImageBridge.maskRaisedBy` (`.swift:97`) | 4 + 2 + 5 | P; B; X n=3 (decl, def, wrapper) |
| F-22 | `ocv_feature_set_create_empty` (`OCVFeatureSet.cpp:28-30`, `.h:11`) / `OCVFeatureSet.createEmpty` (`.swift:15`) | 3 + 1 + 3 | P; B; X n=3 |
| F-23 | `buffer_holder_as_uint32` (`BufferHolder.cpp:42`, `.h:33`) / `BufferHolder.asUInt32` (`.swift:33`) | 3 | P; B; X. `asUInt8`/`asUInt16` are test-only (§6) |
| F-24 | `gpu_ops_median_merge_available`, `gpu_ops_aligned_merge_available` (`GPUOps_C.cpp:27-33`, `GPUOps_C.h:131-132`) | 8 + 2 | B: no Swift caller (the other three `*_available` functions are called, but only from `StarCppBridgeTests`/`StarCppWGPUTests`); X n=3 each (decl, def, one doc comment) |
| F-25 | `ia_debug_pair_match_is_enabled` (`ImageAligner.cpp:4386-4388`, `.h:373`) | 3 + 1 | B no Swift caller; X n=2 |
| F-26 | `mat_wrapper_free_split` (`MatWrapper.cpp:891-897`, `.h:114`) | 7 + 1 | B no Swift caller: `MatWrapper.split` frees the array itself with `free(elems)` and takes ownership of the images (`MatWrapper.swift:158-171`), so the helper is also a trap |
| F-27 | `GPUOps.debugBuildAkazePyramid(...)` (`GPUOps.swift:141-157`) | 17 | P; X n=1 (its sibling `debugBuildSiftPyramid` has a test and stays); `CEnumExtensions.swift:12` `bruteForce` (4), P, X n=1 |
| F-28 | `ImageAligner.cpp:68` `static cv::Mat ensure8U` (15 lines) | 15 | **C** `-Wunused-function`; X n=1 in the C++ |
| F-29 | `StarCpp/Sources/kht/peak_detection.cpp:174` `std::size_t fuck = 666;` | 1 | **C** `-Wunused-variable`; R the variable is assigned and never read |

C++ files that cleared the pass with no finding: `AKAZEDetector`, `SIFTDetector`, `RandomWalkerHorizon`,
`MatWrapper`, `PixelatedImageBridge`, `OCVFeatureSet`, `GPUOps_C`, `BufferHolder`, `QoSProbe`, `StarCppBridge`,
`WGPUBackend` (not compiled here, see §2), and the `kht` sources other than F-29. In particular every shader
function is looked up by name from `GPUOps.swift` and the `WGPU*Shaders.h` string tables; none was removed.

### 4.5 `Config` properties

| ID | Property | Kind | Lines | Evidence |
|---|---|---|---|---|
| F-30 | `Config.horizonMinY`, `Config.horizonMaxY` (`Config.swift:1001-1003`, decode lines `1658-1659`) | unused `Config` property | 5 + `ConfigRoundTripTests.swift:199-200` | P `assignOnlyProperty`; X appear only in Config.swift and that test, **not** in `star.proto` (either copy), `Mapping.swift`, `ArtifactInputs.swift`, the gui view model, the Kotlin client, the cli overrides or any stage; R added 2025-08-23 "initial cut at doing optional horizon detection at startup" and never read. A stale key in an old `config.json` is ignored by the decoder, so no migration is needed |

Every other `Config` property was checked the same way (132 stored properties; identifier count over StarCore,
cli, daemon, gui and `star-desktop`, excluding the plumbing files `Config.swift`, `ArtifactInputs.swift`,
`Mapping.swift`, the proto and the gui settings view). Three looked dead and are not:
`startupHorizonFrameIndices` is set and read by `gui/star/ImageSequenceViewModel.swift:468,552` and mapped by the
daemon; `workingBytesPerPixel` and `concurrentLoadExtraMultiplier` are computed properties read inside
`Config.swift` (lines 2032-2184); `dpHorizon*Range`/`*Count` feed `dpHorizon*Values`, which `FrameHorizonProcessor`
reads (they are also read by the broken `horizon_tester`, F-60, which does not keep them alive).

### 4.6 gui

| ID | File: symbol | Kind | Lines | Evidence |
|---|---|---|---|---|
| F-50 | `gui/star/Zoomable/NSScrollViewZoomableModifier.swift`: a second `OldZoomableModifier`, `CocoaScrollViewFUCKED`, `CocoaScrollView` | abandoned file, not in the Xcode target | 342 | G not in `project.pbxproj` (it would not compile: `OldZoomableModifier` is also declared in `OldZoomableModifier.swift`); X `CocoaScrollView*` n=2 (own file) |
| F-51 | `gui/star/ExpandDownButton.swift`: `struct ExpandDownButton`; `gui/starTests/ntar_guiTests.swift` (the empty Xcode template test, not in any target) | dead / abandoned | 26 + 36 | G pbxproj lists `ExpandDownButton.swift` (4 lines to remove) and not `ntar_guiTests.swift`; X `ExpandDownButton` n=1 |
| F-52 | `gui/star/Zoomable/ZoomableModifier.swift`: `ZoomableModifier`, `View.zoomable(min:max:currentScale:)`, `TwoFingerDragOverlay`; the commented call in `ZoomableView.swift:63-72` and `FrameEditView.swift:53` | dead | 181 + ~12 | G in pbxproj (lines 53,184,289,675 to remove); X every call site is inside a `//` or `/* */` comment; `ZoomableView` uses `OldZoomableModifier` |
| F-53 | `gui/star/RightPanel.swift`: `EditablePixelThresholdView` (575), `EditableNumberOfNeighborFrames` (600), `EditableNumberOfFramesToProcessView` (625), `EditableNumberOfFramesToProcessConcurrentlyView` (838), `MemoryMultiplierView` (864-972) | dead views | 78 + 135 | G/X each name occurs once in the repo (own declaration), no `*UITests`, no Kotlin mirror. |
| F-54 | gui smaller leftovers: `AlignmentWindowView.oldBody` (599, 27), `FrameView.loadingView` (40, 15), `InitialView.fitSize` (505, 13), `ImageSequenceViewModel.clearAlignedNeighborFrameOverride` (1098, 18), `currentFrameAlignedNeighborCount` (1064, 3), `currentFrameHasAlignedNeighborOverride` (1069, 3), `makePreviews` (2534, 5), `frameLoadingProgress` (2679, 5), `finalProcessingCount` (224), `updatingFrameBatch` (367), `showAllFrameProcessingStates`/`showAllImageCacheStats` (680-681), `frameProcessingMonitor` (110), `ViewModel.replaceCursor` (546, 7), `labelText` (438), `OutlierGroupViewModel.setWillPaint` (35, 4), `ContentView` `showCodecInfo/EncoderInfo/PixelFormatInfo/MuxerInfo` (160-163), `FrameEditImageView.localID` (14), and `FocusedField` cases `maxConcurrentHorizons/Keypoints/Homographys/Merges`, `frameAlignedNeighborFrames`, `minAlignmentFrames` (15-22) | dead | ~170 | G/X each name occurs once in the whole repo; R each is a declaration (not an override, not a SwiftUI lifecycle method; `applicationShouldTerminate`, `makeBody`, `acceptsFirstResponder` were in the same count list and are protocol hooks, kept) |
| F-55 | catalogue keys owned by F-53 (25 keys): `ui.slider.align_neighbors`, `frame_as`, `frames_as`, `frames_at_once`, `horizon_floor`, `horizon_floor_none`, `horizon_floor_prefix`, `horizon_mem`, `horizon_mem_prefix`, `kp_mem`, `kp_mem_prefix`, `max_kp_ops`, `max_kp_ops_auto`, `max_kp_ops_prefix`, `merge_mem`, `merge_mem_prefix`, `n_frames_as`, `neighbor_frames`, `outlier_mem`, `outlier_mem_prefix`, `pixel_threshold`, `pixel_threshold_prefix`, `process`, `process_at_once`, `process_with` | unused localization keys belonging to dead code | 25 per table x 22 tables ~ 550 | X no `.swift` or `.kt` file outside `Localizations/` mentions any of them (checked over gui, StarCore, cli, daemon, `star-desktop/src`); R each is used only inside the F-53 ranges. Remove only after F-53 lands; `LocalizationTests.testEveryLanguageHasExactlyTheEnglishKeys` requires all 22 tables to change together |

Parity: F-50 to F-55 delete code that no screen reaches; no user-visible behaviour changes, so there is no
Kotlin twin to change. `star-desktop` was checked for `ui.slider.*` and for the view names (none).

### 4.7 Abandoned tool packages

| ID | Package | Verdict | Lines | Evidence |
|---|---|---|---|---|
| F-60 | `horizon_tester` | abandoned tool, **does not build** | 881 (4 files) | T `error: value of type 'Config' has no member 'useDPHorizonDetection'` (HorizonTesterCLI.swift:186; the option was removed 2026-03-03 in the commit that last touched the package); X no reference anywhere but `pipeline/.../adapter_star.py` `IGNORED_TOP_LEVEL`; no doc, script, CI job, plan or gherkin step |
| F-61 | `c++_test` | abandoned tool, **does not build** | 353 (3 files) | T `incorrect argument label in call (have 'fromFile:', expected 'filename:')` (main.swift:77) and a second initializer error; R hard-coded `/sp/tmp/...` input paths and a "Next steps for kernel hough transform" scratchpad; X referenced only by `emacs_load_swift.sh:11` and the pipeline ignore list. `emacs_load_swift.sh` is itself stale (it opens `kht/Sources`, which was renamed into `StarCpp` in April 2026) |
| F-62 | `blobber` | abandoned tool, **does not build** | 114 (3 files) | T `cannot find 'Blobber' in scope` (BlobberCLI.swift:70; there is no `Blobber` type in StarCore any more) and missing `import logging`; X referenced only in comments and the pipeline ignore list; last real change 2025-08-30 |
| F-63 | `tile_classifier_tester` | unreferenced tool, builds; owner decision | 260 (3 files) | T compiles clean; X no mention in any doc, script, CI job or plan outside the pipeline ignore list; last change 2026-03-04 (its own creation) and the module rename. Filed with F-62 so the owner can drop just it from the follow-up |

Live (kept): `trail_tools` and `removal_tools` (CI: `.github/workflows/gherkin.yml`, `removal-measure.yml`;
`gherkin/measure-removal.sh`; Kotlin and Swift feature runners; `test_data/datasets.json`), `decision_tree_generator`
(`re-run.sh`, `PROCESSING_DESCRIPTION.md`; produces `StarDecisionTrees`), `outlier_feature_data_classifier` (run by
`decision_tree_generator/re-run.sh`; T compiles), `tile_extractor` (producer for `train_tile_classifier.py`; T compiles),
`horizon_test_bench` (T compiles; the benchmark named in `StarCore/.../CombinedHorizonDetector.swift`'s header,
`HorizonTests.swift:449` and `.gitignore:30`).

If F-60 to F-63 land, `pipeline/src/starpipe/adapter_star.py` `IGNORED_TOP_LEVEL` should drop the four names. That
file is pipeline tooling and untouched by this audit; the T01-T03 follow-up bodies include the one-word edit.

## 5. Dependency traps checked and kept

Each of these showed up as unused in a partial view and is live:

| Symbol | Why it looked dead | Why it is live |
|---|---|---|
| `PreviewGenerationOp` | periphery (cli only) reports it unused | created by `PreviewGeneration.make`, which the daemon calls (`PreviewPrewarm.swift:60`, `PreviewFiles.swift:30`) |
| `ReferenceHorizonStatsRegistry/Cache`, `ReferenceHorizonFrameStats`, `GaussianStats3D`, `sRGBtoLAB` | periphery `unused` on several members | used by `FrameHorizonProcessor`, `HorizonRefinementPlan`, daemon `Session.swift:891`, gui `ViewModel.swift:564` |
| `HorizonTunedParameters` | named in the detector's doc comment | gui painter + daemon + `effectiveMaxDownwardExtension` (F-01) |
| `LimitedTaskGroup`, `LimitedThrowingTaskGroup` | class unused in cli/daemon | `withLimited*TaskGroup` used by `decision_tree_generator`, `outlier_feature_data_classifier` |
| `ClassifiedData`, `DecisionTreeStruct`, `SwiftDecisionSubtree`, `OutlierGroupFeature.allCasesString/isAsync`, `OutlierGroup.decisionTreeGroupValues()` | unused in the products | used by `decision_tree_generator`, a live tool |
| All 16 `OutlierGroupDecisionTreeForest_*.swift` and both `OutlierGroupForestClassifier_*.swift` | 337k generated lines | each forest hash appears in exactly one classifier (checked), classifiers are selected by `cli/StarCli.swift:423`, `daemon/Stard.swift:59`, `gui/StarApp.swift:172` |
| `kht_bridge_get_log_handler` | no Swift caller | called by `logging_impl.hpp` and `WGPUBackend.cpp` |
| `workingBytesPerPixel`, `concurrentLoadExtraMultiplier` | referenced only by tests outside Config.swift | read inside `Config.swift` |
| `farthestFirstOrder(range:)` | periphery `unused` | called from `ImageAccessor.writeMissingImages`, which the daemon/cli call |
| `ProcessedBlobs.getBlobs`, `ReleaseManager.swift` `currentRelease()`/`fetchReleases()` | periphery `unused` (cli+daemon do not call them) | `ProcessedBlobs` is used by `BlobAnalyzer`/`LinearBlobExtender`; `currentRelease()`/`fetchReleases()` are called by `newRelease()`, which `gui/star/ViewModel.swift` and `NewReleaseSheetView.swift` call |
| Metal / WGSL shader entry points | no Swift call site by name | looked up by string in `GPUOps.swift` and the `WGPU*Shaders.h` tables |

## 6. Test-only findings

"Hook" rows are production functions that exist so a test can drive or observe shipping behaviour: keep. "Helper" rows
are production-shaped code called only from its own unit test: the behaviour does not ship, so the test pins nothing a
user gets. Only the helper rows marked **remove** are in a batch (C11).

| Symbol | Test file | Verdict |
|---|---|---|
| `FrameHorizonProcessor.setMaskBudgetForTesting`, `MemoryMonitor.setRealityProbe/setSystemFloor`, `StarWarning.setMinimumInterval`, `Config.updateCallbackCount`, `DecodedFrameStore.pinnedPathCount`, `ReferenceHorizonStatsCache.removeSequence/cacheCount`, `ResourceGovernor.limitedByText`, `RunMarker.currentFormatVersion`, `StarShutdown.isShuttingDown`, `FrameSource.waitingFrames`, `ImageCache.prepareUpdate`, `AdaptiveHorizonDetector.isFirstFrame`, `VideoFrameSourceStart.isIncompleteAndUnresumable`, `VideoConvert.runFFmpegWithProgress`, `FrameAirplaneRemover.hashValue()`, `logging: logNext/getHandlers/EncodableLogData.utf8String` | the matching `*Tests` | hook: keep (guard memory gate, shutdown, resume, cache-key behaviour that ships) |
| `GPUOps` `setReadbackCopies`, `readbackPoolCounts`, `mergeCounts`, `setCopyMergeInputsForTesting`, `setDiscreteMergesForTesting`, `debugBuildSiftPyramid`; `ImageAligner.debugSift*/debugAkaze*/debugWarp/debugSet*/debugPairMatch*/debugMedian*`; `maskedStretchToGray8`; `MatWrapper.tiffIsFastReadable/atDouble`; `BufferHolder.asUInt8/asUInt16`; `FFmpegCodec.isLossy/isLossless/isIntraFrameOnly`, `FFmpegPixelFormat.canInput/inputOutputPixelFormats`, `FFmpegCodec+Extension.pixelFormatCount` | StarCppBridge GPU/equivalence tests, `FFmpegTableTests` | hook / table check: keep (CPU-vs-GPU equivalence, shipped codec tables) |
| `FullFrameBlobber.NeighborDirection` | `LegacyFullFrameBlobber.swift` (a test-target oracle for `FullFrameBlobberIdentityTests`) | keep |
| `BoundingBox.overlapAmount(with:)`, `BoundingBox.centerTheta(with:)` | `BoundingBoxTests` | helper, **remove** (57 lines + tests) |
| `Horizon.calculateStats()` | `HorizonTests` | helper, **remove** (50 + test) |
| `CombinedHorizonDetector.isPlausibleHorizon(_:imageHeight:)` | `CombinedHorizonDetectorTests` | helper, **remove** (19 + test) |
| `Line+Iteration.findSpot(between:and:closure:)` | `LineIterationTests` | helper, **remove** (34 + test) |
| `StandardLine.precised(_:)`, `StandardLine.yAtZeroX` | `StandardLineTests` | helper, **remove** (10 + test) |
| `ReferenceHorizonStats.nearestStats(to:maxCount:)`, `PixelatedImage.normalizedBrightness(x:y:maxVal:)` | `ReferenceHorizonStatsTests` | helper, **remove** (22 + test) |
| `Blob.persistentDataSizeBytes()`, `IntensityHistogram`, `ProcessingHeadline.stepBrief/stepActivity` | `BlobBinaryRoundTripTests`, `ReferenceHorizonStatsTests`, `ProcessingHeadlineTests` | undecided: each test may guard a persisted format or a string the clients show; not batched, owner to say |

## 7. Unreachable branches

None was filed. The two "dead branch" patterns the audit looked for (a config flag whose only reader is a `false`
constant; an `if` on a symbol that is never assigned) turned up one candidate, `FrameOutlierProcessor.maybeApplyOutlierGroupClassifier`'s
validation-image path, which is already commented out (lines 369-396); its private target `classifyOutliers(with:)`
(36 lines, `FrameOutlierProcessor.swift:425`) is dead for that reason and is listed in C09. A repeatable
search for the other pattern needs flow analysis that periphery does not do.

## 8. Removal batches and follow-ups

Counting rule: changed lines = deletions (these batches add almost nothing). Where one batch is a single whole-file
deletion that cannot be split, it is marked **oversize** and the reason is given. Each batch lands alone on
`develop`; "needs" marks a real ordering constraint. Batches that touch `StarCore` public API are proved by
`starpipe check`, which builds and tests what the diff touches.

| Batch | Follow-up title | Findings | ~Lines | Needs |
|---|---|---|---|---|
| C01 | Remove the uncalled horizon parameter tuning in FrameHorizonProcessor | F-01 part 2 | 184 | - |
| C02 | Remove the second half of the HomographyHorizonDetector tests | F-01 part 3a (test lines 455-846) | 392 | C01 |
| C03 | Remove the first half of the HomographyHorizonDetector tests | F-01 part 3b (lines 1-454, the file) | 454 | C02 |
| C04 | Remove the unused HomographyHorizonDetector | F-01 part 1 and 4 | 743 + ~20, **oversize** (single file, nothing references it once C01-C03 land) | C01, C03 |
| C05 | Remove the unused Combinations copy from StarCore | F-02 | 297 | - |
| C06 | Remove the unused HoughTransform, BlobImageSaver and HomographyLie chain | F-03, F-06, F-07 | 182 + 25 + 109 = 316 | - |
| C07 | Remove the duplicate ProcessorUsageReporter and ProcessorUsageTracker | F-04 | 365 | - |
| C08 | Remove the unused ProcessorUsage parser and its tests | F-05 | 403 | C07 |
| C09 | Remove unused Blob, outlier and pixel helpers from StarCore | F-10 to F-15, `classifyOutliers(with:)` | ~380 | - |
| C10 | Remove unused one-off helpers from StarCore, the daemon and logging | F-16 to F-18 | ~140 | - |
| C11 | Remove geometry and statistics helpers that only their own unit tests call | §6 helper rows marked remove | ~190 + tests | - |
| D01 | Remove unreachable C bridge functions and C++ leftovers in StarCpp | F-20 to F-29 | ~115 | - |
| D02 | Remove the unused horizonMinY and horizonMaxY Config properties | F-30 | ~8 | - |
| G01 | Remove orphaned gui source files (old zoom scroll view, ExpandDownButton, template test) | F-50, F-51 | 408 | - |
| G02 | Remove the unused gui ZoomableModifier and dead RightPanel settings views | F-52, F-53 | ~410 | - |
| G03 | Remove the pixel-threshold and frame-count slider catalogue keys | F-55: `align_neighbors`, `frame_as`, `frames_as`, `frames_at_once`, `n_frames_as`, `neighbor_frames`, `pixel_threshold`, `pixel_threshold_prefix`, `process`, `process_at_once`, `process_with` (11 keys) | ~242 | G02 |
| G04 | Remove the memory and horizon slider catalogue keys | F-55: `horizon_floor*` (3), `horizon_mem*` (2), `kp_mem*` (2), `max_kp_ops*` (3), `merge_mem*` (2), `outlier_mem*` (2) (14 keys) | ~308 | G02 |
| G05 | Remove small unused gui leftovers (old bodies, flags and focus cases) | F-54 | ~170 | - |
| T01 | Remove the broken horizon_tester package | F-60 | 881, **oversize** (whole package; nothing references it) | - |
| T02 | Remove the broken c++_test package and the stale emacs script paths | F-61 | 353 + ~4 | - |
| T03 | Remove the broken blobber and the unreferenced tile_classifier_tester packages | F-62, F-63 | 374 | - |

C09 and C10 and C11 are sized from the per-symbol line counts in §4.3 and §6; the follow-up bodies say to re-count
with `git diff --stat` and to split at a file boundary if the diff exceeds ~400 once the doc comments are included.
The rule for every follow-up is the same: re-run the evidence check for each symbol first (`grep -rwn <name>` over
the repo must still return only the declaration), delete, then run `starpipe check`.

Not batched on purpose: the detector-mirroring fields of `HorizonTunedParameters` after C04 (a persisted-format
decision), `FileSystemMonitor` after G05, the `Blob.persistentDataSizeBytes`/`IntensityHistogram`/`ProcessingHeadline`
test-only rows, the 72 assign-only properties, the 363 redundant-public hints, and the `pipeline/` ignore list.

## Appendix A - `xref.py` (identifier cross-reference)

```python
import csv, os, re, sys, collections, json
ROOT = os.getcwd()
EXT = {'.swift','.kt','.kts','.m','.mm','.h','.hpp','.cpp','.c','.cc','.metal','.proto','.wgsl','.sh','.py','.yml','.yaml'}
SKIP_DIRS = {'.build','build','.git','opencv','external_binaries','ffmpeg','wgpu','.audit-scratch','node_modules','.gradle','DerivedData','pipeline','.claude'}
tok = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
idx = collections.defaultdict(lambda: collections.Counter())   # word -> {relfile: n}
for d, dirs, files in os.walk(ROOT):
    dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
    for f in files:
        if os.path.splitext(f)[1] not in EXT: continue
        p = os.path.join(d, f)
        if os.path.islink(p): continue
        rel = os.path.relpath(p, ROOT)
        if rel.endswith('star.pb.swift') or 'Features.generated' in rel: continue
        try: s = open(p, encoding='utf-8', errors='ignore').read()
        except Exception: continue
        for w, n in collections.Counter(tok.findall(s)).items():
            idx[w][rel] = n
def kind_of(rel):
    if '/Tests/' in rel or 'Tests/' in rel.split('/')[0:3] or rel.startswith(('gui/starTests','gui/starUITests')) or '/Tests' in rel: return 'test'
    return 'src'
out = []
seen = set()
for csvp in sys.argv[1:]:
    for r in csv.DictReader(open(csvp)):
        if r['Hints'] not in ('unused','assignOnlyProperty'): continue
        loc = r['Location']; rel = loc.split('/pipe-77/')[-1]
        f, line, col = rel.rsplit(':', 2)
        name = re.split(r'[(<]', r['Name'])[0]
        key = (f, line, name)
        if key in seen: continue
        seen.add(key)
        refs = idx.get(name, {})
        decl_other = {k: v for k, v in refs.items() if k != f}
        out.append(dict(file=f, line=int(line), kind=r['Kind'], name=name, full=r['Name'], hint=r['Hints'], acc=r['Accessibility'],
                        attrs=r['Attributes'], mods=r['Modifiers'],
                        same_file=refs.get(f, 0),
                        other_src=sorted(k for k in decl_other if kind_of(k)=='src'),
                        other_test=sorted(k for k in decl_other if kind_of(k)=='test')))
json.dump(out, open('.audit-scratch/xref.json','w'), indent=1)
print(len(out))
```

## Appendix B - bridge header function list

```python
# Every function declared in StarCpp/Sources/StarCpp/include/*.h, and which files mention it.
# Output: cfuncs.json {name: {hdr, swift: [files], other: [files]}}; prints the ones with no Swift reference.
import re, os, glob, collections, json
H = glob.glob('StarCpp/Sources/StarCpp/include/*.h')
names = {}
for h in H:
    s = open(h).read()
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S); s = re.sub(r'//[^\n]*', '', s)
    for m in re.finditer(r'\b([A-Za-z]\w*)\s*\(', s):
        n = m.group(1)
        if n in ('if', 'while', 'for', 'return', 'sizeof', 'defined', 'void', 'int'): continue
        names.setdefault(n, os.path.basename(h))
tok = re.compile(r'[A-Za-z_]\w*')
SKIP = {'.build', 'build', '.git', 'opencv', 'external_binaries', 'ffmpeg', 'wgpu', '.audit-scratch', 'pipeline', '.claude'}
refs = collections.defaultdict(dict)
for d, ds, fs in os.walk('.'):
    ds[:] = [x for x in ds if x not in SKIP]
    for f in fs:
        if os.path.splitext(f)[1] in ('.swift', '.cpp', '.mm', '.hpp', '.h', '.c', '.kt', '.m'):
            p = os.path.join(d, f)
            if os.path.islink(p): continue
            s = open(p, errors='ignore').read()
            for w, n in collections.Counter(tok.findall(s)).items():
                if w in names: refs[w][p[2:]] = n
res = {}
for n, h in sorted(names.items(), key=lambda x: (x[1], x[0])):
    r = refs.get(n, {})
    sw = [k for k in r if k.endswith('.swift')]
    res[n] = dict(hdr=h, swift=sw, other=[k for k in r if not k.endswith('.swift')])
    if not sw: print("NO SWIFT:", h, n, [k.split('/')[-1] for k in res[n]['other']])
json.dump(res, open('.audit-scratch/cfuncs.json', 'w'), indent=1)
```

## Appendix C - C functions reachable only through dead Swift wrappers (`cdead.py`)

```python
import json,re,sys,os
x=json.load(open('.audit-scratch/xref.json'))
c=json.load(open('.audit-scratch/cfuncs.json'))
def body(f,line):
    L=open(f).read().split('\n')
    i=line-1; depth=0; started=False; out=[]
    while i<len(L):
        out.append(L[i])
        for ch in L[i]:
            if ch=='{': depth+=1; started=True
            elif ch=='}': depth-=1
        if started and depth<=0: break
        if not started and not L[i].rstrip().endswith((',','(')) and '{' not in L[i] and i>line-1+3: break
        i+=1
    return (line, line+len(out)-1)
dead_ranges={}   # file -> list of (start,end,name)
for o in x:
    if o['hint']!='unused' or not o['file'].startswith('StarCpp/Sources/StarCppBridge/'): continue
    if o['other_src']: continue          # referenced elsewhere in repo sources
    if o['kind'] not in('function.method.static','function.method.instance','var.instance','var.static','function.free','class','struct','enum'): continue
    s,e=body(o['file'],o['line'])
    dead_ranges.setdefault(o['file'],[]).append((s,e,o['name'],o['other_test']))
res=[]
for n,v in sorted(c.items()):
    refs=[]
    for f in v['swift']:
        if '/Tests/' in f: continue
        for i,l in enumerate(open(f).read().split('\n'),1):
            if re.search(r'\b'+n+r'\b',l): refs.append((f,i))
    if not refs: continue
    inside=[]
    ok=True
    for f,i in refs:
        r=[d for d in dead_ranges.get(f,[]) if d[0]<=i<=d[1]]
        if r: inside.append((f.split('/')[-1],r[0][2],bool(r[0][3])))
        else: ok=False
    if ok: print(f"{n} <- {inside}  testrefs={len([f for f in v['swift'] if '/Tests/' in f])}")
```

## Appendix D - clang unused-warning pass (`clangwarn.sh`)

```bash
#!/bin/bash
# Syntax-only compile of every StarCpp / kht translation unit with the unused-* warnings on.
W=$(pwd)
CLANG=$(xcrun -f clang)
SDK=$(xcrun --show-sdk-path)
FLAGS="-fobjc-arc -target x86_64-apple-macosx13.0 -O0 -DSWIFT_PACKAGE=1 -DDEBUG=1 -fblocks \
 -I $W/StarCpp/Sources/StarCpp/include -I $W/StarCpp/Sources/kht/include -fmodule-map-file=$W/StarCpp/Sources/kht/include/module.modulemap \
 -I$W/StarCpp/opencv/include -I/opt/homebrew/include/eigen3 -I/usr/local/include/eigen3 -I$W/opencv/include -isysroot $SDK -std=c++2b"
WARN="-Wunused-function -Wunused-member-function -Wunused-variable -Wunused-const-variable -Wunused-private-field -Wunneeded-internal-declaration -Wunneeded-member-function -Wunused-template -Wunused-local-typedef -Wunused-lambda-capture -Wunused-parameter"
for f in StarCpp/Sources/StarCpp/*.cpp StarCpp/Sources/kht/*.cpp; do
  echo "### $f"
  $CLANG $FLAGS $WARN -fsyntax-only -Xclang -fno-caret-diagnostics "$f" 2>&1 | grep -E "warning:|error:" | grep -F "$(dirname $f)" | sort -u
done
```

## Appendix E - tool package type-check (`tc.sh`)

```bash
#!/bin/bash
# swiftc -typecheck each standalone tool against the module set the cli build produced.
W=$(pwd); M=$W/cli/.build/debug/Modules
SDK=$(xcrun --show-sdk-path)
for t in horizon_tester tile_classifier_tester c++_test blobber horizon_test_bench tile_extractor outlier_feature_data_classifier decision_tree_generator trail_tools removal_tools; do
  echo "### $t"
  files=$(find "$t/Sources" -name '*.swift' | sort)
  extra=""
  case $t in decision_tree_generator) extra="-I $W/StarDecisionTrees/.build/debug/Modules";; esac
  main=""; [ $(echo "$files" | wc -l) -gt 1 ] && main="-parse-as-library"
  grep -q '@main' $files 2>/dev/null && main="-parse-as-library"
  xcrun swiftc -typecheck $main -swift-version 5 -target x86_64-apple-macosx14.0 -sdk $SDK -I $M \
     -Xcc -fmodule-map-file=$W/StarCpp/Sources/kht/include/module.modulemap -Xcc -fmodule-map-file=$W/cli/.build/debug/StarCpp.build/module.modulemap -Xcc -fmodule-map-file=$W/cli/.build/debug/StarCoreC.build/module.modulemap -I $W/cli/.build/debug/StarCpp.build -Xcc -I$W/StarCpp/Sources/StarCpp/include -Xcc -I$W/StarCpp/Sources/kht/include \
     $extra $files 2>&1 | grep -E "error" | sed "s#$W/##" | sort -u | head -8
done
```

## Appendix F - gui declarations that occur once in the repo (`gui_decls.py`)

```python
# Declarations in gui/star whose identifier occurs exactly once in the whole repo.
import re, os, collections
decl = re.compile(r'^[ \t]*(?:@\w+(?:\([^)]*\))?[ \t]+)*(?:(?:public|internal|private|fileprivate|open|final|static|class|mutating|override|nonisolated|indirect)[ \t]+)*(?:func|class|struct|enum|actor|protocol|typealias|var|let|case)[ \t]+([A-Za-z_]\w*)', re.M)
tok = re.compile(r'[A-Za-z_]\w*')
SKIP = {'.build', 'build', '.git', 'opencv', 'external_binaries', 'ffmpeg', 'wgpu', '.audit-scratch', 'pipeline', '.claude'}
cnt = collections.Counter(); decls = []
for d, ds, fs in os.walk('.'):
    ds[:] = [x for x in ds if x not in SKIP]
    for f in fs:
        if os.path.splitext(f)[1] in ('.swift', '.kt', '.h', '.cpp', '.mm', '.m', '.hpp', '.c', '.proto', '.metal', '.sh', '.py'):
            p = os.path.join(d, f)[2:]
            if os.path.islink(os.path.join(d, f)) or p.endswith('star.pb.swift') or 'generated' in p.lower(): continue
            s = open(os.path.join(d, f), errors='ignore').read()
            for w, n in collections.Counter(tok.findall(s)).items(): cnt[w] += n
            if p.startswith('gui/star/'):
                for m in decl.finditer(s): decls.append((p, s[:m.start()].count('\n') + 1, m.group(1)))
for p, l, n in sorted(x for x in decls if cnt[x[2]] == 1): print(p, l, n)
# note: the line number can be a few lines early (the regex consumes leading blank lines); grep -nw the name for the exact line
```
