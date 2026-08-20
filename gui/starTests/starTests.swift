//
//  starTests.swift
//
//  NOTE ON THE FILENAME: the starTests target's Sources build phase references
//  starTests/starTests.swift, but no such file existed — the original was renamed to
//  ntar_guiTests.swift on disk without updating the project, leaving the reference
//  dangling and the target unbuildable (which is why nothing here has ever run).
//  Keeping this file at the expected name repairs that without touching project.pbxproj.
//  ntar_guiTests.swift is orphaned: the project does not reference it, so it is not
//  compiled.
//
//  For the same reason, `HorizonPaintStateTests` below lives in this file rather than one
//  of its own: a new file would need a project.pbxproj edit to be compiled at all, and
//  everything the target builds has to be reachable from this one Sources entry.
//
import XCTest
import SwiftUI
import StarCore
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star

/// Each setting the gui exposes is wired by hand at two places in
/// `ImageSequenceViewModel`: a loader in `init` that reads a `Config` field into the
/// property, and a `didSet` that writes the property back to a `Config` field. Nothing
/// ties those two to the same field, and getting it wrong is silent — the control would
/// display one setting and edit another, or two controls would fight over one setting.
///
/// This is the same invariant the Kotlin client's `ExpertFieldWiringTest` pins down, but it
/// has to be checked differently. There the three accessors are values in a table that a
/// test can call; here they are statements in two different scopes of a `@MainActor`
/// `@Observable` class whose init is `async throws` and needs a `ViewModel` (which kicks
/// off a release-check network call) plus a `ConfigManager`. Standing that up to set 42
/// properties would test the wiring through a great deal of unrelated machinery. The
/// pairing is a syntactic convention between two code sites, so it is checked as one.
///
/// Note that a property name is NOT required to match its field name — several
/// legitimately differ (`numberOfNeighborFrames` is backed by
/// `numberFinalProcessingNeighborsNeeded`). What must hold is that a property loads from
/// and stores to the *same* field, whatever it is called.
final class SettingsWiringTests: XCTestCase {

    // MARK: - sources under inspection

