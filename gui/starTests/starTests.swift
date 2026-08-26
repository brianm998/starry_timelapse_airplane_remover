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
import Observation
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
    ///
    /// The floor is deliberately far below the real count (40 at the time of writing) — it is
    /// there to catch the parse breaking, not to inventory the settings.  A snug floor just
    /// fails the next time a setting is legitimately retired, which it has already done twice.
    func testTheParseFindsTheSettings() throws {
        let src = try source("star/ImageSequenceViewModel.swift")
        let writers = configWriters(in: src)
        XCTAssertGreaterThan(writers.count, 30,
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

/// The processing modal draws one bar per step from `FrameGraphViewModel`'s operation
/// counters.  Those counters are cumulative for as long as a sequence is open — they only
/// reset when it is closed — so every number the modal shows is a subtraction, and a
/// subtraction that is wrong still draws a perfectly plausible bar.  That is what these
/// pin down.
final class ProcessingStepsTests: XCTestCase {

    // MARK: - which steps are listed

    /// Everything on: a moving camera with earth alignment, horizon detection and a clean
    /// method that reviews outliers.
    private func allSteps() -> [OperationType] {
        ProcessingSteps.types(horizonDetectionEnabled: true,
                              hasStaticReferenceHorizon: false,
                              cameraWasMoving: true,
                              allowEarthAlignment: true,
                              usesOutliers: true)
    }

    func testTheStepsAreInTheOrderTheModalStacksThem() {
        XCTAssertEqual(allSteps(),
                       [.horizon, .mergedHorizon,
                        .starKeypoints, .earthKeypoints,
                        .starHomography, .earthHomography,
                        .outliers, .merge])
    }

    func testEarthStepsAreNotListedWhenEarthAlignmentIsOff() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: true,
                                          hasStaticReferenceHorizon: false,
                                          cameraWasMoving: true,
                                          allowEarthAlignment: false,
                                          usesOutliers: true)
        XCTAssertEqual(types, [.horizon, .mergedHorizon, .starKeypoints, .starHomography,
                               .outliers, .merge])
    }

    /// The setting is not enough on its own: `FrameGraphBuilder` needs the camera to have
    /// been moving too, so on a fixed tripod these rows would sit at zero all run.
    func testEarthStepsAreNotListedForAFixedCameraEvenWithEarthAlignmentOn() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: true,
                                          hasStaticReferenceHorizon: false,
                                          cameraWasMoving: false,
                                          allowEarthAlignment: true,
                                          usesOutliers: true)
        XCTAssertFalse(types.contains(.earthKeypoints))
        XCTAssertFalse(types.contains(.earthHomography))
    }

    /// Earth work is masked by the horizon, so with no horizon detection there is none of
    /// it either — the builder gates both on `hasHorizon && processEarth`.
    func testEarthStepsAreNotListedWithoutHorizonDetection() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: false,
                                          hasStaticReferenceHorizon: false,
                                          cameraWasMoving: true,
                                          allowEarthAlignment: true,
                                          usesOutliers: true)
        XCTAssertEqual(types, [.starKeypoints, .starHomography, .outliers, .merge])
    }

    func testHorizonStepsAreNotListedWhenHorizonDetectionIsOff() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: false,
                                          hasStaticReferenceHorizon: false,
                                          cameraWasMoving: false,
                                          allowEarthAlignment: false,
                                          usesOutliers: true)
        XCTAssertEqual(types, [.starKeypoints, .starHomography, .outliers, .merge])
    }

    /// A painted reference horizon on a static sequence is used directly, so neither
    /// detection nor the merge that combines detections runs at all.
    func testHorizonStepsAreNotListedForAPaintedStaticReference() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: true,
                                          hasStaticReferenceHorizon: true,
                                          cameraWasMoving: false,
                                          allowEarthAlignment: false,
                                          usesOutliers: true)
        XCTAssertFalse(types.contains(.horizon))
        XCTAssertFalse(types.contains(.mergedHorizon))
    }

    /// The same painted reference does not apply to a moving sequence — there the painted
    /// frames are references for detection rather than a replacement for it.
    func testHorizonStepsSurviveAPaintedReferenceWhenTheCameraMoved() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: true,
                                          hasStaticReferenceHorizon: true,
                                          cameraWasMoving: true,
                                          allowEarthAlignment: false,
                                          usesOutliers: true)
        XCTAssertTrue(types.contains(.horizon))
        XCTAssertTrue(types.contains(.mergedHorizon))
    }

    func testOutliersAreNotListedForACleanMethodThatDoesNotUseThem() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: true,
                                          hasStaticReferenceHorizon: false,
                                          cameraWasMoving: true,
                                          allowEarthAlignment: false,
                                          usesOutliers: false)
        XCTAssertFalse(types.contains(.outliers))
        XCTAssertEqual(types.last, .merge)
    }

    /// The two steps every run takes, whatever it is configured to do.
    func testKeypointsAndTheMergeAreAlwaysListed() {
        for horizon in [true, false] {
            for earth in [true, false] {
                for moving in [true, false] {
                    for outliers in [true, false] {
                        let types = ProcessingSteps.types(
                          horizonDetectionEnabled: horizon,
                          hasStaticReferenceHorizon: false,
                          cameraWasMoving: moving,
                          allowEarthAlignment: earth,
                          usesOutliers: outliers)
                        XCTAssertTrue(types.contains(.starKeypoints))
                        XCTAssertTrue(types.contains(.starHomography))
                        XCTAssertTrue(types.contains(.merge))
                        XCTAssertFalse(types.contains(.preview))
                    }
                }
            }
        }
    }

    /// Every listed step needs a row label, and `localized` returns the key itself when the
    /// catalogue does not have it — which renders as `ui.merged_horizon` on screen rather
    /// than as anything a user would recognise.
    func testEveryListedStepHasALabelFromTheCatalogue() {
        for type in allSteps() {
            let name = type.stepName
            XCTAssertFalse(name.isEmpty, "\(type) has no name")
            XCTAssertFalse(name.hasPrefix("ui."),
                           "\(type) is labelled '\(name)', which is a missing catalogue key")
        }
    }

    /// Same for the tooltip that explains the step.  An empty one is a row that silently
    /// stops explaining itself; a `ui.` one is the key showing through.
    func testEveryListedStepHasHoverHelpFromTheCatalogue() {
        for type in allSteps() {
            let help = type.stepHelp
            XCTAssertFalse(help.isEmpty, "\(type) has no hover help")
            XCTAssertFalse(help.hasPrefix("ui."),
                           "\(type)'s hover help is '\(help)', a missing catalogue key")
            XCTAssertNotEqual(help, type.stepName,
                              "\(type)'s hover help just repeats its label")
        }
    }

    // MARK: - which steps are drawn

    private func progress(_ entries: [(OperationType, Int)]) -> [ProcessingStepProgress] {
        entries.map { ProcessingStepProgress(type: $0.0, queued: $0.1, running: 0, done: 0) }
    }

    /// The point of the whole exercise: a step whose artifacts were all already on disk
    /// built no operations, so it is not a step this run takes and it should not be a row.
    func testAStepWithNothingToDoIsNotDrawnOnceThePlanIsSettled() {
        let steps = progress([(.horizon, 0), (.starKeypoints, 19), (.merge, 19)])
        let visible = ProcessingSteps.visible(steps, graphIsBuilt: true)

        XCTAssertEqual(visible.map(\.type), [.starKeypoints, .merge])
    }

    /// Until the builder has finished, every step has no operations yet.  Filtering then
    /// would open the panel empty and pop the rows in one at a time.
    func testNothingIsHiddenWhileThePlanIsStillBeingWorkedOut() {
        let steps = progress([(.horizon, 0), (.starKeypoints, 0), (.merge, 0)])
        let visible = ProcessingSteps.visible(steps, graphIsBuilt: false)

        XCTAssertEqual(visible.map(\.type), [.horizon, .starKeypoints, .merge])
    }

    /// A step that has finished still has operations, so it keeps its filled bar rather
    /// than vanishing at the moment it completes.
    func testAFinishedStepIsStillDrawn() {
        let done = ProcessingStepProgress(type: .horizon, queued: 0, running: 0, done: 19)
        let visible = ProcessingSteps.visible([done], graphIsBuilt: true)

        XCTAssertEqual(visible.map(\.type), [.horizon])
    }

    // MARK: - the arithmetic

    private func counts(_ entries: [OperationType: (queued: UInt, running: UInt, done: UInt)])
      -> [OperationType: [OperationState: UInt]]
    {
        entries.mapValues { [.queued: $0.queued, .running: $0.running, .done: $0.done] }
    }

    private func step(_ progress: [ProcessingStepProgress],
                      _ type: OperationType) throws -> ProcessingStepProgress
    {
        try XCTUnwrap(progress.first { $0.type == type })
    }

    func testAStepReportsItsQueuedRunningAndDoneCounts() throws {
        let progress = ProcessingSteps.progress(
          for: [.horizon],
          counts: counts([.horizon: (queued: 5, running: 2, done: 3)]))
        let horizon = try step(progress, .horizon)

        XCTAssertEqual(horizon.queued, 5)
        XCTAssertEqual(horizon.running, 2)
        XCTAssertEqual(horizon.done, 3)
        XCTAssertEqual(horizon.total, 10)
        XCTAssertTrue(horizon.hasWork)
    }

    func testTheBarSegmentsAreFractionsOfTheWholeStep() throws {
        let progress = ProcessingSteps.progress(
          for: [.merge],
          counts: counts([.merge: (queued: 1, running: 1, done: 2)]))
        let merge = try step(progress, .merge)

        XCTAssertEqual(merge.doneFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(merge.runningFraction, 0.25, accuracy: 0.0001)
    }

    /// A step whose artifacts were all on disk already builds no operations at all.  It has
    /// to divide by something other than zero, and it must not read as 100% done.
    func testAStepWithNoOperationsHasNoWorkAndNoFilledBar() throws {
        let progress = ProcessingSteps.progress(for: [.starKeypoints], counts: [:])
        let keypoints = try step(progress, .starKeypoints)

        XCTAssertEqual(keypoints.total, 0)
        XCTAssertFalse(keypoints.hasWork)
        XCTAssertEqual(keypoints.doneFraction, 0)
        XCTAssertEqual(keypoints.runningFraction, 0)
    }

    func testAStepIsAskedForEvenWhenTheCountersHaveNothingForIt() {
        let progress = ProcessingSteps.progress(
          for: [.horizon, .merge],
          counts: counts([.horizon: (queued: 0, running: 0, done: 4)]))

        XCTAssertEqual(progress.map(\.type), [.horizon, .merge],
                       "every requested step needs a row, so the rows do not move about "
                         + "as the run reaches each one")
    }

    // MARK: - work finished before the run started

    /// The bug this exists for: star was stopped part way through a 1434 frame sequence,
    /// 494 of them already merged.  The rebuilt graph only has merge ops for the 940 that
    /// are left, so counting operations alone reported "74 / 940" against a sequence the
    /// line above it called 1434 frames — the wrong job, and a bar that jumps backwards
    /// every time the run is resumed.
    func testAResumedStepIsMeasuredAgainstTheWholeSequence() throws {
        let progress = ProcessingSteps.progress(
          for: [.merge],
          counts: counts([.merge: (queued: 866, running: 0, done: 74)]),
          alreadyDone: [.merge: 494])
        let merge = try step(progress, .merge)

        XCTAssertEqual(merge.total, 1434)
        XCTAssertEqual(merge.completed, 568)
        XCTAssertEqual(merge.doneFraction, 568.0 / 1434.0, accuracy: 0.0001)
    }

    /// Work done before the run counts as done, not as running or queued, so the bar fills
    /// from the same end whichever run did it.
    func testWorkFromBeforeTheRunFillsTheDoneEndOfTheBar() throws {
        let progress = ProcessingSteps.progress(
          for: [.starKeypoints],
          counts: counts([.starKeypoints: (queued: 2, running: 1, done: 1)]),
          alreadyDone: [.starKeypoints: 6])
        let keypoints = try step(progress, .starKeypoints)

        XCTAssertEqual(keypoints.total, 10)
        XCTAssertEqual(keypoints.completed, 7)
        XCTAssertEqual(keypoints.doneFraction, 0.7, accuracy: 0.0001)
        XCTAssertEqual(keypoints.runningFraction, 0.1, accuracy: 0.0001)
        XCTAssertEqual(keypoints.queued, 2)
    }

    /// A step finished entirely by an earlier run builds no operations at all.  It is not a
    /// step with nothing to it — it is a step that is done — so it keeps its row, full.
    func testAStepFinishedBeforeTheRunIsShownComplete() throws {
        let progress = ProcessingSteps.progress(
          for: [.horizon],
          counts: [:],
          alreadyDone: [.horizon: 1434])
        let horizon = try step(progress, .horizon)

        XCTAssertTrue(horizon.hasWork)
        XCTAssertEqual(horizon.completed, 1434)
        XCTAssertEqual(horizon.total, 1434)
        XCTAssertEqual(horizon.doneFraction, 1)
        XCTAssertEqual(ProcessingSteps.visible([horizon], graphIsBuilt: true).map(\.type),
                       [.horizon],
                       "a step that is finished is not a step to hide")
    }

    /// Nothing on disk and nothing to do is still nothing, and still goes.
    func testAStepWithNeitherOperationsNorEarlierWorkIsStillHidden() throws {
        let progress = ProcessingSteps.progress(for: [.mergedHorizon], counts: [:])
        let merged = try step(progress, .mergedHorizon)

        XCTAssertFalse(merged.hasWork)
        XCTAssertTrue(ProcessingSteps.visible([merged], graphIsBuilt: true).isEmpty)
    }

    /// The segments still tile the bar exactly once earlier work is one of them.
    func testTheSegmentsFillTheWholeBarWithEarlierWorkInIt() throws {
        let progress = ProcessingSteps.progress(
          for: [.merge],
          counts: counts([.merge: (queued: 3, running: 2, done: 1)]),
          alreadyDone: [.merge: 4])
        let merge = try step(progress, .merge)

        XCTAssertEqual(merge.doneFraction + merge.runningFraction
                         + Double(merge.queued) / Double(merge.total),
                       1, accuracy: 0.0001)
    }

    // MARK: - the baseline

    /// The whole point of the baseline: a second run in the same session starts with the
    /// first run's operations still counted as done, and without subtracting them the bars
    /// would open most of the way across.
    func testASecondRunMeasuresFromWhereTheFirstOneFinished() throws {
        let baseline = counts([.horizon: (queued: 0, running: 0, done: 20)])
        let now = counts([.horizon: (queued: 2, running: 1, done: 22)])

        let horizon = try step(ProcessingSteps.progress(for: [.horizon],
                                                        counts: now,
                                                        since: baseline),
                               .horizon)
        XCTAssertEqual(horizon.total, 5, "this run created five ops, not twenty five")
        XCTAssertEqual(horizon.done, 2)
        XCTAssertEqual(horizon.running, 1)
        XCTAssertEqual(horizon.queued, 2)
    }

    func testAnEmptyBaselineMeasuresEverythingTheCountersHold() throws {
        let now = counts([.merge: (queued: 0, running: 0, done: 7)])
        let merge = try step(ProcessingSteps.progress(for: [.merge], counts: now), .merge)

        XCTAssertEqual(merge.done, 7)
        XCTAssertEqual(merge.total, 7)
        XCTAssertEqual(merge.doneFraction, 1)
    }

    /// The gui does not let a second run start while one is going, but nothing in the
    /// arithmetic depends on that: a baseline taken with work still in flight has to produce
    /// a bar that can be drawn, not a negative width.
    func testLeftoverOperationsFromBeforeTheBaselineCannotMakeASegmentNegative() throws {
        let baseline = counts([.starHomography: (queued: 3, running: 0, done: 0)])
        // those three finished, and nothing new was ever queued
        let now = counts([.starHomography: (queued: 0, running: 0, done: 3)])

        let align = try step(ProcessingSteps.progress(for: [.starHomography],
                                                      counts: now,
                                                      since: baseline),
                             .starHomography)
        XCTAssertGreaterThanOrEqual(align.queued, 0)
        XCTAssertGreaterThanOrEqual(align.running, 0)
        XCTAssertGreaterThanOrEqual(align.done, 0)
        XCTAssertEqual(align.total, align.queued + align.running + align.done)
        XCTAssertLessThanOrEqual(align.doneFraction, 1)
    }

    /// Every op the counters hold is in exactly one state, so the three segments always add
    /// up to the whole bar however the counts move.
    func testTheSegmentsAlwaysFillExactlyTheWholeBar() throws {
        for done in 0...4 {
            for running in 0...4 {
                let now = counts([.merge: (queued: 4, running: UInt(running), done: UInt(done))])
                let merge = try step(ProcessingSteps.progress(for: [.merge], counts: now), .merge)
                XCTAssertEqual(merge.doneFraction + merge.runningFraction
                                 + Double(merge.queued) / Double(merge.total),
                               1, accuracy: 0.0001)
            }
        }
    }
}

