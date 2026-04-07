import Foundation
import SwiftUI

/// Phase of the horizon painter workflow.
///
/// The user starts by painting a yellow **band** that brackets the horizon,
/// then the system computes the precise horizon within that band, and
/// finally the user can **refine** the result with paint/erase gestures.
enum HorizonPainterPhase: Sendable {
    /// Painting the yellow horizon band (no SIOX yet).
    case bandSelection
    /// SIOX is running within the band to detect the horizon.
    case computing
    /// Horizon detected — user can paint/erase to refine.
    case refinement
}


/// Mutable state for a single horizon-painting session.
///
/// Stores all brush strokes as circles so that the painting can be
/// re-composed on demand.  Works in *view* coordinates (the size the
/// frame is rendered at on screen); callers scale to image pixel
/// coordinates at save-time via ``horizonYPerColumn(imageWidth:imageHeight:)``
/// or the live-preview expansion via ``applyExpandedHorizonMask(_:)``.
///
/// ## Merged-shape rendering
///
/// In addition to the raw stroke list, the state maintains a
/// ``unifiedPaintPath`` that is updated incrementally (O(1) per stroke)
/// using `Path.union` and `Path.subtracting`.  This single merged `Path`
/// is used for:
/// * The blue fill overlay (no need for per-circle iteration).
/// * The marching-ants selection outline (one border around the whole
///   selection, not individual rings per circle).
/// * `isPainted` hit-testing via `Path.contains` (much faster than the
///   previous per-stroke linear scan).
///
/// ## Live object-selection expansion
///
/// After each gesture ends, `HorizonPainterView` triggers an async
/// "object selection" pass: the bottom boundary of the painted area is
/// snapped to Canny edges and interpolated to full width, producing an
/// `expandedPath` that represents the auto-detected sky region.  While
/// this pass is running, `isExpanding` is `true`.  The ``displayPath``
/// property returns `expandedPath` when available, falling back to
/// `unifiedPaintPath`.  Adding a new stroke invalidates `expandedPath`
/// so the raw strokes are shown until the next expansion finishes.
///
/// ## Gap filling
///
/// When the user paints quickly and the cursor jumps between gesture
/// events, `addStroke` inserts intermediate strokes along the straight
/// line between the previous and current position so the painted path is
/// continuous.  The connecting shape matches the user's description:
/// a rectangle of width = brush diameter bridging the two circles.
@MainActor @Observable
final class HorizonPaintState {

    // MARK: - Phase

    /// Current phase of the three-step workflow: band → compute → refine.
    private(set) var phase: HorizonPainterPhase = .bandSelection

    /// Transition to the given phase.  Used by the view layer to move to
    /// `.computing` once the band is complete.
    func setPhase(_ newPhase: HorizonPainterPhase) { phase = newPhase }

    // MARK: - Band boundaries

    /// Per-column top Y of the horizon band (view coords).
    /// Accumulated across all band-selection gestures; `nil` = column not yet painted.
    private(set) var bandColumnTop: [Int?]

    /// Per-column bottom Y of the horizon band (view coords).
    private(set) var bandColumnBottom: [Int?]

    // MARK: - Known-region boundaries (SIOX three-region model)

    /// Per-column lowest Y known to be sky (view coords).
    /// Initialised from `bandColumnTop` when entering refinement.
    /// Painting extends this downward (enlarges the known-sky region).
    /// SIOX only classifies pixels between `knownSkyFloor` and
    /// `knownGroundCeiling` — everything outside is locked.
    private(set) var knownSkyFloor: [Int?]

    /// Per-column highest Y known to be ground (view coords).
    /// Initialised from `bandColumnBottom` when entering refinement.
    /// Erasing extends this upward (enlarges the known-ground region).
    private(set) var knownGroundCeiling: [Int?]

    /// `true` when the band spans the full frame width (within a small edge margin).
    var isBandComplete: Bool {
        let vw = Int(viewWidth)
        guard vw > 0 else { return false }
        let edgeMargin = max(10, vw / 50)   // ~2 % margin
        let first = bandColumnTop.firstIndex(where: { $0 != nil }) ?? Int.max
        let last  = bandColumnTop.lastIndex(where: { $0 != nil })  ?? 0
        return first <= edgeMargin && last >= vw - 1 - edgeMargin
    }

