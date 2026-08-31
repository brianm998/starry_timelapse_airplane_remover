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
/// ## Per-column shape rendering
///
/// The painted area is stored as a **per-column vertical extent** —
/// ``paintColumnTop`` and ``paintColumnBottom`` — rather than as an
/// accumulated `Path`.  ``paintedRegionPath`` is rebuilt from those two
/// arrays once per gesture event and is used for:
/// * The blue/yellow fill overlay.
/// * The marching-ants selection outline (one border around the whole
///   selection, not individual rings per circle).
///
/// `isPainted` hit-testing is an array lookup against the same columns.
///
/// ### Why not `Path.union`
///
/// This used to merge each brush circle into a running `Path` with
/// `Path.union` / `Path.subtracting`, on the belief that it cost O(1) per
/// stroke.  It does not.  Those operations are *lazy*: they build a
/// deferred node and cost nothing until something traverses the result,
/// which the fill and the marching-ants outline both do on every redraw.
/// The merged outline also gains segments roughly linearly with the stroke
/// count, so each new boolean op runs against a larger operand than the
/// last.  Measured at frame width, forcing a render after every stroke as
/// the canvas does, one drag event cost 0.2 ms at the first stroke and
/// 358 ms by the 400th — which is about ten seconds of ordinary painting.
/// A band paint that had become unusable by the time it crossed the frame
/// is the reason this is column-based now.
///
/// The per-column form is also what the solver already consumes: it only
/// ever reads ``bandColumnTop`` / ``bandColumnBottom`` and the known-region
/// arrays, never a `Path`.  The drawn shape now matches the region the
/// solver is actually given.
///
/// ## Live object-selection expansion
///
/// After each gesture ends, `HorizonPainterView` triggers an async
/// "object selection" pass: the bottom boundary of the painted area is
/// snapped to Canny edges and interpolated to full width, producing an
/// `expandedPath` that represents the auto-detected sky region.  While
/// this pass is running, `isExpanding` is `true`.  The ``displayPath``
/// property returns `expandedPath` when available, falling back to
/// ``paintedRegionPath``.  Strokes made while an expansion is in flight
/// move ``previewHorizonY`` directly, so the preview follows the brush
/// without waiting for the pass to finish.
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

    /// `true` when the band spans the full frame width (within a small edge margin)
    /// with no unpainted gaps between the first and last painted columns.
    var isBandComplete: Bool {
        let vw = Int(viewWidth)
        guard vw > 0 else { return false }
        let edgeMargin = max(10, vw / 50)   // ~2 % margin
        let first = bandColumnTop.firstIndex(where: { $0 != nil }) ?? Int.max
        let last  = bandColumnTop.lastIndex(where: { $0 != nil })  ?? 0
        guard first <= edgeMargin && last >= vw - 1 - edgeMargin else { return false }
        // Require continuous coverage — no unpainted columns between first and last.
        return !bandColumnTop[first...last].contains(where: { $0 == nil })
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

    // MARK: - Painted region

    /// Per-column top Y of the painted area (view coords); `nil` = unpainted.
    ///
    /// This is the raw brush coverage, as opposed to ``bandColumnTop`` which
    /// only accumulates during band selection.  Each column holds the
    /// vertical extent of the brush over that column, so a column touched by
    /// several overlapping circles keeps the outermost edges.
    @ObservationIgnored private(set) var paintColumnTop: [Int?]

    /// Per-column bottom Y of the painted area (view coords); `nil` = unpainted.
    @ObservationIgnored private(set) var paintColumnBottom: [Int?]

    /// The painted area as a `Path`, rebuilt from ``paintColumnTop`` and
    /// ``paintColumnBottom`` once per gesture event.
    ///
    /// Rebuilding costs O(view width) and does not grow with the number of
    /// strokes — see the type doc for why that matters.  Use it for fills and
    /// for the marching-ants outline when no expanded path is available;
    /// hit-test with ``isPainted(vx:vy:)`` rather than `Path.contains`.
    private(set) var paintedRegionPath: Path = Path()

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
    var displayPath: Path { expandedPath ?? paintedRegionPath }

    /// Per-column horizon Y in *view* coordinates, as last computed by the
    /// SIOX object-selection expansion.  `nil` until the first expansion
    /// completes; replaced whenever a new expansion finishes.
    ///
    /// Use this for saving — it holds the smooth SIOX-detected horizon that
    /// matches the live preview, rather than the raw top-of-brush-stroke Y
    /// that `horizonYPerColumn` would return.  Only cleared by `clear()`.
    private(set) var lastHorizonY: [Int?]? = nil

    /// Per-column bottom edge of the *displayed* sky region (view coords).
    ///
    /// Seeded from each completed expansion and then moved directly by
    /// refinement strokes, so the preview follows the brush between passes.
    /// ``expandedPath`` is this array as a polygon.
    ///
    /// Kept separate from ``lastHorizonY``, which stays as the last solver
    /// result: saving must write the horizon the solver produced, not the
    /// interim shape a half-finished gesture is showing.
    @ObservationIgnored private(set) var previewHorizonY: [Int?]? = nil

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
        self.paintColumnTop      = [Int?](repeating: nil,     count: vw)
        self.paintColumnBottom   = [Int?](repeating: nil,     count: vw)
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
    /// Reset at gesture start, updated in `apply(_:)`.
    private(set) var gestureColumnBottom: [Int]

    /// Per-column top Y (min Y) of strokes in the current gesture.
    /// Reset at gesture start, updated in `apply(_:)`.
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

        // Collect this event's circles first, then apply them in one pass, so
        // the per-column loops below touch each observable array once rather
        // than once per stroke.
        var pending: [Stroke] = []

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
                    pending.append(Stroke(
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
        pending.append(Stroke(center: center, radius: brushRadius, isErase: isErasing))
        apply(pending)
    }

    /// Signal that the current drag gesture has ended.
    ///
    /// Call this from `DragGesture.onEnded` so that the next `addStroke`
    /// (from a fresh press) does not gap-fill back to the previous position.
    func endSegment() {
        isNewSegment = true
    }

    /// Apply a batch of strokes to every per-column map, then rebuild the
    /// display paths once.
    ///
    /// Each observable array is copied into a local, mutated by the column
    /// loops, and written back a single time.  Writing through the property
    /// instead put every one of the (up to brush-diameter) element writes
    /// through the observation registrar: measured at 501 columns that was
    /// 0.42 ms per stroke against 0.042 ms for plain storage.
    private func apply(_ pending: [Stroke]) {
        guard !pending.isEmpty else { return }

        let vw = paintColumnTop.count
        let inBand = (phase == .bandSelection)

        var gTop     = gestureColumnTop
        var gBottom  = gestureColumnBottom
        var pTop     = paintColumnTop
        var pBottom  = paintColumnBottom
        var bTop     = bandColumnTop
        var bBottom  = bandColumnBottom
        var preview  = previewHorizonY
        var bounds   = lastGestureBounds
        var allStrokes = strokes

        for stroke in pending {
            allStrokes.append(stroke)

            // Accumulate gesture bounding rect.
            let sr = CGRect(x: stroke.center.x - stroke.radius,
                            y: stroke.center.y - stroke.radius,
                            width: stroke.radius * 2, height: stroke.radius * 2)
            bounds = bounds?.union(sr) ?? sr

            // Compute the actual circle Y-extent per column using the circle
            // equation: dy = sqrt(r² - dx²).  This avoids including corners
            // of the bounding box that are outside the circular brush.
            let cx = stroke.center.x
            let cy = stroke.center.y
            let r  = stroke.radius
            let r2 = r * r
            let colLo = max(0, Int(cx - r))
            let colHi = min(vw - 1, Int(cx + r))
            guard colLo <= colHi else { continue }

            for col in colLo...colHi {
                let dx = CGFloat(col) - cx
                let dy2 = r2 - dx * dx
                guard dy2 >= 0 else { continue }
                let dy = dy2.squareRoot()
                let strokeTop    = Int(cy - dy)
                let strokeBottom = Int(cy + dy)

                // Per-gesture vertical extent, read by `commitRefinementGesture`.
                if gBottom[col] < strokeBottom { gBottom[col] = strokeBottom }
                if gTop[col]    > strokeTop    { gTop[col]    = strokeTop    }

                if stroke.isErase {
                    // Clip the painted extent back from whichever side the
                    // brush overlaps.  A single interval per column cannot
                    // hold a hole, and a hole in the middle of the sky is not
                    // a horizon the solver could act on anyway.
                    if let top = pTop[col], let bottom = pBottom[col] {
                        if strokeTop <= top && strokeBottom >= bottom {
                            pTop[col] = nil
                            pBottom[col] = nil
                        } else if strokeTop <= top && strokeBottom >= top {
                            pTop[col] = strokeBottom + 1
                        } else if strokeBottom >= bottom && strokeTop <= bottom {
                            pBottom[col] = strokeTop - 1
                        }
                    }
                    // Erase marks ground: the previewed sky retreats upward.
                    if preview?[col] != nil {
                        preview![col] = min(preview![col]!, strokeTop)
                    }
                } else {
                    pTop[col]    = min(pTop[col]    ?? Int.max, strokeTop)
                    pBottom[col] = max(pBottom[col] ?? Int.min, strokeBottom)
                    // Paint marks sky: the previewed sky extends downward.
                    if preview?[col] != nil {
                        preview![col] = max(preview![col]!, strokeBottom)
                    }
                }

                // During band selection, also accumulate the cumulative band
                // boundaries (not reset per gesture).
                if inBand {
                    bTop[col]    = min(bTop[col]    ?? Int.max, strokeTop)
                    bBottom[col] = max(bBottom[col] ?? Int.min, strokeBottom)
                }
            }
        }

        strokes             = allStrokes
        gestureColumnTop    = gTop
        gestureColumnBottom = gBottom
        paintColumnTop      = pTop
        paintColumnBottom   = pBottom
        lastGestureBounds   = bounds
        if inBand {
            bandColumnTop    = bTop
            bandColumnBottom = bBottom
        }

        paintedRegionPath = HorizonPaintState.regionPath(top: pTop, bottom: pBottom)
        if let preview {
            previewHorizonY = preview
            expandedPath = HorizonPaintState.skyPath(horizonY: preview)
        }

        // Increment the generation so the in-flight expansion (if any) knows it
        // is now stale and should not overwrite the updated preview.
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
    ///
    /// ## The gesture widens the band
    ///
    /// The band is a *search* region, not a verdict, so a gesture that reaches outside it
    /// pushes it open rather than being clipped by it.  Without that the painter could not
    /// repair a badly wrong horizon at all: `loadExistingHorizon` synthesises a band of only
    /// `margin` view-points either side of the saved curve, the solver is only allowed to
    /// answer inside it, and the clamp at the end of the refinement pass pulls anything below
    /// `knownGroundCeiling` — which is pinned to the band bottom — back up.  Painting sky over
    /// a stretch of frame that the detector had called ground therefore snapped straight back
    /// to where it started, which is exactly what a user hits when the detection is wrong by
    /// more than the margin.  On a9 frame 1310 it was wrong by around 2000 px against a margin
    /// of 400.
    func commitRefinementGesture(isErasing: Bool) {
        let vw = Int(viewWidth)
        let vh = Int(viewHeight)
        for col in 0..<vw {
            guard gestureColumnBottom[col] != Int.min else { continue }
            let brushTop    = gestureColumnTop[col]
            let brushBottom = gestureColumnBottom[col]

            if isErasing {
                // Open the band above the brush first, so the retraction below is not
                // clipped back to the old search region.
                if let top = bandColumnTop[col] {
                    bandColumnTop[col] = min(top, max(0, min(vh - 1, brushTop - 1)))
                }
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
                // Open the band below the brush first, for the same reason.
                if let bottom = bandColumnBottom[col] {
                    bandColumnBottom[col] = max(bottom, max(0, min(vh - 1, brushBottom + 1)))
                }
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
        clearPaintedRegion()
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

    /// Reset all painting data for a new frame while preserving brush settings.
    ///
    /// Preserves `brushRadius` and `isErasing` so tool settings survive
    /// multi-frame startup-flow advances.  Transitions to `.computing` so the
    /// view shows a spinner while the existing horizon reference (if any) is
    /// loaded asynchronously.
    func resetForNewFrame() {
        let savedIsErasing = isErasing
        clear()              // clears everything including isErasing; brushRadius is untouched
        phase = .computing   // override bandSelection set by clear()
        // Restore *after* the phase, not before: isErasing's didSet forces the value back to
        // false while the phase is still .bandSelection, which is what clear() just set it to.
        // Assigning it first therefore lost the toggle on every frame advance.
        isErasing = savedIsErasing
    }

    /// Remove all recorded strokes and reset to the band-selection phase.
    func clear() {
        strokes.removeAll()
        clearPaintedRegion()
        expandedPath = nil
        previewHorizonY = nil
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
    /// An index into the per-column extent, so it does not depend on how many
    /// strokes have been recorded.
    func isPainted(vx: CGFloat, vy: CGFloat) -> Bool {
        let col = Int(vx)
        guard col >= 0, col < paintColumnTop.count,
              let top = paintColumnTop[col],
              let bottom = paintColumnBottom[col]
        else { return false }
        return vy >= CGFloat(top) && vy <= CGFloat(bottom)
    }

    /// Clear the painted region and the path built from it.
    private func clearPaintedRegion() {
        let vw = Int(viewWidth)
        paintColumnTop    = [Int?](repeating: nil, count: vw)
        paintColumnBottom = [Int?](repeating: nil, count: vw)
        paintedRegionPath = Path()
    }

    // MARK: - Horizon extraction

    /// Compute the per-column horizon Y in **view** coordinates by taking the
    /// top of the painted region for each column.
    ///
    /// - Parameters:
    ///   - imageWidth:  Number of columns to produce (typically the view width).
    ///   - imageHeight: Number of rows to scan (typically the view height).
    /// - Returns: Array of length `imageWidth`.  `nil` = column not painted.
    ///
    /// The caller is responsible for any further scaling to image-pixel
    /// coordinates.
    func horizonYPerColumn(imageWidth: Int, imageHeight: Int) -> [Int?] {
        var result = [Int?](repeating: nil, count: imageWidth)
        guard imageWidth > 0, imageHeight > 0, !strokes.isEmpty else { return result }

        let scaleX = viewWidth  / CGFloat(imageWidth)
        let scaleY = viewHeight / CGFloat(imageHeight)
        guard scaleY > 0 else { return result }

        let vw = paintColumnTop.count
        for ix in 0..<imageWidth {
            let col = min(vw - 1, max(0, Int((CGFloat(ix) + 0.5) * scaleX)))
            guard let top = paintColumnTop[col],
                  let bottom = paintColumnBottom[col]
            else { continue }
            // The first image row whose sample point falls at or below the top
            // of the painted region — the same row the old downward scan for
            // the first painted pixel would have stopped on.
            let iy = max(0, Int((CGFloat(top) / scaleY - 0.5).rounded(.up)))
            guard iy < imageHeight else { continue }
            let vy = (CGFloat(iy) + 0.5) * scaleY
            if vy >= CGFloat(top) && vy <= CGFloat(bottom) { result[ix] = iy }
        }
        return result
    }

    // MARK: - Object-selection expansion result

    /// Build a closed polygon spanning each column's `top...bottom` extent.
    ///
    /// Contiguous runs of defined columns become separate closed subpaths, so
    /// two dabs with a gap between them stay two shapes.  Cost is O(width) and
    /// independent of how many strokes produced the extents.
    ///
    /// Built through `CGMutablePath.addLines(between:)` rather than repeated
    /// `Path.addLine`: at frame width the latter measured ~1 µs per call, which
    /// put a full-width band at ~19 ms per gesture event on its own.
    private static func regionPath(top: [Int?], bottom: [Int?]) -> Path {
        let cg = CGMutablePath()
        var runStart: Int? = nil

        func closeRun(_ start: Int, _ end: Int) {
            // Along the top edge left to right, then back along the bottom.
            // The +1 on the bottom edge keeps the last painted row inside.
            var points: [CGPoint] = []
            points.reserveCapacity((end - start + 1) * 2)
            for col in start...end {
                points.append(CGPoint(x: CGFloat(col), y: CGFloat(top[col]!)))
            }
            for col in stride(from: end, through: start, by: -1) {
                points.append(CGPoint(x: CGFloat(col), y: CGFloat(bottom[col]! + 1)))
            }
            cg.addLines(between: points)
            cg.closeSubpath()
        }

        for col in top.indices {
            if top[col] != nil, bottom[col] != nil {
                if runStart == nil { runStart = col }
            } else if let start = runStart {
                closeRun(start, col - 1)
                runStart = nil
            }
        }
        if let start = runStart { closeRun(start, top.count - 1) }
        return Path(cg)
    }

    /// Build the sky polygon: from y = 0 down to `horizonY[column]`.
    ///
    /// Adjacent columns are connected with straight lines (a smooth
    /// interpolated horizon); contiguous runs of non-nil columns become
    /// separate closed subpaths.
    private static func skyPath(horizonY: [Int?]) -> Path {
        let cg = CGMutablePath()
        var points: [CGPoint] = []

        func closeSegment(endingAt x: CGFloat) {
            guard !points.isEmpty else { return }
            // Back up to the top of the frame to close the sky region.
            points.append(CGPoint(x: x, y: 0))
            cg.addLines(between: points)
            cg.closeSubpath()
            points.removeAll(keepingCapacity: true)
        }

        for (ix, maybeY) in horizonY.enumerated() {
            let x = CGFloat(ix)
            if let iy = maybeY {
                // Start a new sky segment at the top of the frame.
                if points.isEmpty { points.append(CGPoint(x: x, y: 0)) }
                points.append(CGPoint(x: x, y: CGFloat(iy)))
            } else {
                closeSegment(endingAt: x)
            }
        }
        closeSegment(endingAt: CGFloat(horizonY.count))
        return Path(cg)
    }

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

        previewHorizonY = filledY
        expandedPath = HorizonPaintState.skyPath(horizonY: filledY)
    }
}