/// The moving-video startup prompt suggests how many reference horizons to paint by hand.
/// It used to suggest 3 whatever the sequence length, which is too few for a long moving
/// sequence: 12 was measured to work well over 1450 frames.  The suggestion is now derived
/// from the length, and the numbers it lands on are what this pins down — together with the
/// bound the stepper beside it relies on, that the suggestion is always a value the stepper's
/// `1...total` range can actually hold.
///
/// The Kotlin client duplicates the formula (`suggestedMovingHorizonCount` in
/// `AppViewModel.kt`, checked by `StartupHorizonTest`); the expected values here and there
/// are deliberately the same.
@MainActor
final class SuggestedHorizonCountTests: XCTestCase {

    private func suggestion(_ total: Int) -> Int {
        ImageSequenceViewModel.suggestedMovingHorizonCount(total: total)
    }

    // MARK: - how it scales

    /// 12 over 1450 frames is the measured value the curve is anchored to.
    func testTheSuggestionMatchesTheMeasuredValueForA1450FrameSequence() {
        XCTAssertEqual(suggestion(1450), 12)
    }

    func testTheSuggestionGrowsWithTheSequenceLength() {
        XCTAssertEqual(suggestion(1000), 10)
        XCTAssertEqual(suggestion(2000), 14)
        XCTAssertEqual(suggestion(5000), 22)
    }