    /// Fraction of columns covered by the band (0.0 to 1.0).
    var bandCoverage: Double {
        Double(bandColumnTop.compactMap { $0 }.count) / Double(max(1, Int(viewWidth)))
    }

    // MARK: - Brush settings

    /// Radius of the circular brush in view-coordinate points.
    var brushRadius: CGFloat = 250

    static let minBrushRadius: CGFloat = 5
    static let maxBrushRadius: CGFloat = 500

    /// When `true` the brush removes sky from the selection instead of adding it.
    /// Forced to `false` during band selection (the band is always additive).
    var isErasing: Bool = false {
        didSet {
            if phase == .bandSelection && isErasing { isErasing = false }
        }
    }

    // MARK: - Stroke list

    struct Stroke: Sendable {
        let center: CGPoint
        let radius: CGFloat
        let isErase: Bool
    }

    private(set) var strokes: [Stroke] = []

    var hasStrokes: Bool { !strokes.isEmpty }

    // MARK: - Unified paint path

    /// The current painted area as a single merged `Path`.
    ///
    /// Each add stroke is `union`-ed in; each erase stroke is `subtract`-ed.
    /// The incremental update is O(1) per stroke: one CGPath boolean
    /// operation, regardless of how many strokes have been recorded.
    ///
    /// Use this path for fills, hit-testing, and the marching-ants outline
    /// when no expanded path is available.
    private(set) var unifiedPaintPath: Path = Path()

    // MARK: - Object-selection expanded path

    /// Result of the last async object-selection expansion, or `nil` if not
    /// yet computed or invalidated by a new stroke.
    ///
    /// When non-nil, this shows the full auto-detected sky region (horizon
    /// snapped to Canny edges, filled from y = 0 to the horizon per column).
    private(set) var expandedPath: Path? = nil

    /// Number of async object-selection expansion tasks currently in flight.
    ///
    /// Using a counter instead of a Bool means that when two concurrent tasks
    /// exist (e.g. a new gesture arrived while the previous expansion was still
    /// computing), the spinner stays visible until the *last* task finishes —
    /// rather than disappearing prematurely when the stale task exits.
    private(set) var expandingTaskCount: Int = 0

    /// `true` while any async object-selection expansion is running.
    var isExpanding: Bool { expandingTaskCount > 0 }

    /// Call at the **start** of an async expansion task.
    func beginExpanding() { expandingTaskCount += 1 }

    /// Call at the **end** of an async expansion task (success *or* failure).
    func endExpanding()   { expandingTaskCount = max(0, expandingTaskCount - 1) }

    /// Monotonically increasing counter.  Each new stroke increments this so
    /// that a stale in-flight expansion can detect it was superseded and skip
    /// updating `expandedPath`.
    private(set) var expansionGeneration: Int = 0

    /// The path to display: expanded (object-selection result) when available,
    /// raw painted strokes otherwise.
    var displayPath: Path { expandedPath ?? unifiedPaintPath }

    /// Per-column horizon Y in *view* coordinates, as last computed by the
    /// SIOX object-selection expansion.  `nil` until the first expansion
    /// completes; replaced whenever a new expansion finishes.
    ///
    /// Use this for saving — it holds the smooth SIOX-detected horizon that
    /// matches the live preview, rather than the raw top-of-brush-stroke Y
    /// that `horizonYPerColumn` would return.  Only cleared by `clear()`.
    private(set) var lastHorizonY: [Int?]? = nil

    // MARK: - View dimensions

    /// Width of the frame view (view-coordinate points, not image pixels).
    let viewWidth: CGFloat
    /// Height of the frame view (view-coordinate points, not image pixels).
    let viewHeight: CGFloat

    init(viewWidth: CGFloat, viewHeight: CGFloat) {
        self.viewWidth  = viewWidth
        self.viewHeight = viewHeight
        let vw = Int(viewWidth)
        self.bandColumnTop       = [Int?](repeating: nil,     count: vw)
        self.bandColumnBottom    = [Int?](repeating: nil,     count: vw)
        self.knownSkyFloor       = [Int?](repeating: nil,     count: vw)
        self.knownGroundCeiling  = [Int?](repeating: nil,     count: vw)
        self.gestureColumnBottom = [Int](repeating: Int.min,  count: vw)
        self.gestureColumnTop    = [Int](repeating: Int.max,  count: vw)
    }

