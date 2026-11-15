import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


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

    /// Each tool but none has its own before-and-after diagram in the help.
    func testEveryToolHasHelpArt() {
        var seen = Set<StarArt>()
        for tool in ToolType.allCases {
            if tool == .none {
                XCTAssertNil(tool.helpArt)
            } else {
                let art = tool.helpArt
                XCTAssertNotNil(art, "\(tool) has no help art")
                if let art { XCTAssertTrue(seen.insert(art).inserted, "\(tool) shares its diagram") }
            }
        }
        XCTAssertEqual(seen.count, 8)
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

    /// Refusing the *assignment* is not enough: the phase also moves under a value already
    /// held.  A frame advance restores the toggle while the phase is `.computing`, and the
    /// phase then settles on `.bandSelection` for any frame with no saved horizon to load.
    ///
    /// Left on, the band paints nothing: every stroke takes the erase path, which has no
    /// painted region to clip, so the canvas stays empty while the coverage percentage
    /// climbs.  The band-selection toolbar has no sky/ground buttons either, so the only
    /// way back out was Reset — which is exactly the report this pins down.
    func testReturningToBandSelectionTurnsErasingBackOff() {
        let paint = state()
        paint.setPhase(.refinement)
        paint.isErasing = true

        paint.setPhase(.bandSelection)

        XCTAssertFalse(paint.isErasing, "the band is always additive")
    }

    /// The whole path the startup flow actually takes: erase on the frame just finished,
    /// advance, and the new frame turns out to need a band painted from scratch.
    func testAFrameAdvanceIntoBandSelectionDoesNotLeaveTheEraserOn() {
        let paint = state()
        paint.setPhase(.refinement)
        paint.isErasing = true

        paint.resetForNewFrame()
        XCTAssertTrue(paint.isErasing, "still carried while the load is in flight")

        paint.setPhase(.bandSelection)   // no saved horizon for the new frame
        XCTAssertFalse(paint.isErasing)

        paint.brushRadius = 20
        paint.addStroke(at: CGPoint(x: 100, y: 50))
        XCTAssertTrue(paint.isPainted(vx: 100, vy: 50),
                      "the first stroke on the new frame has to paint")
    }

    /// The other half of the advance: a frame that *does* have a saved horizon lands in
    /// refinement, where the toggle is a tool setting and has to survive.
    func testAFrameAdvanceIntoRefinementKeepsTheEraser() {
        let paint = state()
        paint.setPhase(.refinement)
        paint.isErasing = true

        paint.resetForNewFrame()
        paint.loadExistingHorizon([Int?](repeating: 50, count: 200), margin: 20)

        XCTAssertEqual(paint.phase, .refinement)
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

    // MARK: - a gesture outside the band opens it

    /// **The band is a search region, not a cap.**  `loadExistingHorizon` synthesises a band of
    /// `margin` points either side of the saved curve, and the refinement pass will not let the
    /// horizon leave it — so before this, a horizon that was wrong by more than `margin` could not
    /// be corrected at all.  Painting sky well below the band bottom left `knownGroundCeiling`
    /// pinned to that bottom, and the clamp at the end of the pass pulled the answer straight back
    /// up to it.  That is the "it snaps back to where it was" report from a9 frame 1310, where the
    /// detection was wrong by roughly 2000 px against a margin of 400.
    func testPaintingSkyBelowTheBandOpensTheBandDownward() {
        let paint = state(width: 200, height: 400)
        paint.loadExistingHorizon([Int?](repeating: 100, count: 200), margin: 20)
        XCTAssertEqual(paint.bandColumnBottom[100], 120, "precondition: the band ends at 120")

        // paint sky down to row 300 — far below the band
        paint.brushRadius = 10
        paint.addStroke(at: CGPoint(x: 100, y: 290))
        paint.commitRefinementGesture(isErasing: false)

        guard let bottom = paint.bandColumnBottom[100],
              let floor = paint.knownSkyFloor[100],
              let ceiling = paint.knownGroundCeiling[100]
        else { return XCTFail("the column should be fully defined") }

        XCTAssertGreaterThanOrEqual(floor, 300, "the brushed rows are known sky")
        XCTAssertGreaterThan(bottom, floor, "the band must have room below the new floor")
        XCTAssertGreaterThan(ceiling, floor,
                             "the ground ceiling must retract past the newly painted sky")
    }

    /// The same in the other direction: erasing above the band top opens it upward, so a horizon
    /// detected far too low can be dragged up.
    func testErasingAboveTheBandOpensTheBandUpward() {
        let paint = state(width: 200, height: 400)
        paint.loadExistingHorizon([Int?](repeating: 300, count: 200), margin: 20)
        XCTAssertEqual(paint.bandColumnTop[100], 280, "precondition: the band starts at 280")

        paint.isErasing = true
        paint.brushRadius = 10
        paint.addStroke(at: CGPoint(x: 100, y: 110))
        paint.commitRefinementGesture(isErasing: true)

        guard let top = paint.bandColumnTop[100],
              let ceiling = paint.knownGroundCeiling[100],
              let floor = paint.knownSkyFloor[100]
        else { return XCTFail("the column should be fully defined") }

        XCTAssertLessThanOrEqual(ceiling, 100, "the brushed rows are known ground")
        XCTAssertLessThan(top, ceiling, "the band must have room above the new ceiling")
        XCTAssertLessThan(floor, ceiling,
                          "the sky floor must retract past the newly erased ground")
    }

    /// The band only opens where the brush actually went.
    func testOpeningTheBandDoesNotDisturbUntouchedColumns() {
        let paint = state(width: 200, height: 400)
        paint.loadExistingHorizon([Int?](repeating: 100, count: 200), margin: 20)

        paint.brushRadius = 5
        paint.addStroke(at: CGPoint(x: 150, y: 290))
        paint.commitRefinementGesture(isErasing: false)

        XCTAssertEqual(paint.bandColumnBottom[10], 120, "column 10 keeps the synthesised band")
        XCTAssertGreaterThan(paint.bandColumnBottom[150] ?? 0, 290)
    }

    /// The widened band still stops at the frame edge.
    func testTheOpenedBandStaysInsideTheFrame() {
        let paint = state(width: 200, height: 100)
        paint.loadExistingHorizon([Int?](repeating: 50, count: 200), margin: 10)

        paint.brushRadius = 30
        paint.addStroke(at: CGPoint(x: 100, y: 95))
        paint.commitRefinementGesture(isErasing: false)

        XCTAssertEqual(paint.bandColumnBottom[100], 99, "clamped to the last row")

        let up = state(width: 200, height: 100)
        up.loadExistingHorizon([Int?](repeating: 50, count: 200), margin: 10)
        up.isErasing = true
        up.brushRadius = 30
        up.addStroke(at: CGPoint(x: 100, y: 5))
        up.commitRefinementGesture(isErasing: true)

        XCTAssertEqual(up.bandColumnTop[100], 0, "clamped to the first row")
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

    // MARK: - the session counter

    /// One paint state serves every frame of the startup flow, so an async detection pass
    /// that is still running when the frame advances comes back holding a live reference to
    /// the *next* frame's state.  Writing its horizon there showed the previous frame's
    /// selection over the new frame, left the new band barely able to draw over it (a
    /// stroke only moves `previewHorizonY` where it already has a value, and `displayPath`
    /// prefers the expanded path to the raw strokes), and seeded the `lastHorizonY` that a
    /// save writes.  The session counter is how the pass knows not to.
    func testAFrameAdvanceRetiresTheSession() {
        let paint = state()
        let session = paint.sessionGeneration
        XCTAssertTrue(paint.isCurrentSession(session))

        paint.resetForNewFrame()

        XCTAssertFalse(paint.isCurrentSession(session),
                       "work started for the previous frame is no longer current")
        XCTAssertTrue(paint.isCurrentSession(paint.sessionGeneration))
    }

    func testResetRetiresTheSession() {
        let paint = state()
        let session = paint.sessionGeneration
        paint.clear()
        XCTAssertFalse(paint.isCurrentSession(session))
    }

    /// Unlike the expansion generation, painting must *not* retire the session: several
    /// refinement passes legitimately run at once, each merging only its own columns, and
    /// every one of them has to be allowed to land.
    func testPaintingDoesNotRetireTheSession() {
        let paint = state()
        paint.setPhase(.refinement)
        let session = paint.sessionGeneration

        paint.brushRadius = 20
        paint.addStroke(at: CGPoint(x: 50, y: 50))
        paint.endSegment()
        paint.addStroke(at: CGPoint(x: 150, y: 50))

        XCTAssertTrue(paint.isCurrentSession(session),
                      "a stroke supersedes an expansion, not the whole session")
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