    /// Growth has to be sublinear: a fixed one-horizon-every-N-frames rate would ask for over
    /// forty hand-painted horizons at 5000 frames, which nobody would sit through.  Doubling
    /// the sequence must grow the suggestion, but by less than double.
    func testTheSuggestionGrowsMoreSlowlyThanTheSequence() {
        XCTAssertGreaterThan(suggestion(2900), suggestion(1450))
        XCTAssertLessThan(suggestion(2900), 2 * suggestion(1450))
    }

    // MARK: - the short end

    /// Nothing under about 120 frames should see a different suggestion than before, where
    /// the spacing is already tight enough.
    func testShortSequencesStillGetThree() {
        XCTAssertEqual(suggestion(50), 3)
        XCTAssertEqual(suggestion(122), 3)
        XCTAssertEqual(suggestion(123), 4)
    }

    // MARK: - the bound the stepper depends on

    func testTheSuggestionNeverExceedsTheSequence() {
        XCTAssertEqual(suggestion(1), 1)
        XCTAssertEqual(suggestion(2), 2)
    }

    /// `maxCount` floors at 1 even for an empty sequence, so the suggestion has to as well
    /// or the stepper would start outside its own range.
    func testAnEmptySequenceSuggestsOne() {
        XCTAssertEqual(suggestion(0), 1)
        XCTAssertEqual(suggestion(-5), 1)
    }