    // MARK: - Brush resize ([ and ] keys)

    func shrinkBrush() {
        brushRadius = max(HorizonPaintState.minBrushRadius, brushRadius - 10)
    }

    func growBrush() {
        brushRadius = min(HorizonPaintState.maxBrushRadius, brushRadius + 10)
    }

    // MARK: - Paint / erase

    /// `true` when the next `addStroke` call is the first point of a new
    /// gesture (i.e. the user just pressed down again after lifting).
    /// Gap-filling is suppressed at segment boundaries so that lifting and
    /// clicking somewhere else does not draw a line between the two spots.
    private var isNewSegment: Bool = true

    /// Bounding rect of all strokes in the **current** drag gesture (view
    /// coordinates).  Reset at the start of each new gesture; accumulates
    /// every stroke circle added during the gesture.  Captured in `onEnded`
    /// to determine the horizontal region affected by this gesture so that
    /// only nearby columns are updated by the SIOX horizon pass.
    private(set) var lastGestureBounds: CGRect? = nil

    /// Per-column bottom Y (max Y) of strokes in the current gesture.
    /// Reset at gesture start, updated in `appendStroke`.
    private(set) var gestureColumnBottom: [Int]

    /// Per-column top Y (min Y) of strokes in the current gesture.
    /// Reset at gesture start, updated in `appendStroke`.
    private(set) var gestureColumnTop: [Int]