    /// gui/, derived from this file's location: gui/starTests/starTests.swift
    private static var guiDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        let url = Self.guiDir.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func matches(_ pattern: String, in text: String) -> [[String?]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("bad pattern \(pattern)")
            return []
        }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
            }
        }
    }

    /// property name -> the single Config field its didSet writes.
    private func configWriters(in source: String) -> [String: String] {
        var writers: [String: String] = [:]
        // var NAME: TYPE {  didSet {  ... realConfig.FIELD = ... } }
        let blocks = matches(#"var\s+(\w+)\s*:[^\n{]+\{\s*\n\s*didSet\s*\{([\s\S]*?)\n\s*\}\s*\n\s*\}"#,
                             in: source)
        for b in blocks {
            guard let name = b[1], let body = b[2] else { continue }
            let written = matches(#"realConfig\.(\w+)\s*="#, in: body).compactMap { $0[1] }
            guard let first = written.first else { continue }   // didSet that touches no config
            XCTAssertEqual(Set(written).count, 1,
                           "\(name): didSet writes more than one Config field \(Set(written)), "
                           + "which this check cannot pair unambiguously")
            writers[name] = first
        }
        return writers
    }

    /// property name -> every Config field its init loader reads.
    private func configLoaders(in source: String) -> [String: Set<String>] {
        var loaders: [String: Set<String>] = [:]
        for m in matches(#"self\.(\w+)\s*=\s*[^\n]*config\.(\w+)[^\n]*"#, in: source) {
            guard let name = m[1], let field = m[2] else { continue }
            loaders[name, default: []].insert(field)
        }
        return loaders
    }

    // MARK: - the checks

    /// Guard against a vacuous pass: if the patterns above stop matching, every other test
    /// here would trivially succeed over an empty set.
    func testTheParseFindsTheSettings() throws {
        let src = try source("star/ImageSequenceViewModel.swift")
        let writers = configWriters(in: src)
        XCTAssertGreaterThan(writers.count, 40,
                             "only found \(writers.count) config-backed properties; the "
                             + "patterns have probably stopped matching the source")
        XCTAssertFalse(configLoaders(in: src).isEmpty)
    }

    func testEveryConfigBackedPropertyLoadsFromConfig() throws {
        let src = try source("star/ImageSequenceViewModel.swift")
        let loaders = configLoaders(in: src)
        for (name, field) in configWriters(in: src) {
            XCTAssertNotNil(loaders[name],
                            "\(name) writes Config.\(field) but init never loads it from "
                            + "config, so the control opens showing a value that is not the "
                            + "config's")
        }
    }

    /// The core pairing check.
    func testWriterAndLoaderAgreeOnTheSameField() throws {
        let src = try source("star/ImageSequenceViewModel.swift")
        let loaders = configLoaders(in: src)
        for (name, written) in configWriters(in: src) {
            guard let read = loaders[name] else { continue }   // covered by the test above
            XCTAssertTrue(read.contains(written),
                          "\(name) stores to Config.\(written) but loads from "
                          + "\(read.sorted()) — it would display one setting and edit another")
        }
    }

    /// Two properties backed by one field cross-wire: editing either moves the other, and
    /// whichever saves last wins.
    func testNoTwoPropertiesWriteTheSameConfigField() throws {
        let src = try source("star/ImageSequenceViewModel.swift")
        var byField: [String: [String]] = [:]
        for (name, field) in configWriters(in: src) { byField[field, default: []].append(name) }
        for (field, names) in byField where names.count > 1 {
            XCTFail("Config.\(field) is written by \(names.sorted()) — those controls "
                    + "overwrite each other")
        }
    }

    /// FocusedField cases route keyboard focus. Two editors in one view claiming the same
    /// case send focus to the wrong box.
    func testFocusFieldsAreUniqueWithinEachView() throws {
        for view in ["star/RightPanel.swift", "star/ProcessingSettingsView.swift"] {
            let uses = matches(#"focusField:\s*\.(\w+)"#, in: try source(view)).compactMap { $0[1] }
            XCTAssertFalse(uses.isEmpty, "\(view): found no focusField uses to check")
            let dupes = Dictionary(grouping: uses, by: { $0 }).filter { $0.value.count > 1 }.keys
            XCTAssertTrue(dupes.isEmpty, "\(view): focus cases used more than once: \(Array(dupes))")
        }
    }

    /// Coverage guard for the memory settings, which are the reason this file exists. A
    /// reservation knob that is not reachable from the gui is the state this campaign has
    /// been undoing; this fails if one is dropped from the settings view.
    func testMemorySettingsAreReachableFromTheSettingsView() throws {
        let settings = try source("star/ProcessingSettingsView.swift")
        let viewModel = try source("star/ImageSequenceViewModel.swift")
        let expected = [
          "keypointMemoryMultiplier",
          "outlierMemoryMultiplier",
          "mergeMemoryMultiplier",
          "horizonMemoryMultiplier",
          "horizonReservationFloorMB",
          "alignmentKeypointDetectionDivisor",
        ]
        for name in expected {
            XCTAssertTrue(settings.contains("viewModel.\(name)"),
                          "\(name) is not bound in ProcessingSettingsView")
            XCTAssertTrue(viewModel.contains("var \(name)"),
                          "\(name) is not a property on ImageSequenceViewModel")
        }
    }
}

/// `HorizonPaintState` holds the whole horizon-painting session: the brush strokes, the
/// three-phase workflow, and the per-column sky/ground boundaries that the SIOX pass is
/// constrained by.  It is the one substantial piece of the gui that is plain logic rather
/// than view code — no image, no network, no async init — and it had no coverage.
///
/// What makes it worth testing is that its invariants are all *between* properties: the
/// per-column arrays must stay the width of the view, the known-sky floor must never cross
/// the known-ground ceiling, and clearing has to reset every one of eight parallel arrays.
/// A missed array in `clear()` shows up as paint bleeding from the previous frame.
@MainActor
final class HorizonPaintStateTests: XCTestCase {

    private func state(width: CGFloat = 200, height: CGFloat = 100) -> HorizonPaintState {
        HorizonPaintState(viewWidth: width, viewHeight: height)
    }

    // MARK: - initial state

    func testAFreshStateStartsInBandSelectionWithNothingPainted() {
        let paint = state()
        XCTAssertEqual(paint.phase, .bandSelection)
        XCTAssertFalse(paint.hasStrokes)
        XCTAssertFalse(paint.isErasing)
        XCTAssertFalse(paint.isExpanding)
        XCTAssertNil(paint.expandedPath)
        XCTAssertNil(paint.lastHorizonY)
        XCTAssertNil(paint.lastGestureBounds)
    }

    /// Every per-column array is indexed by view x, so they all have to be exactly as wide as
    /// the view or a stroke near the right edge would run off the end.
    func testEveryPerColumnArrayIsAsWideAsTheView() {
        let paint = state(width: 321, height: 100)
        XCTAssertEqual(paint.bandColumnTop.count, 321)
        XCTAssertEqual(paint.bandColumnBottom.count, 321)
        XCTAssertEqual(paint.knownSkyFloor.count, 321)
        XCTAssertEqual(paint.knownGroundCeiling.count, 321)
        XCTAssertEqual(paint.gestureColumnTop.count, 321)
        XCTAssertEqual(paint.gestureColumnBottom.count, 321)
    }

    func testTheViewDimensionsAreRememberedAsGiven() {
        let paint = state(width: 640, height: 480)
        XCTAssertEqual(paint.viewWidth, 640)
        XCTAssertEqual(paint.viewHeight, 480)
    }

    // MARK: - brush sizing

    func testTheBrushShrinksAndGrowsInTenPointSteps() {
        let paint = state()
        paint.brushRadius = 100
        paint.shrinkBrush()
        XCTAssertEqual(paint.brushRadius, 90)
        paint.growBrush()
        XCTAssertEqual(paint.brushRadius, 100)
    }

    /// The clamps matter because the keys repeat: holding `[` must stop at a usable brush
    /// rather than reaching zero or a negative radius.
    func testTheBrushCannotShrinkBelowItsMinimum() {
        let paint = state()
        paint.brushRadius = HorizonPaintState.minBrushRadius
        for _ in 0..<20 { paint.shrinkBrush() }
        XCTAssertEqual(paint.brushRadius, HorizonPaintState.minBrushRadius)
        XCTAssertGreaterThan(paint.brushRadius, 0)
    }

    func testTheBrushCannotGrowAboveItsMaximum() {
        let paint = state()
        paint.brushRadius = HorizonPaintState.maxBrushRadius
        for _ in 0..<20 { paint.growBrush() }
        XCTAssertEqual(paint.brushRadius, HorizonPaintState.maxBrushRadius)
    }

    func testTheBrushBoundsAreOrdered() {
        XCTAssertLessThan(HorizonPaintState.minBrushRadius, HorizonPaintState.maxBrushRadius)
    }

    // MARK: - erasing is not available while picking the band

    /// The band is always additive — there is nothing to erase from yet — so the setter
    /// refuses to turn erasing on until the phase has moved past band selection.
    func testErasingCannotBeTurnedOnDuringBandSelection() {
        let paint = state()
        paint.isErasing = true
        XCTAssertFalse(paint.isErasing, "erasing should have been refused in band selection")
    }

    func testErasingIsAvailableOnceRefiningg() {
        let paint = state()
        paint.setPhase(.refinement)
        paint.isErasing = true
        XCTAssertTrue(paint.isErasing)
    }

    // MARK: - strokes

    func testAStrokeIsRecordedWithTheCurrentBrush() {
        let paint = state()
        paint.brushRadius = 25
        paint.addStroke(at: CGPoint(x: 50, y: 50))

        XCTAssertTrue(paint.hasStrokes)
        XCTAssertEqual(paint.strokes.count, 1)
        XCTAssertEqual(paint.strokes[0].center, CGPoint(x: 50, y: 50))
        XCTAssertEqual(paint.strokes[0].radius, 25)
        XCTAssertFalse(paint.strokes[0].isErase)
    }

    func testAStrokeMarksItsOwnAreaAsPainted() {
        let paint = state()
        paint.brushRadius = 20
        paint.addStroke(at: CGPoint(x: 100, y: 50))

        XCTAssertTrue(paint.isPainted(vx: 100, vy: 50), "the centre should be painted")
        XCTAssertFalse(paint.isPainted(vx: 100, vy: 5), "far above the brush should not be")
    }

    /// Gap filling is what turns a fast drag — which delivers only a few widely spaced
    /// events — into a continuous band rather than a row of isolated dots.
    func testAFastDragIsFilledInWithIntermediateStrokes() {
        let paint = state(width: 400, height: 200)
        paint.brushRadius = 10
        paint.addStroke(at: CGPoint(x: 20, y: 100))
        paint.addStroke(at: CGPoint(x: 200, y: 100))   // 180 points away, step is 5

        XCTAssertGreaterThan(paint.strokes.count, 2,
                             "a 180 point jump with a 10 point brush needs filling in")
        // and the middle of the jump is actually covered
        XCTAssertTrue(paint.isPainted(vx: 110, vy: 100),
                      "the midpoint of the drag should have been painted")
    }

    func testASlowDragNeedsNoFillingIn() {
        let paint = state()
        paint.brushRadius = 50
        paint.addStroke(at: CGPoint(x: 100, y: 50))
        paint.addStroke(at: CGPoint(x: 105, y: 50))   // well within half the radius
        XCTAssertEqual(paint.strokes.count, 2)
    }

    /// Lifting the mouse and clicking elsewhere must not draw a line between the two spots.
    /// That is the whole reason `endSegment` exists.
    func testLiftingTheBrushStopsTheNextStrokeFromBeingJoinedToTheLast() {
        let paint = state(width: 400, height: 200)
        paint.brushRadius = 10
        paint.addStroke(at: CGPoint(x: 20, y: 100))
        paint.endSegment()
        paint.addStroke(at: CGPoint(x: 200, y: 100))

        XCTAssertEqual(paint.strokes.count, 2, "no gap filling across a gesture boundary")
        XCTAssertFalse(paint.isPainted(vx: 110, vy: 100),
                       "the space between two separate clicks must stay unpainted")
    }

    func testTheFirstStrokeOfASessionIsNeverJoinedToAnything() {
        let paint = state()
        paint.brushRadius = 10
        paint.addStroke(at: CGPoint(x: 150, y: 50))
        XCTAssertEqual(paint.strokes.count, 1)
    }

    /// The generation counter is how a stale async expansion knows not to overwrite a path
    /// the user has since painted on.  It has to move on every stroke.
    func testEveryStrokeAdvancesTheExpansionGeneration() {
        let paint = state()
        paint.brushRadius = 20
        let before = paint.expansionGeneration
        paint.addStroke(at: CGPoint(x: 50, y: 50))
        let afterOne = paint.expansionGeneration
        XCTAssertGreaterThan(afterOne, before)

        paint.endSegment()
        paint.addStroke(at: CGPoint(x: 150, y: 50))
        XCTAssertGreaterThan(paint.expansionGeneration, afterOne)
    }

    func testAStrokeAccumulatesTheGestureBounds() {
        let paint = state()
        paint.brushRadius = 10
        paint.addStroke(at: CGPoint(x: 50, y: 50))
        guard let first = paint.lastGestureBounds else { return XCTFail("no bounds recorded") }
        XCTAssertTrue(first.contains(CGPoint(x: 50, y: 50)))

        paint.addStroke(at: CGPoint(x: 60, y: 50))
        guard let grown = paint.lastGestureBounds else { return XCTFail("no bounds recorded") }
        XCTAssertGreaterThanOrEqual(grown.width, first.width)
        XCTAssertTrue(grown.contains(CGPoint(x: 60, y: 50)))
    }

    // MARK: - band completeness

    func testAnUnpaintedBandIsNotComplete() {
        XCTAssertFalse(state().isBandComplete)
        XCTAssertEqual(state().bandCoverage, 0)
    }

    func testABandPaintedAcrossOnlyPartOfTheFrameIsNotComplete() {
        let paint = state(width: 200, height: 100)
        paint.brushRadius = 20
        paint.addStroke(at: CGPoint(x: 50, y: 50))

        XCTAssertFalse(paint.isBandComplete, "one brush dab does not span the frame")
        XCTAssertGreaterThan(paint.bandCoverage, 0)
        XCTAssertLessThan(paint.bandCoverage, 1)
    }

    /// Completeness needs coverage from edge to edge with no holes, because the horizon has to
    /// be defined for every column of the frame.
    func testABandDraggedAcrossTheWholeFrameIsComplete() {
        let paint = state(width: 200, height: 100)
        paint.brushRadius = 15
        for x in stride(from: CGFloat(-10), through: 210, by: 5) {
            paint.addStroke(at: CGPoint(x: x, y: 50))
        }

        XCTAssertTrue(paint.isBandComplete, "coverage was \(paint.bandCoverage)")
        XCTAssertEqual(paint.bandCoverage, 1, accuracy: 0.01)
    }

    /// A gap in the middle is the case the continuity check exists for — the coverage fraction
    /// alone would look healthy.
    func testABandWithAHoleInTheMiddleIsNotComplete() {
        let paint = state(width: 200, height: 100)
        paint.brushRadius = 10
        for x in stride(from: CGFloat(-10), through: 60, by: 5) {
            paint.addStroke(at: CGPoint(x: x, y: 50))
        }
        paint.endSegment()
        for x in stride(from: CGFloat(140), through: 210, by: 5) {
            paint.addStroke(at: CGPoint(x: x, y: 50))
        }

        XCTAssertFalse(paint.isBandComplete, "a hole in the middle leaves columns undefined")
    }

    /// Band boundaries only accumulate while the band is being picked; strokes made during
    /// refinement adjust the known regions instead and must not widen the band.
    func testStrokesDuringRefinementDoNotExtendTheBand() {
        let paint = state(width: 200, height: 100)
        paint.setPhase(.refinement)
        paint.brushRadius = 20
        paint.addStroke(at: CGPoint(x: 100, y: 50))

        XCTAssertTrue(paint.bandColumnTop.allSatisfy { $0 == nil },
                      "refinement strokes should leave the band alone")
    }

    // MARK: - phases

    func testThePhaseCanBeDrivenThroughTheWorkflow() {
        let paint = state()
        XCTAssertEqual(paint.phase, .bandSelection)
        paint.setPhase(.computing)
        XCTAssertEqual(paint.phase, .computing)
        paint.setPhase(.refinement)
        XCTAssertEqual(paint.phase, .refinement)
    }

    /// Moving into refinement drops the band strokes (they have served their purpose) and
    /// seeds the known regions from the band, which is what keeps refinement inside it.
    func testEnteringRefinementSeedsTheKnownRegionsFromTheBand() {
        let paint = state(width: 200, height: 100)
        paint.brushRadius = 15
        for x in stride(from: CGFloat(-10), through: 210, by: 5) {
            paint.addStroke(at: CGPoint(x: x, y: 50))
        }
        let bandTop = paint.bandColumnTop
        let bandBottom = paint.bandColumnBottom

        paint.transitionToRefinement(horizon: [Int?](repeating: 50, count: 200))

        XCTAssertEqual(paint.phase, .refinement)
        XCTAssertFalse(paint.hasStrokes, "band strokes are no longer needed for display")
        XCTAssertEqual(paint.knownSkyFloor, bandTop)
        XCTAssertEqual(paint.knownGroundCeiling, bandBottom)
    }

    func testEnteringRefinementResetsThePerGestureExtents() {
        let paint = state(width: 200, height: 100)
        paint.brushRadius = 20
        paint.addStroke(at: CGPoint(x: 100, y: 50))
        paint.transitionToRefinement(horizon: [Int?](repeating: 50, count: 200))

        XCTAssertTrue(paint.gestureColumnTop.allSatisfy { $0 == Int.max })
        XCTAssertTrue(paint.gestureColumnBottom.allSatisfy { $0 == Int.min })
    }

    // MARK: - loading a saved horizon

    /// Loading a saved reference mask skips straight to refinement, synthesising a band around
    /// the saved horizon so the brushes still have somewhere to work.
    func testLoadingASavedHorizonJumpsStraightToRefinement() {
        let paint = state(width: 200, height: 100)
        paint.loadExistingHorizon([Int?](repeating: 40, count: 200), margin: 10)

        XCTAssertEqual(paint.phase, .refinement)
        XCTAssertEqual(paint.bandColumnTop[100], 30)
        XCTAssertEqual(paint.bandColumnBottom[100], 50)
    }

    func testTheSynthesisedBandIsClampedToTheFrame() {
        let paint = state(width: 200, height: 100)
        paint.loadExistingHorizon([Int?](repeating: 5, count: 200), margin: 50)

        XCTAssertEqual(paint.bandColumnTop[100], 0, "the band cannot start above the frame")
        XCTAssertEqual(paint.bandColumnBottom[100], 55)

        let low = state(width: 200, height: 100)
        low.loadExistingHorizon([Int?](repeating: 95, count: 200), margin: 50)
        XCTAssertEqual(low.bandColumnBottom[100], 99, "the band cannot run past the last row")
    }

    /// A saved horizon can be undefined at the edges.  Those columns are filled by
    /// nearest-neighbour extrapolation so the band always spans the full width — an
    /// unpainted edge column would leave the horizon undefined there.
    func testUndefinedEdgeColumnsAreFilledFromTheirNearestNeighbour() {
        var horizon = [Int?](repeating: 40, count: 200)
        for i in 0..<10 { horizon[i] = nil }
        for i in 190..<200 { horizon[i] = nil }

        let paint = state(width: 200, height: 100)
        paint.loadExistingHorizon(horizon, margin: 10)

        XCTAssertEqual(paint.bandColumnTop[0], 30, "the leading nil run should be filled")
        XCTAssertEqual(paint.bandColumnTop[199], 30, "the trailing nil run should be filled")
        XCTAssertTrue(paint.bandColumnTop.allSatisfy { $0 != nil })
        XCTAssertTrue(paint.bandColumnBottom.allSatisfy { $0 != nil })
    }

    // MARK: - refinement gestures move the known boundaries

    /// Painting marks brushed rows as known sky, which pushes the sky floor *down*.  SIOX only
    /// scans the gap left between the floor and the ceiling, so this is how a correction
    /// actually takes effect.
    func testPaintingPushesTheKnownSkyFloorDown() {
        let paint = state(width: 200, height: 100)
        paint.loadExistingHorizon([Int?](repeating: 50, count: 200), margin: 20)
        let floorBefore = paint.knownSkyFloor[100]

        paint.brushRadius = 8
        paint.addStroke(at: CGPoint(x: 100, y: 55))
        paint.commitRefinementGesture(isErasing: false)

        guard let before = floorBefore, let after = paint.knownSkyFloor[100] else {
            return XCTFail("the floor should be defined after loading a horizon")
        }
        XCTAssertGreaterThan(after, before, "painting sky should move the floor downward")
    }

    /// Erasing marks brushed rows as known ground, which pulls the ceiling *up*.
    func testErasingPullsTheKnownGroundCeilingUp() {
        let paint = state(width: 200, height: 100)
        paint.loadExistingHorizon([Int?](repeating: 50, count: 200), margin: 20)
        let ceilingBefore = paint.knownGroundCeiling[100]

        paint.isErasing = true
        paint.brushRadius = 8
        paint.addStroke(at: CGPoint(x: 100, y: 45))
        paint.commitRefinementGesture(isErasing: true)

        guard let before = ceilingBefore, let after = paint.knownGroundCeiling[100] else {
            return XCTFail("the ceiling should be defined after loading a horizon")
        }
        XCTAssertLessThan(after, before, "erasing should move the ceiling upward")
    }

    /// The floor and ceiling must never cross: if they did, SIOX would have an inverted
    /// unknown range and the horizon would be undefined for that column.  Each direction
    /// retracts the other, which is what lets a paint undo an erase and vice versa.
    func testPaintingAndErasingTheSameColumnKeepsTheBoundariesOrdered() {
        let paint = state(width: 200, height: 100)
        paint.loadExistingHorizon([Int?](repeating: 50, count: 200), margin: 25)

        paint.brushRadius = 10
        paint.addStroke(at: CGPoint(x: 100, y: 60))
        paint.commitRefinementGesture(isErasing: false)

        paint.endSegment()
        paint.isErasing = true
        paint.addStroke(at: CGPoint(x: 100, y: 45))
        paint.commitRefinementGesture(isErasing: true)

        guard let floor = paint.knownSkyFloor[100], let ceiling = paint.knownGroundCeiling[100] else {
            return XCTFail("both boundaries should be defined")
        }
        XCTAssertLessThan(floor, ceiling,
                          "the known sky floor must stay above the known ground ceiling")
    }

    func testColumnsUntouchedByAGestureAreLeftAlone() {
        let paint = state(width: 200, height: 100)
        paint.loadExistingHorizon([Int?](repeating: 50, count: 200), margin: 20)
        let untouched = paint.knownSkyFloor[10]

        paint.brushRadius = 5
        paint.addStroke(at: CGPoint(x: 150, y: 55))
        paint.commitRefinementGesture(isErasing: false)

        XCTAssertEqual(paint.knownSkyFloor[10], untouched,
                       "a gesture at x 150 must not move column 10")
    }

    // MARK: - the expansion counter

    /// A counter rather than a flag, so that a second gesture arriving mid-expansion keeps the
    /// spinner up until the last task finishes instead of the first one clearing it.
    func testTheSpinnerStaysUpUntilTheLastExpansionFinishes() {
        let paint = state()
        XCTAssertFalse(paint.isExpanding)

        paint.beginExpanding()
        paint.beginExpanding()
        XCTAssertTrue(paint.isExpanding)
        XCTAssertEqual(paint.expandingTaskCount, 2)

        paint.endExpanding()
        XCTAssertTrue(paint.isExpanding, "one task is still running")

        paint.endExpanding()
        XCTAssertFalse(paint.isExpanding)
    }

    /// An unbalanced end — a task that failed and cleaned up twice — must not drive the count
    /// negative, or the spinner would never show again.
    func testAnExtraEndCannotDriveTheCounterNegative() {
        let paint = state()
        paint.endExpanding()
        paint.endExpanding()
        XCTAssertEqual(paint.expandingTaskCount, 0)
        XCTAssertFalse(paint.isExpanding)

        paint.beginExpanding()
        XCTAssertTrue(paint.isExpanding, "the counter is still usable afterwards")
    }

    // MARK: - clearing

    /// `clear()` has eight parallel arrays plus six scalars to reset.  Missing one is how paint
    /// from a previous frame bleeds into the next.
    func testClearingResetsEverything() {
        let paint = state(width: 200, height: 100)
        paint.brushRadius = 42
        for x in stride(from: CGFloat(-10), through: 210, by: 5) {
            paint.addStroke(at: CGPoint(x: x, y: 50))
        }
        paint.transitionToRefinement(horizon: [Int?](repeating: 50, count: 200))
        paint.isErasing = true
        paint.addStroke(at: CGPoint(x: 100, y: 50))

        paint.clear()

        XCTAssertEqual(paint.phase, .bandSelection)
        XCTAssertFalse(paint.hasStrokes)
        XCTAssertFalse(paint.isErasing)
        XCTAssertNil(paint.expandedPath)
        XCTAssertNil(paint.lastHorizonY)
        XCTAssertNil(paint.lastGestureBounds)
        XCTAssertTrue(paint.bandColumnTop.allSatisfy { $0 == nil })
        XCTAssertTrue(paint.bandColumnBottom.allSatisfy { $0 == nil })
        XCTAssertTrue(paint.knownSkyFloor.allSatisfy { $0 == nil })
        XCTAssertTrue(paint.knownGroundCeiling.allSatisfy { $0 == nil })
        XCTAssertTrue(paint.gestureColumnTop.allSatisfy { $0 == Int.max })
        XCTAssertTrue(paint.gestureColumnBottom.allSatisfy { $0 == Int.min })
        XCTAssertFalse(paint.isPainted(vx: 100, vy: 50), "the painted path should be empty")
    }

    /// The brush is a tool setting, not session data — it survives a clear so the user does not
    /// have to resize it on every frame.
    func testClearingKeepsTheBrushSize() {
        let paint = state()
        paint.brushRadius = 42
        paint.clear()
        XCTAssertEqual(paint.brushRadius, 42)
    }

    func testClearingAdvancesTheExpansionGenerationSoStaleWorkIsDropped() {
        let paint = state()
        let before = paint.expansionGeneration
        paint.clear()
        XCTAssertGreaterThan(paint.expansionGeneration, before)
    }

    func testClearingLetsGapFillingStartFreshRatherThanJoiningToTheOldStrokes() {
        let paint = state(width: 400, height: 200)
        paint.brushRadius = 10
        paint.addStroke(at: CGPoint(x: 20, y: 100))
        paint.clear()
        paint.addStroke(at: CGPoint(x: 200, y: 100))

        XCTAssertEqual(paint.strokes.count, 1, "the cleared stroke must not be filled toward")
    }

    // MARK: - advancing to the next frame

    /// The startup flow walks several frames in a row.  Each one starts fresh, but the tool
    /// settings carry over, and the phase goes to `.computing` so the view shows a spinner
    /// while any saved horizon is loaded.
    func testAdvancingToANewFrameKeepsTheBrushButDropsTheSession() {
        let paint = state(width: 200, height: 100)
        paint.setPhase(.refinement)
        paint.brushRadius = 33
        paint.addStroke(at: CGPoint(x: 100, y: 50))

        paint.resetForNewFrame()

        XCTAssertEqual(paint.phase, .computing)
        XCTAssertEqual(paint.brushRadius, 33, "the brush size carries over")
        XCTAssertFalse(paint.hasStrokes, "but the strokes do not")
        XCTAssertTrue(paint.bandColumnTop.allSatisfy { $0 == nil })
    }

    /// The erase toggle is a tool setting, so like the brush size it has to survive a frame
    /// advance.  This is order sensitive: `isErasing`'s `didSet` forces the value back to false
    /// while the phase is `.bandSelection`, which is what `clear()` leaves behind, so
    /// `resetForNewFrame` has to set the phase to `.computing` *before* restoring the toggle.
    /// Restoring first silently dropped it on every advance.
    func testTheEraseToggleSurvivesAFrameAdvance() {
        let paint = state(width: 200, height: 100)
        paint.setPhase(.refinement)
        paint.isErasing = true
        XCTAssertTrue(paint.isErasing, "erasing is on before the advance")

        paint.resetForNewFrame()

        XCTAssertEqual(paint.phase, .computing)
        XCTAssertTrue(paint.isErasing, "the erase toggle should have carried over")
    }

    /// The mirror case: an advance must not *turn erasing on* either.
    func testAnAdvanceDoesNotTurnErasingOnByItself() {
        let paint = state(width: 200, height: 100)
        paint.setPhase(.refinement)
        XCTAssertFalse(paint.isErasing)

        paint.resetForNewFrame()

        XCTAssertFalse(paint.isErasing)
    }

    // MARK: - extracting the horizon

    func testAnUnpaintedStateYieldsNoHorizonAtAll() {
        let paint = state(width: 200, height: 100)
        let horizon = paint.horizonYPerColumn(imageWidth: 200, imageHeight: 100)
        XCTAssertEqual(horizon.count, 200)
        XCTAssertTrue(horizon.allSatisfy { $0 == nil })
    }

    /// The result is always exactly `imageWidth` long, whatever the view size — the caller
    /// indexes it by image column.
    func testTheHorizonIsAlwaysAsLongAsTheImageIsWide() {
        let paint = state(width: 200, height: 100)
        paint.brushRadius = 30
        paint.addStroke(at: CGPoint(x: 100, y: 50))

        for width in [50, 100, 200, 400] {
            XCTAssertEqual(paint.horizonYPerColumn(imageWidth: width, imageHeight: 100).count,
                           width)
        }
    }

    /// A band painted across the frame gives a horizon under it: the first painted row of each
    /// column, in image coordinates.
    func testAPaintedBandProducesAHorizonUnderIt() {
        let paint = state(width: 200, height: 100)
        paint.brushRadius = 15
        for x in stride(from: CGFloat(-10), through: 210, by: 5) {
            paint.addStroke(at: CGPoint(x: x, y: 50))
        }

        let horizon = paint.horizonYPerColumn(imageWidth: 200, imageHeight: 100)
        let defined = horizon.compactMap { $0 }
        XCTAssertGreaterThan(defined.count, 150, "most columns should have a horizon")
        for y in defined {
            XCTAssertGreaterThanOrEqual(y, 0)
            XCTAssertLessThan(y, 100)
            XCTAssertLessThan(y, 50, "the top of a brush centred at 50 is above 50")
        }
    }

    /// The horizon is reported in image coordinates, so a smaller image has to scale rather
    /// than truncate — the same painted band should describe the same fraction of the frame.
    func testTheHorizonScalesWithTheRequestedImageSize() {
        let paint = state(width: 200, height: 100)
        paint.brushRadius = 15
        for x in stride(from: CGFloat(-10), through: 210, by: 5) {
            paint.addStroke(at: CGPoint(x: x, y: 50))
        }

        let full = paint.horizonYPerColumn(imageWidth: 200, imageHeight: 100)
        let half = paint.horizonYPerColumn(imageWidth: 100, imageHeight: 50)

        guard let fullMid = full[100], let halfMid = half[50] else {
            return XCTFail("the middle column should have a horizon at both sizes")
        }
        XCTAssertEqual(Double(halfMid), Double(fullMid) / 2, accuracy: 2,
                       "the horizon should sit at the same fraction of the frame")
    }

    // MARK: - which path gets drawn

    func testTheDisplayPathFallsBackToTheRawStrokesUntilAnExpansionArrives() {
        let paint = state(width: 200, height: 100)
        paint.brushRadius = 20
        paint.addStroke(at: CGPoint(x: 100, y: 50))

        XCTAssertNil(paint.expandedPath)
        XCTAssertTrue(paint.displayPath.contains(CGPoint(x: 100, y: 50)),
                      "with no expansion the raw strokes are what is shown")
    }

    /// Once an expansion lands, the sky it describes is filled from the top of the frame down
    /// to the horizon — that fill is what the user sees, not the brush strokes.
    func testAnExpansionFillsTheSkyAboveTheHorizon() {
        let paint = state(width: 200, height: 100)
        paint.applyExpandedHorizonMask([Int?](repeating: 60, count: 200))

        XCTAssertNotNil(paint.expandedPath)
        XCTAssertTrue(paint.displayPath.contains(CGPoint(x: 100, y: 10)),
                      "the sky above the horizon should be filled")
        XCTAssertFalse(paint.displayPath.contains(CGPoint(x: 100, y: 90)),
                       "the ground below it should not be")
    }

    func testAnEmptyExpansionIsIgnoredRatherThanClearingTheDisplay() {
        let paint = state(width: 200, height: 100)
        paint.brushRadius = 20
        paint.addStroke(at: CGPoint(x: 100, y: 50))
        paint.applyExpandedHorizonMask([])

        XCTAssertNil(paint.expandedPath, "an empty horizon is not a result")
        XCTAssertTrue(paint.displayPath.contains(CGPoint(x: 100, y: 50)))
    }
}

/// The low-memory alert, which used to take the window with it.
///
/// `ContentView` draws its own panels as siblings inside the root `ZStack`, and a sibling's
/// layout is the window's layout: whatever minimum size the panel needs becomes a minimum
/// size the window must satisfy.  The warning panel asked for an unbounded height — its
/// message and suggestion were `fixedSize`d vertically, so at a narrow width they grow
/// without limit — and AppKit duly grew the window to fit.  A user processing a 4240x2832
/// sequence ended up with a window 3104 points tall (measured; the screen is 1440), most of
/// it off screen, which could not be shrunk while the alert was up.
///
/// So the invariant is not about the alert's own size: it is that showing the alert does not
/// change what the window is asked to be.  A system alert is a separate window and satisfies
/// that by construction, which is what these tests pin down — along with the other half of
/// the report, an alert that came back after the user pressed OK.
@MainActor
final class WarningAlertTests: XCTestCase {

    // MARK: - window sizing

    /// The regression itself.  One window, one hosted `ContentView`, the flag toggled
    /// underneath it: the window's minimum content size and its actual content size must both
    /// come out the same as they went in.
    ///
    /// The sizing options are the ones a SwiftUI `WindowGroup` uses, so the hosting view
    /// pushes the content's minimum, ideal and maximum sizes onto the window exactly as the
    /// real app does.
    func testShowingTheAlertDoesNotResizeTheWindowOrRaiseItsMinimum() {
        let viewModel = ViewModel()
        let host = NSHostingView(rootView: ContentView().environment(viewModel))
        host.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable, .closable],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.setContentSize(NSSize(width: 900, height: 600))
        settle()

        let quietMinimum = window.contentMinSize
        let quietContent = host.frame.size

        viewModel.report(warning: warning(.memoryPressure, .critical))
        XCTAssertTrue(viewModel.showWarningAlert, "a critical warning should reach the alert")
        settle()

        XCTAssertEqual(window.contentMinSize, quietMinimum,
                       "the alert must not raise the window's minimum size")
        XCTAssertEqual(host.frame.size, quietContent,
                       "the alert must not resize the window it appears over")

        viewModel.acknowledgeWarning()
        settle()

        XCTAssertEqual(window.contentMinSize, quietMinimum)
        XCTAssertEqual(host.frame.size, quietContent,
                       "and dismissing it must not resize the window either")
    }

    // MARK: - what interrupts

    /// Only `critical` gets a modal.  Everything else goes to the banner — a modal for a
    /// condition the user cannot act on teaches them to click through the one they can.
    func testAWarningSeverityConditionDoesNotInterrupt() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .warning))

        XCTAssertFalse(viewModel.showWarningAlert)
        XCTAssertEqual(viewModel.latestWarning?.severity, .warning,
                       "it is still recorded, just not in front of the user")
        XCTAssertEqual(viewModel.bannerWarning?.kind, .memoryPressure,
                       "and it is somewhere the user can see it")
    }

    func testACriticalConditionInterrupts() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))

        XCTAssertTrue(viewModel.showWarningAlert)
        XCTAssertEqual(viewModel.warningTitle, StarWarning.Kind.memoryPressure.titleForTest)
        XCTAssertTrue(viewModel.warningMessage.contains("holding"))
    }

    // MARK: - pressing OK

    func testAcknowledgingClosesTheAlert() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.acknowledgeWarning()

        XCTAssertFalse(viewModel.showWarningAlert)
    }

    /// The other half of the report: the alert came back.  These conditions are sampled for as
    /// long as they last and `StarWarnings` re-delivers the same kind every 30 seconds, so
    /// pressing OK has to mean "I have read this", not "hide it for half a minute".
    func testAConditionTheUserHasAcknowledgedDoesNotInterruptAgain() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.acknowledgeWarning()

        viewModel.report(warning: warning(.memoryPressure, .critical))

        XCTAssertFalse(viewModel.showWarningAlert,
                       "the same condition must not put the same alert back up")
        XCTAssertEqual(viewModel.latestWarning?.kind, .memoryPressure,
                       "it is still recorded")
    }

    /// Acknowledging one condition is not acknowledging the next one.
    func testADifferentConditionStillInterrupts() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.acknowledgeWarning()

        viewModel.report(warning: warning(.outputWriteFailed, .critical))

        XCTAssertTrue(viewModel.showWarningAlert)
    }

    /// Acknowledgement is scoped to what the user acknowledged, not to whatever was reported
    /// most recently: a `warning` arriving between the alert going up and OK being pressed
    /// must not be the thing that gets silenced.
    func testANonInterruptingWarningInBetweenDoesNotStealTheAcknowledgement() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.report(warning: warning(.lowDiskSpace, .warning))
        viewModel.acknowledgeWarning()

        viewModel.report(warning: warning(.memoryPressure, .critical))
        XCTAssertFalse(viewModel.showWarningAlert, "memory pressure is what was acknowledged")

        viewModel.report(warning: warning(.lowDiskSpace, .critical))
        XCTAssertTrue(viewModel.showWarningAlert, "the disk was not")
    }

    /// A condition acknowledged about the sequence just closed should not stay acknowledged
    /// for the next one.
    func testClosingTheSequenceForgetsWhatWasAcknowledged() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.acknowledgeWarning()

        viewModel.unloadSequence()
        viewModel.report(warning: warning(.memoryPressure, .critical))

        XCTAssertTrue(viewModel.showWarningAlert)
    }

    // MARK: - the banner

    /// The banner is the whole reason a non-interrupting severity is worth having: before it
    /// existed, a `warning` in the gui went to the log and nowhere else, which in an app with
    /// no terminal means nowhere at all.
    func testTheBannerShowsWhatDidNotInterrupt() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.footprintOverBudget, .warning))

        XCTAssertEqual(viewModel.bannerWarning?.kind, .footprintOverBudget)
        XCTAssertFalse(viewModel.showWarningAlert)
    }

    /// A condition that gets the modal does not also get the banner: the user is already
    /// reading it.
    func testAConditionThatInterruptsDoesNotAlsoGetABanner() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))

        XCTAssertTrue(viewModel.showWarningAlert)
        XCTAssertNil(viewModel.bannerWarning)
    }

    /// And dismissing the alert does not leave the same sentence behind to be dismissed a
    /// second time.
    func testAcknowledgingTheAlertLeavesNoBanner() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.acknowledgeWarning()

        XCTAssertNil(viewModel.bannerWarning)
    }

    /// The pair of the suppression test above: an acknowledged condition that happens again
    /// is not silent, it is quiet.  This is what a long run under memory pressure looks like
    /// — one alert, then the banner for as long as it lasts.
    func testARepeatOfAnAcknowledgedConditionGoesToTheBanner() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .critical))
        viewModel.acknowledgeWarning()

        viewModel.report(warning: warning(.memoryPressure, .critical))

        XCTAssertFalse(viewModel.showWarningAlert)
        XCTAssertEqual(viewModel.bannerWarning?.kind, .memoryPressure)
        XCTAssertEqual(viewModel.bannerWarning?.severity, .critical,
                       "the banner colours by severity, so it must keep it")
    }

    func testDismissingTheBannerTakesItDown() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .warning))
        viewModel.dismissBanner()

        XCTAssertNil(viewModel.bannerWarning)
    }

    /// The newest report wins.  These arrive at most every 30 seconds per kind, so a queue
    /// would be showing the user a condition from several minutes ago.
    func testANewerWarningReplacesWhatTheBannerWasShowing() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.footprintOverBudget, .warning))
        viewModel.report(warning: warning(.lowSystemMemory, .warning))

        XCTAssertEqual(viewModel.bannerWarning?.kind, .lowSystemMemory)
    }

    /// A machine state that has passed takes its banner with it: a strip still saying the
    /// system is short of memory ten minutes after it stopped being true is worse than no
    /// strip at all.
    func testABannerAboutAPassingConditionTakesItselfDown() async {
        let viewModel = ViewModel()
        viewModel.bannerLifetime = 0.1
        viewModel.report(warning: warning(.memoryPressure, .warning))
        XCTAssertNotNil(viewModel.bannerWarning)

        await waitForBannerToClear(viewModel)
        XCTAssertNil(viewModel.bannerWarning)
    }

    /// Whereas a fact about the run does not stop being true, and is posted once — so a banner
    /// that expired could take it away before anyone read it.
    func testABannerAboutTheRunItselfStaysUntilDismissed() async {
        let viewModel = ViewModel()
        viewModel.bannerLifetime = 0.1
        viewModel.report(warning: warning(.outputWriteFailed, .warning))

        await waitForBannerToClear(viewModel)
        XCTAssertEqual(viewModel.bannerWarning?.kind, .outputWriteFailed,
                       "an output write failure must not time out")
    }

    /// Each report restarts the clock, which is what keeps the banner up for as long as a
    /// condition keeps being reported.
    func testAFreshReportRestartsTheBannerClock() async {
        let viewModel = ViewModel()
        viewModel.bannerLifetime = 0.4
        viewModel.report(warning: warning(.memoryPressure, .warning))

        try? await Task.sleep(nanoseconds: 300_000_000)
        viewModel.report(warning: warning(.memoryPressure, .warning))
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertNotNil(viewModel.bannerWarning,
                        "the first timer must not take down the second warning")
    }

    func testClosingTheSequenceTakesTheBannerDown() {
        let viewModel = ViewModel()
        viewModel.report(warning: warning(.memoryPressure, .warning))
        viewModel.unloadSequence()

        XCTAssertNil(viewModel.bannerWarning)
    }

    /// The banner is an overlay rather than another member of the root `ZStack`, so that it
    /// cannot do what the old warning panel did to the window.  Same measurement as the alert
    /// test above.
    func testShowingTheBannerDoesNotResizeTheWindowOrRaiseItsMinimum() {
        let viewModel = ViewModel()
        let host = NSHostingView(rootView: ContentView().environment(viewModel))
        host.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable, .closable],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.setContentSize(NSSize(width: 900, height: 600))
        settle()

        let quietMinimum = window.contentMinSize
        let quietContent = host.frame.size

        viewModel.report(warning: warning(.memoryPressure, .warning))
        XCTAssertNotNil(viewModel.bannerWarning)
        settle()

        XCTAssertEqual(window.contentMinSize, quietMinimum,
                       "the banner must not raise the window's minimum size")
        XCTAssertEqual(host.frame.size, quietContent,
                       "the banner must not resize the window it appears over")
    }

    // MARK: - the alert's text

    /// The system alert takes one body string, so the suggestion has to be folded into it —
    /// and kept as its own paragraph, because unlike an error there is usually something the
    /// user can do.
    func testTheSuggestionBecomesItsOwnParagraph() {
        let viewModel = ViewModel()
        viewModel.report(warning: StarWarning(kind: .memoryPressure,
                                              severity: .critical,
                                              message: "the message",
                                              suggestion: "the suggestion"))

        XCTAssertEqual(viewModel.warningAlertText, "the message\n\nthe suggestion")
    }

    func testAConditionWithNothingToSuggestIsJustTheMessage() {
        let viewModel = ViewModel()
        viewModel.report(warning: StarWarning(kind: .previousRunDied,
                                              severity: .critical,
                                              message: "the message"))

        XCTAssertEqual(viewModel.warningAlertText, "the message")
    }

    // MARK: - helpers

    private func warning(_ kind: StarWarning.Kind,
                         _ severity: StarWarning.Severity) -> StarWarning
    {
        StarWarning(kind: kind,
                    severity: severity,
                    message: "star is holding 101311MB, and this is a sentence long enough to "
                      + "wrap several times over in a narrow column, which is what made the "
                      + "hand-drawn panel's height unbounded.",
                    suggestion: "Closing other applications now may let this run finish. If it "
                      + "is stopped, resume it and add --keypoint-divisor 1.5 to use less "
                      + "memory.")
    }

    /// SwiftUI pushes size changes onto the window on its own update cycle, not inside the
    /// call that changed the state, so the run loop has to turn before the window can be
    /// asked what it now believes.
    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Waits out a (deliberately tiny) `bannerLifetime`, polling rather than sleeping a fixed
    /// time so the test is not racing the expiry task on a loaded machine.
    private func waitForBannerToClear(_ viewModel: ViewModel,
                                      within seconds: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, viewModel.bannerWarning != nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

extension StarWarning.Kind {
    /// `title` is localized, so a test asserting on it has to ask for it the same way the view
    /// does rather than hard-coding English.
    var titleForTest: String {
        StarWarning(kind: self, severity: .warning, message: "").title
    }
}