    func testTheSuggestionIsAlwaysInsideTheSteppersRange() {
        for total in 1...6000 {
            let n = suggestion(total)
            XCTAssertGreaterThanOrEqual(n, 1, "suggestion \(n) below 1 for \(total) frames")
            XCTAssertLessThanOrEqual(n, total, "suggestion \(n) above \(total) frames")
        }
    }

    /// A longer sequence must never ask for fewer horizons than a shorter one.
    func testTheSuggestionNeverDecreasesAsTheSequenceGrows() {
        var previous = 0
        for total in 1...6000 {
            let n = suggestion(total)
            XCTAssertGreaterThanOrEqual(n, previous, "suggestion dropped at \(total) frames")
            previous = n
        }
    }
}

/// What the user picks in that prompt is remembered, so the next sequence starts from their
/// taste rather than star's.  It is remembered as a multiple of what star suggested, not as a
/// count: 12 references over 1450 frames means "one about every 120 frames", and storing the
/// 12 would ask for the same 12 on a 200 frame sequence.
///
/// The arithmetic lives in statics precisely so it can be checked without standing up a live
/// view model.  The Kotlin client duplicates it (`preferredMovingHorizonCount` /
/// `movingHorizonCountMultiplier` in `AppViewModel.kt`) and shares the preferences file, so the
/// expected values here and in `StartupHorizonTest` are deliberately the same.
@MainActor
final class RememberedHorizonCountTests: XCTestCase {

    private func preferred(_ total: Int, _ multiplier: Double?) -> Int {
        ImageSequenceViewModel.preferredMovingHorizonCount(total: total, multiplier: multiplier)
    }

