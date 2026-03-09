import Foundation
import SwiftUI

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

    // MARK: - Brush settings

    /// Radius of the circular brush in view-coordinate points.
    var brushRadius: CGFloat = 250

    static let minBrushRadius: CGFloat = 5
    static let maxBrushRadius: CGFloat = 500

    /// When `true` the brush removes sky from the selection instead of adding it.
    var isErasing: Bool = false

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

    /// Record a brush stroke at the given view-coordinate point.
    ///
    /// If this is a continuation of the **current gesture** (not a new press)
    /// and the previous stroke is farther away than half the brush radius,
    /// intermediate strokes are inserted along the straight line to fill the
    /// gap.  This produces a continuous band rather than two isolated circles.
    /// Gap-filling is **never** applied across a gesture boundary.
    func addStroke(at center: CGPoint) {
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

    /// Remove all recorded strokes and reset the unified path.
    func clear() {
        strokes.removeAll()
        unifiedPaintPath = Path()
        expandedPath = nil
        lastHorizonY = nil
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

    /// Replace `expandedPath` with the full sky mask derived from per-column
    /// horizon Y values returned by `FrameAirplaneRemover.computeLiveObjectSelection`.
    ///
    /// Each column fills from y = 0 down to `horizonY[column]`, representing
    /// the sky above the detected horizon.  Columns with a `nil` Y value are
    /// not included (the user has not yet painted there).
    ///
    /// - Parameter horizonY: Per-column horizon Y in image/view pixel coordinates
    ///   (length should equal the image width ≈ `viewWidth`).
    func applyExpandedHorizonMask(_ horizonY: [Int?]) {
        let width = horizonY.count
        guard width > 0 else { return }

        // Persist the raw per-column values so the save function can use the
        // smooth SIOX-detected horizon instead of re-scanning raw brush strokes.
        lastHorizonY = horizonY

        // Build a polygon whose top edge is y = 0 and whose bottom edge
        // follows the per-column horizon Y values.  Adjacent columns are
        // connected with straight lines (smooth interpolated horizon).
        // Contiguous runs of non-nil columns become separate closed subpaths.
        var poly = Path()
        var segmentOpen = false

        for (ix, maybeY) in horizonY.enumerated() {
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