    /// Record a brush stroke at the given view-coordinate point.
    ///
    /// If this is a continuation of the **current gesture** (not a new press)
    /// and the previous stroke is farther away than half the brush radius,
    /// intermediate strokes are inserted along the straight line to fill the
    /// gap.  This produces a continuous band rather than two isolated circles.
    /// Gap-filling is **never** applied across a gesture boundary.
    func addStroke(at center: CGPoint) {
        // Reset gesture bounds and per-column extent at the start of a new
        // segment so each gesture tracks only its own affected region.
        if isNewSegment {
            lastGestureBounds = nil
            let vw = Int(viewWidth)
            gestureColumnBottom = [Int](repeating: Int.min, count: vw)
            gestureColumnTop    = [Int](repeating: Int.max, count: vw)
        }
        // Gap-fill only within the same continuous gesture segment.
        if !isNewSegment, let prev = strokes.last, prev.isErase == isErasing {
            let dx   = center.x - prev.center.x
            let dy   = center.y - prev.center.y
            let dist = (dx * dx + dy * dy).squareRoot()
            // Step size ≤ half the brush radius so circles overlap.
            let step = max(brushRadius * 0.5, 1)
            if dist > step {
                let steps = Int((dist / step).rounded(.up))
                for i in 1..<steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    appendStroke(Stroke(
                        center: CGPoint(
                            x: prev.center.x + t * dx,
                            y: prev.center.y + t * dy
                        ),
                        radius: brushRadius,
                        isErase: isErasing
                    ))
                }
            }
        }
        isNewSegment = false
        appendStroke(Stroke(center: center, radius: brushRadius, isErase: isErasing))
    }

    /// Signal that the current drag gesture has ended.
    ///
    /// Call this from `DragGesture.onEnded` so that the next `addStroke`
    /// (from a fresh press) does not gap-fill back to the previous position.
    func endSegment() {
        isNewSegment = true
    }

    /// Append a single stroke and update `unifiedPaintPath` and `expandedPath` incrementally.
    private func appendStroke(_ stroke: Stroke) {
        strokes.append(stroke)

        // Accumulate gesture bounding rect.
        let sr = CGRect(x: stroke.center.x - stroke.radius,
                        y: stroke.center.y - stroke.radius,
                        width: stroke.radius * 2, height: stroke.radius * 2)
        lastGestureBounds = lastGestureBounds?.union(sr) ?? sr

        // Track per-column vertical extent of this gesture's strokes.
        // Used by `commitRefinementGesture` to update known-region
        // boundaries (knownSkyFloor / knownGroundCeiling).
        //
        // Compute the actual circle Y-extent per column using the circle
        // equation: dy = sqrt(r² - dx²).  This avoids including corners
        // of the bounding box that are outside the circular brush.
        let cx = stroke.center.x
        let cy = stroke.center.y
        let r  = stroke.radius
        let r2 = r * r
        let colLo = max(0, Int(cx - r))
        let colHi = min(gestureColumnBottom.count - 1, Int(cx + r))
        if colLo <= colHi {
            for col in colLo...colHi {
                let dx = CGFloat(col) - cx
                let dy2 = r2 - dx * dx
                guard dy2 >= 0 else { continue }
                let dy = dy2.squareRoot()
                let strokeTop    = Int(cy - dy)
                let strokeBottom = Int(cy + dy)
                if gestureColumnBottom[col] < strokeBottom { gestureColumnBottom[col] = strokeBottom }
                if gestureColumnTop[col]    > strokeTop    { gestureColumnTop[col]    = strokeTop    }
            }

            // During band selection, also accumulate the cumulative band
            // boundaries (not reset per gesture).
            if phase == .bandSelection {
                for col in colLo...colHi {
                    let dx = CGFloat(col) - cx
                    let dy2 = r2 - dx * dx
                    guard dy2 >= 0 else { continue }
                    let dy = dy2.squareRoot()
                    let strokeTop    = Int(cy - dy)
                    let strokeBottom = Int(cy + dy)
                    bandColumnTop[col]    = min(bandColumnTop[col]    ?? Int.max, strokeTop)
                    bandColumnBottom[col] = max(bandColumnBottom[col] ?? Int.min, strokeBottom)
                }
            }
        }

        let circle = Path(ellipseIn: CGRect(
            x: stroke.center.x - stroke.radius,
            y: stroke.center.y - stroke.radius,
            width:  stroke.radius * 2,
            height: stroke.radius * 2
        ))
        if stroke.isErase {
            unifiedPaintPath = unifiedPaintPath.subtracting(circle, eoFill: false)
            // Keep expandedPath live by subtracting the erased region immediately.
            // This preserves the top-of-frame extension while showing the erase instantly.
            if let existing = expandedPath {
                expandedPath = existing.subtracting(circle, eoFill: false)
            }
        } else {
            unifiedPaintPath = unifiedPaintPath.union(circle, eoFill: false)
            // Keep expandedPath live by adding the new stroke immediately.
            // The top-of-frame extension (and any prior Canny snap) is preserved.
            // A fresh expansion will refine it again once the gesture ends.
            if let existing = expandedPath {
                expandedPath = existing.union(circle, eoFill: false)
            }
        }
        // Increment the generation so the in-flight expansion (if any) knows it
        // is now stale and should not overwrite the updated expandedPath.
        expansionGeneration += 1
    }

    /// Update known-region boundaries from a refinement gesture.
    ///
    /// **Paint** gestures label brushed pixels as known-background (sky):
    /// `knownSkyFloor[col]` is pushed downward to the brush bottom, enlarging
    /// the known-sky region and shrinking the unknown gap that SIOX will scan.
    ///
    /// **Erase** gestures label brushed pixels as known-foreground (ground):
    /// `knownGroundCeiling[col]` is pushed upward to the brush top.
    ///
    /// SIOX never reclassifies known regions — only the remaining unknown gap
    /// between `knownSkyFloor` and `knownGroundCeiling` is subject to the
    /// colour-distance scan.
    func commitRefinementGesture(isErasing: Bool) {
        let vw = Int(viewWidth)
        for col in 0..<vw {
            guard gestureColumnBottom[col] != Int.min else { continue }
            let brushTop    = gestureColumnTop[col]
            let brushBottom = gestureColumnBottom[col]
            if isErasing {
                // Erase → mark brushed rows as known ground: ceiling moves up.
                if let current = knownGroundCeiling[col] {
                    knownGroundCeiling[col] = min(current, brushTop)
                } else {
                    knownGroundCeiling[col] = brushTop
                }
                // Retract sky floor if it now overlaps the newly marked ground.
                // This lets erasing fully undo a prior paint-sky gesture.
                if let sf = knownSkyFloor[col], sf >= brushTop {
                    let retracted = brushTop - 1
                    knownSkyFloor[col] = max(retracted, bandColumnTop[col] ?? 0)
                }
            } else {
                // Paint → mark brushed rows as known sky: floor moves down.
                if let current = knownSkyFloor[col] {
                    knownSkyFloor[col] = max(current, brushBottom)
                } else {
                    knownSkyFloor[col] = brushBottom
                }
                // Retract ground ceiling if it now overlaps the newly marked sky.
                // This lets painting fully undo a prior erase gesture.
                if let gc = knownGroundCeiling[col], gc <= brushBottom {
                    let retracted = brushBottom + 1
                    knownGroundCeiling[col] = min(retracted, bandColumnBottom[col] ?? Int(viewHeight))
                }
            }
        }
    }

    /// Skip band-selection and computation entirely by loading a pre-existing
    /// per-column horizon (e.g. from a saved reference mask on disk).
    ///
    /// Synthesises band boundaries with `margin` view-points above and below
    /// the loaded horizon so the user can still adjust the result with brushes.
    /// Jumps straight to `.refinement` phase — the marching-ants outline and
    /// blue sky fill are shown immediately from the saved values.
    func loadExistingHorizon(_ horizonY: [Int?], margin: Int) {
        let vw = Int(viewWidth)
        let vh = Int(viewHeight)
        var top    = [Int?](repeating: nil, count: vw)
        var bottom = [Int?](repeating: nil, count: vw)
        for col in 0..<vw {
            if let y = horizonY[col] {
                top[col]    = max(0,      y - margin)
                bottom[col] = min(vh - 1, y + margin)
            }
        }
        bandColumnTop    = HorizonPaintState.fillEdgeNils(top)
        bandColumnBottom = HorizonPaintState.fillEdgeNils(bottom)
        transitionToRefinement(horizon: horizonY)
    }

    /// Transition from `.computing` to `.refinement` after the initial
    /// band-mode detection completes.
    ///
    /// Clears the band strokes/paths (they are no longer needed for display)
    /// and applies the detection result as the new sky mask.  The band
    /// boundaries are preserved so refinement stays constrained within them.
    func transitionToRefinement(horizon: [Int?]) {
        strokes.removeAll()
        unifiedPaintPath = Path()
        applyExpandedHorizonMask(horizon)
        phase = .refinement
        isNewSegment = true
        let vw = Int(viewWidth)
        gestureColumnBottom = [Int](repeating: Int.min, count: vw)
        gestureColumnTop    = [Int](repeating: Int.max, count: vw)
        // Initialize known regions from band boundaries:
        // above band = known sky, below band = known ground, band = unknown.
        knownSkyFloor      = bandColumnTop
        knownGroundCeiling = bandColumnBottom
    }

    /// Remove all recorded strokes and reset to the band-selection phase.
    func clear() {
        strokes.removeAll()
        unifiedPaintPath = Path()
        expandedPath = nil
        lastHorizonY = nil
        lastGestureBounds = nil
        phase = .bandSelection
        isErasing = false
        let vw = Int(viewWidth)
        bandColumnTop       = [Int?](repeating: nil,     count: vw)
        bandColumnBottom    = [Int?](repeating: nil,     count: vw)
        knownSkyFloor       = [Int?](repeating: nil,     count: vw)
        knownGroundCeiling  = [Int?](repeating: nil,     count: vw)
        gestureColumnBottom = [Int](repeating: Int.min,  count: vw)
        gestureColumnTop    = [Int](repeating: Int.max,  count: vw)
        expansionGeneration += 1
        isNewSegment = true
    }

    // MARK: - Hit-testing

    /// Returns `true` if view-coordinate point `(vx, vy)` lies inside the
    /// painted (sky) region.
    ///
    /// Uses `Path.contains` on `unifiedPaintPath` — significantly faster
    /// than the previous O(strokes) linear scan.
    func isPainted(vx: CGFloat, vy: CGFloat) -> Bool {
        unifiedPaintPath.contains(CGPoint(x: vx, y: vy))
    }

    // MARK: - Horizon extraction

    /// Compute the per-column horizon Y in **view** coordinates by
    /// scanning downward through the painted region for each column.
    ///
    /// - Parameters:
    ///   - imageWidth:  Number of columns to produce (typically the view width).
    ///   - imageHeight: Number of rows to scan (typically the view height).
    /// - Returns: Array of length `imageWidth`.  `nil` = column not painted.
    ///
    /// The caller is responsible for any further scaling to image-pixel
    /// coordinates.
    func horizonYPerColumn(imageWidth: Int, imageHeight: Int) -> [Int?] {
        guard !strokes.isEmpty else {
            return [Int?](repeating: nil, count: imageWidth)
        }

        let scaleX = viewWidth  / CGFloat(imageWidth)
        let scaleY = viewHeight / CGFloat(imageHeight)

        var result = [Int?](repeating: nil, count: imageWidth)
        for ix in 0..<imageWidth {
            let vx = (CGFloat(ix) + 0.5) * scaleX
            for iy in 0..<imageHeight {
                let vy = (CGFloat(iy) + 0.5) * scaleY
                if isPainted(vx: vx, vy: vy) {
                    result[ix] = iy
                    break
                }
            }
        }
        return result
    }

    // MARK: - Object-selection expansion result

    /// Fill leading/trailing nil runs with nearest-neighbour extrapolation.
    private static func fillEdgeNils(_ arr: [Int?]) -> [Int?] {
        var result = arr
        if let first = result.first(where: { $0 != nil }) {
            for i in result.indices { if result[i] != nil { break }; result[i] = first }
        }
        if let last = result.last(where: { $0 != nil }) {
            for i in result.indices.reversed() { if result[i] != nil { break }; result[i] = last }
        }
        return result
    }

    /// Replace `expandedPath` with the full sky mask derived from per-column
    /// horizon Y values returned by `FrameAirplaneRemover.computeCombinedHorizonInBand`.
    ///
    /// Edge columns with nil Y values are filled by nearest-neighbour
    /// extrapolation so the horizon always spans the full frame width.
    /// Each column fills from y = 0 down to `horizonY[column]`, representing
    /// the sky above the detected horizon.
    ///
    /// - Parameter horizonY: Per-column horizon Y in image/view pixel coordinates
    ///   (length should equal the image width ≈ `viewWidth`).
    func applyExpandedHorizonMask(_ horizonY: [Int?]) {
        let width = horizonY.count
        guard width > 0 else { return }

        // Edge-extrapolate so the horizon spans the full frame width before
        // both storing the values and building the display polygon.
        let filledY = HorizonPaintState.fillEdgeNils(horizonY)

        // Persist the per-column values so the save function can use the
        // smooth detected horizon instead of re-scanning raw brush strokes.
        lastHorizonY = filledY

        // Build a polygon whose top edge is y = 0 and whose bottom edge
        // follows the per-column horizon Y values.  Adjacent columns are
        // connected with straight lines (smooth interpolated horizon).
        // Contiguous runs of non-nil columns become separate closed subpaths.
        var poly = Path()
        var segmentOpen = false

        for (ix, maybeY) in filledY.enumerated() {
            let x = CGFloat(ix)
            if let iy = maybeY {
                let y = CGFloat(iy)
                if !segmentOpen {
                    // Start a new sky segment: move to top-left of this column,
                    // then draw down to the horizon.
                    poly.move(to: CGPoint(x: x, y: 0))
                    poly.addLine(to: CGPoint(x: x, y: y))
                    segmentOpen = true
                } else {
                    // Continue along the horizon bottom edge.
                    poly.addLine(to: CGPoint(x: x, y: y))
                }
            } else {
                if segmentOpen {
                    // Close segment: draw back up to the top of the frame.
                    poly.addLine(to: CGPoint(x: x, y: 0))
                    poly.closeSubpath()
                    segmentOpen = false
                }
            }
        }

        if segmentOpen {
            // Close the final open segment at the right edge.
            poly.addLine(to: CGPoint(x: CGFloat(width), y: 0))
            poly.closeSubpath()
        }

        expandedPath = poly
    }
}