    private func multiplier(chosen: Int, total: Int) -> Double {
        ImageSequenceViewModel.movingHorizonCountMultiplier(chosen: chosen, total: total)
    }

    // MARK: - with nothing remembered

    func testNoRecordedPreferenceLeavesTheSuggestionAlone() {
        XCTAssertEqual(preferred(1450, nil), 12)
        XCTAssertEqual(preferred(50, nil), 3)
    }

    // MARK: - what gets recorded

    func testAChoiceIsRecordedRelativeToWhatWasSuggested() {
        XCTAssertEqual(multiplier(chosen: 24, total: 1450), 2.0)   // star suggested 12
        XCTAssertEqual(multiplier(chosen: 6, total: 1450), 0.5)
        XCTAssertEqual(multiplier(chosen: 12, total: 1450), 1.0)
    }

    // MARK: - what it does next time

    /// The whole point: a choice made on one sequence carries proportionally to another length.
    func testTheMultiplierCarriesToADifferentSequenceLength() {
        let m = multiplier(chosen: 24, total: 1450) // "twice what star suggests"
        XCTAssertEqual(preferred(1450, m), 24)
        XCTAssertEqual(preferred(1000, m), 20)      // 10 suggested → 20
        XCTAssertEqual(preferred(5000, m), 44)      // 22 suggested → 44
    }

    /// Re-opening a sequence of the same length must offer exactly what was picked there, or
    /// the number would drift every time the user looked at it.
    func testRecordingThenApplyingRoundTripsForEveryCount() {
        for total in [1, 2, 10, 123, 1450, 6000] {
            for chosen in Set([1, 2, 3, total / 2, total]).filter({ (1...total).contains($0) }) {
                XCTAssertEqual(preferred(total, multiplier(chosen: chosen, total: total)), chosen,
                               "round trip \(chosen) of \(total)")
            }
        }
    }

    /// Asking for fewer has to be able to go below the suggestion curve's floor of 3 — the
    /// floor describes star's default taste, not a limit on the user's.
    func testAPreferenceForFewerGoesBelowTheFloorOfThree() {
        let m = multiplier(chosen: 1, total: 1000)  // 1 of the 10 suggested
        XCTAssertEqual(preferred(200, m), 1)        // 4 suggested × 0.1 → 1, not 3
        XCTAssertEqual(preferred(5000, m), 2)       // 22 suggested × 0.1 → 2
    }

    func testThePreferredCountIsAlwaysAValidStepperValue() {
        for m in [0.05, 0.5, 1.0, 2.5, 40.0] {
            for total in [1, 2, 3, 50, 1450, 6000] {
                let n = preferred(total, m)
                XCTAssertGreaterThanOrEqual(n, 1, "preferred \(n) below 1 at ×\(m)")
                XCTAssertLessThanOrEqual(n, total, "preferred \(n) above \(total) at ×\(m)")
            }
        }
    }

    /// A file written by hand, or by a future version, must not be able to produce a count the
    /// stepper cannot show.
    func testANonsenseMultiplierFallsBackToTheSuggestion() {
        XCTAssertEqual(preferred(1450, 0), 12)
        XCTAssertEqual(preferred(1450, -2), 12)
        XCTAssertEqual(preferred(1450, .nan), 12)
        XCTAssertEqual(preferred(1450, .infinity), 12)
    }

    /// A finite but preposterous multiplier scales past what an `Int` can hold, and converting
    /// that traps — so it has to be capped while it is still a `Double`.  This test crashes
    /// rather than fails if that ever regresses.
    func testAPreposterousMultiplierCapsAtTheSequenceInsteadOfTrapping() {
        XCTAssertEqual(preferred(1450, 1e6), 1450)
        XCTAssertEqual(preferred(1450, .greatestFiniteMagnitude), 1450)
        XCTAssertEqual(preferred(1, .greatestFiniteMagnitude), 1)
    }

    // MARK: - the shared preferences file

    /// The Kotlin client reads and writes this key by hand in the same `~/.star.userprefs.json`,
    /// while this side gets it from Codable synthesis — so the property name *is* the wire
    /// format, and renaming it would silently split the two clients' preferences.
    ///
    /// Decoded rather than assigned: assigning would fire the `didSet` that saves, and the test
    /// would overwrite the real preferences file of whoever ran it.
    func testTheMultiplierUsesTheSameKeyTheKotlinClientWrites() throws {
        // exactly what the Kotlin client's Gson wrote for a 1.5 multiplier, captured from it
        let json = #"{"recentlyOpenedSequencelist":{},"skipRenderPromptAfterProcessing":false,"movingHorizonCountMultiplier":1.5}"#
        let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs.movingHorizonCountMultiplier, 1.5)

        let round = try JSONEncoder().encode(prefs)
        let text = String(decoding: round, as: UTF8.self)
        XCTAssertTrue(text.contains("movingHorizonCountMultiplier"), "encoded as: \(text)")

        let back = try JSONDecoder().decode(UserPreferences.self, from: round)
        XCTAssertEqual(back.movingHorizonCountMultiplier, 1.5)
    }

    /// An older preferences file has no such key at all, which has to read as "no preference"
    /// rather than failing the whole file to decode.
    func testPreferencesWrittenBeforeThisFeatureStillDecode() throws {
        let json = #"{"recentlyOpenedSequencelist":{}}"#
        let prefs = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))
        XCTAssertNil(prefs.movingHorizonCountMultiplier)
        XCTAssertEqual(preferred(1450, prefs.movingHorizonCountMultiplier), 12)
    }
}

/// `UserPreferences` is a value type whose every field writes the *whole* file on change, so a
/// second copy of it is a second writer: whichever copy saves last puts its own version of every
/// other field back on disk.  `ViewModel` and `ImageSequenceViewModel` each held one, synced only
/// when a sequence was opened, so a render setting changed in the render sheet (written through
/// the sequence's copy) was undone the next time anything wrote through the app's copy — opening
/// another sequence was enough, since that writes the recent-files list.
///
/// The fix is that there is now one live copy, in `UserPreferencesStore`, and both view models
/// expose `userPreferences` as a view onto it.  That is a shape rather than a behaviour, and the
/// objects that would demonstrate it cannot be stood up in a test: `ViewModel.init` reads the
/// real preferences file and prunes it (writing it back), and `ImageSequenceViewModel`'s init is
/// `async throws` over a `ConfigManager`.  So it is checked the way `SettingsWiringTests` checks
/// its own two-site convention — over the source.
@MainActor
final class UserPreferencesStoreTests: XCTestCase {

    /// gui/, derived from this file's location: gui/starTests/starTests.swift
    private static var guiDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.guiDir.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftSources() throws -> [(name: String, text: String)] {
        let dir = Self.guiDir.appendingPathComponent("star")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertGreaterThan(names.count, 20, "found only \(names.count) sources in gui/star")
        return try names.map { ($0, try source("star/\($0)")) }
    }

    /// The whole `var userPreferences: UserPreferences { ... }` declaration, accessors included.
    private func accessor(in source: String) -> String? {
        let pattern = #"var\s+userPreferences\s*:\s*UserPreferences\s*(\{[\s\S]*?\n    \})"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = source as NSString
        guard let m = re.firstMatch(in: source, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    // MARK: - one live copy

    /// A stored `userPreferences` on either view model is the hazard itself.
    func testNeitherViewModelKeepsItsOwnCopy() throws {
        for file in ["star/ViewModel.swift", "star/ImageSequenceViewModel.swift"] {
            let src = try source(file)
            XCTAssertFalse(src.contains("var userPreferences: UserPreferences ="),
                           "\(file) stores its own copy of the preferences again")

            let block = try XCTUnwrap(accessor(in: src), "\(file) has no userPreferences accessor")
            XCTAssertTrue(block.contains("UserPreferencesStore.shared.preferences"),
                          "\(file) reads preferences from somewhere other than the store: \(block)")
            XCTAssertTrue(block.contains("UserPreferencesStore.shared.preferences = newValue"),
                          "\(file) writes preferences somewhere other than the store: \(block)")
        }
    }

    /// Constructing one anywhere else makes a second value that can be written and saved.
    func testOnlyTheStoreConstructsAUserPreferences() throws {
        var built: [String] = []
        for file in try swiftSources() {
            // (?<!\w) so that applyUserPreferences() and the like do not match
            if let re = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])UserPreferences\("#) {
                let ns = file.text as NSString
                let n = re.numberOfMatches(in: file.text,
                                           range: NSRange(location: 0, length: ns.length))
                if n > 0 { built.append("\(file.name) ×\(n)") }
            }
        }
        XCTAssertEqual(built, ["UserPreferences.swift ×1"],
                       "a UserPreferences is built outside the store: \(built)")
    }

    /// The tell of the old hazard: reaching through one view model to write the preferences held
    /// by the other, which is what had to be done, field by field, to keep them in step.
    func testNoPreferenceIsWrittenThroughASecondViewModel() throws {
        // over whitespace-collapsed source, not line by line: the one that used to be here was
        // wrapped, with the receiver on one line and `.userPreferences` on the next
        let reachThrough = #"(imageSequence\?|topViewModel\?|imageSequenceViewModel)\s*\.\s*userPreferences"#
        let re = try NSRegularExpression(pattern: reachThrough)

        var doubleWrites: [String] = []
        for file in try swiftSources() {
            let flat = file.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let ns = flat as NSString
            for m in re.matches(in: flat, range: NSRange(location: 0, length: ns.length)) {
                let from = max(0, m.range.location - 20)
                let length = min(ns.length - from, m.range.length + 60)
                doubleWrites.append("\(file.name): …\(ns.substring(with: NSRange(location: from, length: length)))…")
            }
        }
        XCTAssertEqual(doubleWrites, [],
                       "preferences written through a second view model — the single store makes "
                       + "this unnecessary, and it is how the two copies drifted: \(doubleWrites)")
    }

    // MARK: - what the sequence's view model still has to do

    /// The stored property's `didSet` used to seed the video settings from the preferences on
    /// every write; the setter has to keep doing it, or changing the frame rate in the render
    /// sheet would no longer reach the settings the render actually uses.
    func testWritingPreferencesStillSeedsTheSequenceSettings() throws {
        let src = try source("star/ImageSequenceViewModel.swift")
        let block = try XCTUnwrap(accessor(in: src))
        XCTAssertTrue(block.contains("applyUserPreferences()"),
                      "the setter no longer re-applies the preferences: \(block)")

        for setting in ["detectionType", "frameRate", "codec", "encoder", "pixelFormat", "muxer"] {
            XCTAssertTrue(src.contains("self.\(setting) = \(setting)"),
                          "applyUserPreferences no longer seeds \(setting)")
        }
    }

    /// A sequence opens with its settings at their defaults, so `ViewModel` has to seed them —
    /// that was the one thing the copy-down assignment did that was not just copying.
    func testOpeningASequenceAppliesThePreferencesToIt() throws {
        let src = try source("star/ViewModel.swift")
        let opens = src.components(separatedBy: "imageSequence = imageSequenceViewModel").count - 1
        XCTAssertEqual(opens, 3, "the number of ways a sequence is opened has changed")
        XCTAssertEqual(src.components(separatedBy: "imageSequenceViewModel.applyUserPreferences()").count - 1,
                       opens, "not every sequence-open applies the preferences to the new sequence")
    }

    // MARK: - the store itself

    /// Holding the value rather than vending copies of it is the whole point.  Assigning a whole
    /// struct does not touch the file — only the individual field setters save — so this cannot
    /// disturb the preferences of whoever runs it; the original is put back regardless.
    func testTheStoreHoldsTheValueEveryReaderSees() throws {
        let store = UserPreferencesStore.shared
        let original = store.preferences
        defer { store.preferences = original }

        let json = #"{"recentlyOpenedSequencelist":{},"movingHorizonCountMultiplier":3.25}"#
        store.preferences = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))

        XCTAssertEqual(UserPreferencesStore.shared.preferences.movingHorizonCountMultiplier, 3.25)
        XCTAssertTrue(UserPreferencesStore.shared === store, "the store is not a singleton")
    }

    private final class Flag: @unchecked Sendable { var raised = false }

    /// Every view that reads a preference used to read it from an `@Observable` view model, so a
    /// change redrew it.  Now the value lives a level further away, and the redraw depends on the
    /// store being observable too — silently, since nothing fails to compile if it is not.
    func testChangingAPreferenceStillNotifiesTheViewsThatReadIt() throws {
        let store = UserPreferencesStore.shared
        let original = store.preferences
        defer { store.preferences = original }

        let fired = Flag()
        withObservationTracking {
            _ = store.preferences.movingHorizonCountMultiplier
        } onChange: {
            fired.raised = true
        }
        XCTAssertFalse(fired.raised, "notified before anything changed")

        let json = #"{"recentlyOpenedSequencelist":{},"movingHorizonCountMultiplier":4.5}"#
        store.preferences = try JSONDecoder().decode(UserPreferences.self, from: Data(json.utf8))

        XCTAssertTrue(fired.raised,
                      "a preference changed without notifying its readers — views that show one "
                      + "would no longer redraw")
    }
}

/// The panel star puts up when a sequence is re-opened reports how far the last run got by
/// counting artifacts on disk, and then hands those counts to the same bars the processing
/// modal draws.  Those bars were built to describe a *live* run — this is the second caller,
/// filling in a different pair of fields for a different meaning, and getting the mapping
/// wrong would draw a perfectly plausible bar over the wrong number.  That, and the two
/// predicates that decide which of the panel's buttons the user gets, are what these pin down.
final class SequenceProgressTests: XCTestCase {

    private func progress(frameCount: Int,
                          framesComplete: Int,
                          steps: [ProcessingStepProgress]) -> SequenceProgress
    {
        SequenceProgress(sequenceName: "a_sequence",
                         frameCount: frameCount,
                         framesComplete: framesComplete,
                         steps: steps)
    }

    private func surveyed(_ types: [OperationType],
                          frameCount: Int,
                          _ onDisk: [OperationType: Int]) -> [ProcessingStepProgress]
    {
        SequenceProgressSurvey.steps(for: types,
                                     frameCount: frameCount,
                                     framesOnDisk: onDisk)
    }

    private func step(_ steps: [ProcessingStepProgress],
                      _ type: OperationType) throws -> ProcessingStepProgress
    {
        try XCTUnwrap(steps.first { $0.type == type })
    }

    // MARK: - what a surveyed step says

    /// Frames whose artifact is on disk belong at the *finished* end of the bar, and to
    /// `alreadyDone` rather than `done`: nothing here is work a run in front of the user
    /// did, which is the whole distinction `ProcessingStepProgress` draws between the two.
    func testFramesFoundOnDiskCountAsWorkDoneBeforeThisRun() throws {
        let horizon = try step(surveyed([.horizon], frameCount: 19, [.horizon: 12]), .horizon)

        XCTAssertEqual(horizon.alreadyDone, 12)
        XCTAssertEqual(horizon.done, 0)
        XCTAssertEqual(horizon.running, 0)
        XCTAssertEqual(horizon.queued, 7)
        XCTAssertEqual(horizon.completed, 12)
        XCTAssertEqual(horizon.total, 19)
        XCTAssertEqual(horizon.doneFraction, 12.0 / 19.0, accuracy: 0.0001)
        XCTAssertEqual(horizon.runningFraction, 0)
    }

    /// The bar is over the whole sequence, whatever it finds — a step measured against only
    /// the frames it has already finished reads as complete the moment it starts.
    func testEveryStepIsMeasuredOverTheWholeSequence() {
        let steps = surveyed([.horizon, .starKeypoints, .merge],
                             frameCount: 19,
                             [.horizon: 19, .starKeypoints: 4, .merge: 0])

        XCTAssertEqual(steps.map(\.total), [19, 19, 19])
    }

    /// A step this configuration takes but that the survey found nothing for is a row at
    /// zero, not a missing row: the survey went and looked, and "none yet" is its answer.
    /// (`ProcessingSteps.visible` would drop it, which is right for a live run and wrong
    /// here — this panel does not filter.)
    func testAStepWithNothingOnDiskStillGetsARow() throws {
        let steps = surveyed([.horizon, .merge], frameCount: 19, [.horizon: 19])
        let merge = try step(steps, .merge)

        XCTAssertEqual(steps.map(\.type), [.horizon, .merge])
        XCTAssertEqual(merge.completed, 0)
        XCTAssertEqual(merge.queued, 19)
        XCTAssertEqual(merge.doneFraction, 0)
        XCTAssertTrue(merge.hasWork, "a row over a sequence with frames in it is not empty")
    }

    func testTheRowsComeOutInTheOrderTheStepsWereAskedFor() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: true,
                                          hasStaticReferenceHorizon: false,
                                          cameraWasMoving: true,
                                          allowEarthAlignment: true,
                                          usesOutliers: true)
        XCTAssertEqual(surveyed(types, frameCount: 5, [:]).map(\.type), types)
    }

    /// The counts come off the filesystem, so nothing upstream guarantees they are sane.  A
    /// count past the end of the sequence must not push `queued` negative — a negative
    /// segment width is a drawing fault, not a wrong number.
    func testACountLargerThanTheSequenceIsClampedToIt() throws {
        let merge = try step(surveyed([.merge], frameCount: 19, [.merge: 25]), .merge)

        XCTAssertEqual(merge.alreadyDone, 19)
        XCTAssertEqual(merge.queued, 0)
        XCTAssertEqual(merge.doneFraction, 1, accuracy: 0.0001)
    }

    func testANegativeCountIsTreatedAsNoneAtAll() throws {
        let merge = try step(surveyed([.merge], frameCount: 19, [.merge: -3]), .merge)

        XCTAssertEqual(merge.alreadyDone, 0)
        XCTAssertEqual(merge.queued, 19)
    }

    /// The bar has three segments and they have to cover it exactly, whatever was found.
    func testTheSegmentsAlwaysFillExactlyTheWholeBar() throws {
        for onDisk in 0...19 {
            let merge = try step(surveyed([.merge], frameCount: 19, [.merge: onDisk]), .merge)
            XCTAssertEqual(merge.doneFraction + merge.runningFraction
                             + Double(merge.queued) / Double(merge.total),
                           1, accuracy: 0.0001)
        }
    }

    /// An empty sequence has to divide by something other than zero.
    func testAnEmptySequenceDrawsAnEmptyBarRatherThanDividingByZero() throws {
        let merge = try step(surveyed([.merge], frameCount: 0, [.merge: 0]), .merge)

        XCTAssertEqual(merge.total, 0)
        XCTAssertEqual(merge.doneFraction, 0)
        XCTAssertFalse(merge.hasWork)
    }

    // MARK: - which button the user gets

    func testASequenceWithEveryFrameWrittenIsComplete() {
        let steps = surveyed([.starKeypoints, .merge], frameCount: 19,
                             [.starKeypoints: 19, .merge: 19])
        let sequence = progress(frameCount: 19, framesComplete: 19, steps: steps)

        XCTAssertTrue(sequence.isComplete)
        XCTAssertFalse(sequence.isUntouched)
    }

    func testASequenceMissingOneFrameIsNotComplete() {
        let steps = surveyed([.starKeypoints, .merge], frameCount: 19,
                             [.starKeypoints: 19, .merge: 18])
        let sequence = progress(frameCount: 19, framesComplete: 18, steps: steps)

        XCTAssertFalse(sequence.isComplete)
        XCTAssertFalse(sequence.isUntouched)
    }

    /// An empty sequence is not a finished one — offering it a video render would offer a
    /// render of nothing.
    func testAnEmptySequenceIsNotComplete() {
        XCTAssertFalse(progress(frameCount: 0, framesComplete: 0, steps: []).isComplete)
    }

    func testASequenceWithNothingOnDiskAtAllIsUntouched() {
        let steps = surveyed([.horizon, .starKeypoints, .merge], frameCount: 19, [:])
        let sequence = progress(frameCount: 19, framesComplete: 0, steps: steps)

        XCTAssertTrue(sequence.isUntouched)
        XCTAssertFalse(sequence.isComplete)
    }

    /// The distinction the "Start Processing" / "Finish Processing" wording rests on: a
    /// sequence with its keypoints detected and nothing merged has had most of the hours
    /// spent on it already, whatever the frame count says.
    func testASequenceWithAnEarlyStepDoneIsNotUntouchedEvenWithNoFramesWritten() {
        let steps = surveyed([.starKeypoints, .merge], frameCount: 19,
                             [.starKeypoints: 19, .merge: 0])
        let sequence = progress(frameCount: 19, framesComplete: 0, steps: steps)

        XCTAssertFalse(sequence.isUntouched)
        XCTAssertFalse(sequence.isComplete)
    }

    /// The panel's status line and its buttons read the same two predicates, so exactly one
    /// of the three states it describes can hold at a time.
    func testCompleteAndUntouchedAreNeverBothTrue() {
        for onDisk in 0...19 {
            let steps = surveyed([.merge], frameCount: 19, [.merge: onDisk])
            let sequence = progress(frameCount: 19, framesComplete: onDisk, steps: steps)
            XCTAssertFalse(sequence.isComplete && sequence.isUntouched,
                           "\(onDisk) frames written reads as both finished and untouched")
        }
    }
}
