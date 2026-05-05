import SwiftUI
import StarCore
import logging

// MARK: - Canvas (lives inside ZoomableView, scales with the image)

/// Paint canvas overlay for the horizon painter.
///
/// Renders the blue fill and marching-ants selection outline at image
/// coordinates, overlaid on the frame image inside the `ZoomableView`.
/// It intentionally contains **no toolbar** — the toolbar lives in
/// `HorizonPainterToolbarView`, which is placed *outside* the
/// `ZoomableView` so it renders at screen size and is never scaled down.
///
/// ## Object-selection expansion
///
/// After each brush gesture ends, an async task loads the current frame
/// image, runs Canny edge detection, and snaps the bottom boundary of the
/// band (the full top-to-bottom extent of the brush strokes), finding the
/// bottommost strong Canny edge in that band as the detected horizon.  This is
/// robust for any brush size.  The full sky polygon from y = 0 to the detected
/// horizon is stored in `paintState.expandedPath` and shown via
/// `paintState.displayPath`.  While the expansion is running,
/// `paintState.isExpanding` is `true` and the toolbar shows a spinner.
/// A new stroke immediately updates `expandedPath` incrementally so the
/// top-of-frame extension is never lost between gestures.  A fresh Canny
/// expansion is triggered after each gesture ends to further refine the
/// bottom edge.  A new stroke that arrives while an expansion is in flight
/// previous expansion so the raw strokes are shown until the next pass
/// completes.
struct HorizonPainterView: View {

    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    /// Shared state owned by the parent (`FrameEditView`).
    let paintState: HorizonPaintState

    @State private var mousePosition:  CGPoint?               = nil
    /// The most recently launched expansion task.  Cancelled (and replaced)
    /// each time a new gesture ends so that only the latest stroke set's
    /// computation is ever in flight.
    @State private var expansionTask: Task<Void, Never>? = nil

    var body: some View {
        ZStack {
            paintCanvas
                .allowsHitTesting(true)
                .contentShape(Rectangle())
                .gesture(paintGesture)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        if mousePosition == nil { NSCursor.hide() }
                        mousePosition = location
                    case .ended:
                        mousePosition = nil
                        NSCursor.unhide()
                    }
                }
        }
        .onDisappear {
            NSCursor.unhide()   // safety net
        }
        // Brush-adjustment shortcuts stay here so they fire whenever the
        // mouse is over the canvas.
        .background(brushKeyboardHandlers)
    }

    // MARK: - Paint canvas

    private var paintCanvas: some View {
        ZStack {
            paintMaskCanvas
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                Canvas { context, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    drawMarchingAnts(&context, size: size, time: t)
                    drawCursor(&context)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var paintMaskCanvas: some View {
        Canvas { context, _ in
            let fillColor: Color = paintState.phase == .refinement
                ? .blue.opacity(0.35)
                : .yellow.opacity(0.35)
            context.fill(
                paintState.displayPath,
                with: .color(fillColor)
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: - Marching ants

    private func drawMarchingAnts(
        _ context: inout GraphicsContext,
        size: CGSize,
        time: Double
    ) {
        let path = paintState.displayPath
        guard !path.isEmpty else { return }

        // ZoomableView's scaleEffect is applied at the layer level after the
        // Canvas has rendered, so it is NOT reflected in the Canvas CGContext
        // CTM.  Compensate by dividing nominal screen sizes by currentZoomScale
        // so the stroke and dash render at constant screen size regardless of
        // zoom level.
        let zoomScale = max(0.01, viewModel.currentZoomScale)
        let lw       = 1.5  / zoomScale
        let dashLen  = 4.0  / zoomScale
        // Phase advances at 20 screen-points/sec — constant speed regardless of zoom.
        let phase = CGFloat(time * 20.0 / Double(zoomScale))
            .truncatingRemainder(dividingBy: dashLen * 2)

        context.stroke(path, with: .color(.white),
                       style: StrokeStyle(lineWidth: lw,
                                          dash: [dashLen, dashLen],
                                          dashPhase: phase))
        context.stroke(path, with: .color(.black),
                       style: StrokeStyle(lineWidth: lw,
                                          dash: [dashLen, dashLen],
                                          dashPhase: phase + dashLen))
    }

    // MARK: - Cursor

    private func drawCursor(_ context: inout GraphicsContext) {
        guard let pos = mousePosition else { return }

        // ZoomableView's scaleEffect is applied at the layer level after the
        // Canvas has rendered, so it is NOT reflected in the Canvas CGContext
        // CTM.  Compensate by dividing nominal screen sizes by currentZoomScale
        // so the brush ring, dot, and label all render at constant screen size
        // regardless of zoom level.
        let zoomScale = max(0.01, viewModel.currentZoomScale)

        // Color and label depend on the current interaction phase.
        let color: Color
        let label: String
        switch paintState.phase {
        case .bandSelection:
            color = .yellow
            label = "Select an area that contains the horizon"
        case .computing:
            color = .gray
            label = "Calculating..."
        case .refinement:
            if paintState.isExpanding {
                color = .gray
                label = "Calculating..."
            } else if paintState.isErasing {
                color = .red
                label = "select ground"
            } else {
                color = .green
                label = "select sky"
            }
        }

        // Draw the brush ring.
        let r    = paintState.brushRadius
        let rect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)
        let ring = Path(ellipseIn: rect)
        context.stroke(ring, with: .color(.black.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 3.0 / zoomScale))
        context.stroke(ring, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.5 / zoomScale))
        let dotR = 2.0 / zoomScale
        let dot  = Path(ellipseIn: CGRect(x: pos.x - dotR, y: pos.y - dotR,
                                          width: dotR * 2, height: dotR * 2))
        context.fill(dot, with: .color(color))

        // Draw label to the upper-right of the cursor ring.
        let labelOffset: CGFloat = 6.0 / zoomScale
        let labelOrigin = CGPoint(x: pos.x + r + labelOffset, y: pos.y - r - labelOffset)
        let text = Text(label)
            .font(.system(size: 11.0 / zoomScale, weight: .medium))
            .foregroundColor(color)
        context.draw(text, at: labelOrigin, anchor: .bottomLeading)
    }

    // MARK: - Gesture

    private var paintGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { gesture in
                guard paintState.phase != .computing else { return }
                paintState.addStroke(at: gesture.location)
                mousePosition = gesture.location
            }
            .onEnded { gesture in
                guard paintState.phase != .computing else {
                    paintState.endSegment()
                    return
                }
                paintState.addStroke(at: gesture.location)
                paintState.endSegment()

                let frameView = viewModel.currentFrameView
                let ps        = paintState

                switch paintState.phase {
                case .bandSelection:
                    // Check if the band now spans the full frame width.
                    if paintState.isBandComplete {
                        paintState.setPhase(.computing)
                        expansionTask?.cancel()
                        expansionTask = Task {
                            await triggerBandComputation(paintState: ps,
                                                         frameView: frameView)
                        }
                    }
                    // No SIOX triggered per-gesture during band selection.

                case .computing:
                    break   // Ignore gestures while computing.

                case .refinement:
                    let wasErasing = paintState.isErasing
                    // Commit the gesture to the known-region map SYNCHRONOUSLY here,
                    // before the Task is queued.  If we deferred this to inside the
                    // Task, a second gesture's addStroke (which also runs on the main
                    // actor) could reset gestureColumnBottom/Top before the Task even
                    // starts, causing commitRefinementGesture to read the wrong data.
                    paintState.commitRefinementGesture(isErasing: wasErasing)
                    // Do not cancel a prior refinement task — it targets different
                    // columns and its result should still be applied.  Both tasks
                    // run concurrently; each merges only its own affected columns
                    // into lastHorizonY, so they compose safely.
                    Task {
                        await triggerObjectSelection(paintState: ps,
                                                     frameView: frameView,
                                                     isErasingGesture: wasErasing)
                    }
                }
            }
    }

    // MARK: - Keyboard shortcuts (brush only)

    @ViewBuilder
    private var brushKeyboardHandlers: some View {
        Button("") { paintState.shrinkBrush() }
            .keyboardShortcut("[", modifiers: [])
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

        Button("") { paintState.growBrush() }
            .keyboardShortcut("]", modifiers: [])
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

        Button("") {
            if paintState.phase == .refinement { paintState.isErasing.toggle() }
        }
        .keyboardShortcut("-", modifiers: [])
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

        Button("") {
            if paintState.phase == .refinement { paintState.isErasing = false }
        }
        .keyboardShortcut("p", modifiers: [])
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

        Button("") {
            if paintState.phase == .refinement { paintState.isErasing = true }
        }
        .keyboardShortcut("e", modifiers: [])
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

        Button("") { paintState.clear() }
            .keyboardShortcut("r", modifiers: [])
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

// MARK: - Band computation (initial horizon detection)

/// Runs the initial horizon detection using `CombinedHorizonDetector` within
/// the user's painted band.  Areas above the band top are always sky; areas
/// below the band bottom are always earth.  The detector runs only on the band
/// region.  Edge columns that were not painted are filled automatically.
///
/// Called once when the band first spans the full frame width.  After the
/// computation completes, transitions the paint state to `.refinement`.
@MainActor
private func triggerBandComputation(
    paintState: HorizonPaintState,
    frameView: FrameViewModel
) async {
    let bandTop    = paintState.bandColumnTop
    let bandBottom = paintState.bandColumnBottom
    let vw = Int(paintState.viewWidth)
    let vh = Int(paintState.viewHeight)

    guard let frame = frameView.frame else {
        paintState.setPhase(.bandSelection)
        return
    }

    paintState.beginExpanding()

    let horizon: [Int?]
    do {
        horizon = try await frame.computeCombinedHorizonInBand(
            topBoundaryY:    bandTop,
            bottomBoundaryY: bandBottom,
            viewWidth:       vw,
            viewHeight:      vh
        )
    } catch {
        Log.w("HorizonPainterView: band computation failed: \(error)")
        paintState.setPhase(.bandSelection)
        paintState.endExpanding()
        return
    }

    paintState.transitionToRefinement(horizon: horizon)
    paintState.endExpanding()
}

// MARK: - Object-selection expansion (refinement)

/// Re-runs horizon detection during the **refinement** phase using the
/// edge-aware Random Walker, constrained to the remaining unknown gap (area #2).
///
/// Before detecting, the gesture's affected columns are permanently
/// committed to the known-region map via `commitRefinementGesture`:
///   - **Paint** → marks brushed pixels as known sky, pushing
///     `knownSkyFloor` downward and shrinking the unknown gap.
///   - **Erase** → marks brushed pixels as known ground, pushing
///     `knownGroundCeiling` upward.
///
/// The Random Walker solves a diffusion problem across the ENTIRE gap using
/// the updated sky/ground seeds.  Because the solution is global, changing
/// seeds in brushed columns propagates and re-shapes the horizon across ALL
/// columns in area #2 — not just the directly brushed ones.  Brushed regions
/// are locked as seeds and will never be reclassified.
@MainActor
private func triggerObjectSelection(
    paintState: HorizonPaintState,
    frameView: FrameViewModel,
    isErasingGesture: Bool = false
) async {
    let vw = Int(paintState.viewWidth)
    let vh = Int(paintState.viewHeight)

    let bandTop = paintState.bandColumnTop
    let bandBot = paintState.bandColumnBottom

    // Gesture was already committed to the known-region map synchronously in
    // paintGesture.onEnded, before this Task was queued.  Snapshot the current
    // state (which includes that commit and any prior ones).
    let skyFloor   = paintState.knownSkyFloor
    let gndCeiling = paintState.knownGroundCeiling

    guard let frame = frameView.frame else { return }

    paintState.beginExpanding()

    // Determine the column range to re-solve: gesture footprint + 20 px margin
    // on each side.  Columns outside this window keep their value from
    // lastHorizonY unchanged, so a brush stroke never corrupts the horizon
    // more than 20 pixels beyond where it actually touched.
    let margin = 20
    let affectedMin: Int
    let affectedMax: Int
    if let bounds = paintState.lastGestureBounds {
        affectedMin = max(0,      Int(bounds.minX) - margin)
        affectedMax = min(vw - 1, Int(bounds.maxX) + margin)
    } else {
        affectedMin = 0
        affectedMax = vw - 1
    }

    // Build band/lock arrays with nil outside the affected range.
    // The C++ Random Walker solver only processes columns with non-nil band values,
    // so the diffusion stays local to the brush region.
    var localBandTop    = [Int?](repeating: nil, count: vw)
    var localBandBot    = [Int?](repeating: nil, count: vw)
    var localSkyFloor   = [Int?](repeating: nil, count: vw)
    var localGndCeiling = [Int?](repeating: nil, count: vw)
    for col in affectedMin...affectedMax {
        localBandTop[col]    = bandTop[col]
        localBandBot[col]    = bandBot[col]
        localSkyFloor[col]   = skyFloor[col]
        localGndCeiling[col] = gndCeiling[col]
    }

    // Smooth the locked-region boundary at the brush X-edges.
    //
    // For a circular brush, the per-column locked-sky floor is `cy` at the
    // leftmost touched column (only one pixel of the circle), so the value
    // jumps discontinuously between the column just outside the footprint
    // (skyFloor = bandTop, often dozens of rows higher) and the leftmost
    // brush column.  The Random Walker's Gauss-Seidel diffusion produces
    // a noisy probability profile in those step columns, and the
    // scan-up-from-ground in RandomWalkerHorizon.cpp catches a stray
    // prob >= 0.5 crossing *below* the real horizon — visible as a small
    // downward dip right at each X-edge of the brush.
    //
    // Taper the locked-region boundary into half the margin so the solver
    // sees a smooth ramp instead of a step.  Only the side that the
    // gesture actually moved (sky floor for paint, ground ceiling for
    // erase) needs to be tapered.  The taper never relaxes a constraint:
    // on the sky side it pushes the floor down; on the ground side it
    // pushes the ceiling up.
    let taperWidth = max(1, margin / 2)
    if let bounds = paintState.lastGestureBounds {
        let brushLeft  = max(affectedMin, Int(bounds.minX))
        let brushRight = min(affectedMax, Int(bounds.maxX))
        if brushLeft <= brushRight {
            if isErasingGesture {
                taperLockedBoundary(&localGndCeiling,
                                    brushLeft:  brushLeft,
                                    brushRight: brushRight,
                                    outerLeft:  affectedMin,
                                    outerRight: affectedMax,
                                    taperWidth: taperWidth,
                                    pushDirection: .up)
            } else {
                taperLockedBoundary(&localSkyFloor,
                                    brushLeft:  brushLeft,
                                    brushRight: brushRight,
                                    outerLeft:  affectedMin,
                                    outerRight: affectedMax,
                                    taperWidth: taperWidth,
                                    pushDirection: .down)
            }
        }
    }

    let snappedHorizon: [Int?]?
    do {
        snappedHorizon = try await frame.computeRandomWalkerHorizon(
            topBoundaryY:        localBandTop,
            bottomBoundaryY:     localBandBot,
            viewWidth:           vw,
            viewHeight:          vh,
            knownSkyFloorY:      localSkyFloor,
            knownGroundCeilingY: localGndCeiling
        )
    } catch {
        Log.w("HorizonPainterView: object selection failed: \(error)")
        paintState.endExpanding()
        return
    }

    guard !Task.isCancelled,
          let local = snappedHorizon
    else {
        paintState.endExpanding()
        return
    }

    // Merge: replace the affected column range with fresh RW values;
    // columns outside the range keep their value from lastHorizonY.
    // This prevents a local brush stroke from corrupting the horizon in
    // distant areas that were already detected correctly.
    var merged: [Int?] = paintState.lastHorizonY ?? [Int?](repeating: nil, count: vw)
    for col in affectedMin...affectedMax {
        if let y = local[col] { merged[col] = y }
    }

    // Clamp every column so explicit paint/erase gestures are never
    // overridden by the computation.
    // • Paint (sky): knownSkyFloor[col] is the lowest sky row the user has
    //   explicitly brushed — the horizon must be at or below that row.
    // • Erase (ground): knownGroundCeiling[col] is the highest ground row —
    //   the horizon must be above that row.
    for col in 0..<vw {
        guard let y = merged[col] else { continue }
        var clampedY = y
        if let sf = skyFloor[col]   { clampedY = max(clampedY, sf) }
        if let gc = gndCeiling[col] { clampedY = min(clampedY, gc - 1) }
        merged[col] = max(0, clampedY)
    }

    paintState.applyExpandedHorizonMask(merged)
    paintState.endExpanding()
}

// MARK: - Locked-region taper helper

/// Direction the taper pushes a locked-region boundary toward the brush
/// edge value.  Sky uses `.down` (floor moves to a larger Y); ground uses
/// `.up` (ceiling moves to a smaller Y).
private enum BoundaryPushDirection { case up, down }

/// Linearly interpolate a locked-region boundary from `outer` toward the
/// brush edge value across `taperWidth` columns on each side of the brush
/// footprint.  Never relaxes the existing constraint: when pushing
/// `.down`, the new value is `max(prior, tapered)`; when pushing `.up`,
/// it is `min(prior, tapered)`.
///
/// Required to fix a small downward dip in the detected horizon at the
/// left/right edges of a refinement brush stroke — see the comment at the
/// call site in `triggerObjectSelection`.
private func taperLockedBoundary(_ array: inout [Int?],
                                 brushLeft:  Int,
                                 brushRight: Int,
                                 outerLeft:  Int,
                                 outerRight: Int,
                                 taperWidth: Int,
                                 pushDirection: BoundaryPushDirection) {
    func combine(_ prior: Int, _ tapered: Int) -> Int {
        switch pushDirection {
        case .down: return max(prior, tapered)
        case .up:   return min(prior, tapered)
        }
    }

    if let edge = array[brushLeft] {
        let extendStart = max(outerLeft, brushLeft - taperWidth)
        let span = brushLeft - extendStart
        if span > 0 {
            for col in extendStart..<brushLeft {
                guard let prior = array[col] else { continue }
                let t = Double(col - extendStart) / Double(span)
                let tapered = Int((1.0 - t) * Double(prior) + t * Double(edge))
                array[col] = combine(prior, tapered)
            }
        }
    }
    if let edge = array[brushRight] {
        let extendEnd = min(outerRight, brushRight + taperWidth)
        let span = extendEnd - brushRight
        if span > 0 {
            for col in (brushRight + 1)...extendEnd {
                guard let prior = array[col] else { continue }
                let t = Double(extendEnd - col) / Double(span)
                let tapered = Int((1.0 - t) * Double(prior) + t * Double(edge))
                array[col] = combine(prior, tapered)
            }
        }
    }
}

// MARK: - Toolbar (lives outside ZoomableView, always screen-sized)

/// Toolbar for the horizon painter.
///
/// Placed **outside** the `ZoomableView` in `FrameEditView` so it is
/// rendered at full screen size regardless of how far the image is zoomed.
/// It shares a `HorizonPaintState` reference with `HorizonPainterView`.
struct HorizonPainterToolbarView: View {

    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    /// Shared state owned by the parent (`FrameEditView`).
    let paintState: HorizonPaintState

    @State private var isSaving              = false
    @State private var saveError: String?    = nil
    @State private var cancelledExplicitly   = false
    @State private var savedAlready          = false
    @State private var tunedParams           = HorizonTunedParameters()
    @State private var applyToNearbyFrames   = true

    var body: some View {
        bottomToolbar
            .task { await loadTunedParams() }
            .onDisappear {
                // Auto-save when dismissed via toggle (not Cancel / Escape).
                // Only save during refinement — band selection has no horizon.
                // In startup mode the user must use Continue/Cancel explicitly.
                guard viewModel.horizonPainterMode == .normal,
                      paintState.phase == .refinement,
                      !savedAlready,
                      !cancelledExplicitly,
                      !isSaving
                else { return }

                let frame = viewModel.currentFrameView.frame
                // Prefer the SIOX-detected horizon from the live preview;
                // fall back to raw brush strokes if no expansion has run yet.
                let rawY: [Int?]
                if let refined = paintState.lastHorizonY {
                    rawY = refined
                } else {
                    rawY = paintState.horizonYPerColumn(
                        imageWidth:  Int(paintState.viewWidth),
                        imageHeight: Int(paintState.viewHeight)
                    )
                }
                let w = Int(paintState.viewWidth)
                let h = Int(paintState.viewHeight)
                Task {
                    guard let frame else { return }
                    try? await frame.saveHorizonReferenceMask(
                        paintedYPerColumn: rawY,
                        viewWidth:  w,
                        viewHeight: h
                    )
                }
            }
            .background(actionKeyboardHandlers)
    }

    // MARK: - Toolbar layout (phase-aware)

    private var bottomToolbar: some View {
        HStack(spacing: 16) {
            switch paintState.phase {
            case .bandSelection:
                bandSelectionToolbar
            case .computing:
                computingToolbar
            case .refinement:
                refinementToolbar
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
                .opacity(0.92)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: Band-selection toolbar

    @ViewBuilder
    private var bandSelectionToolbar: some View {
        startupProgressLabel

        brushSizeControls

        Divider().frame(height: 24)

        let pct = Int(paintState.bandCoverage * 100)
        Label("Paint across the horizon — \(pct)%",
              systemImage: "mountain.2")
            .foregroundColor(.yellow)
            .font(.caption)

        Spacer()

        Button {
            paintState.clear()
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.bordered)
        .disabled(!paintState.hasStrokes)
        .help("Reset and start over (R)")

        Button("Cancel") { handleCancel() }
        .help("Discard and close (Esc)")
    }

    // MARK: Computing toolbar

    @ViewBuilder
    private var computingToolbar: some View {
        Spacer()
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Computing horizon…")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        Spacer()
        Button("Cancel") { handleCancel() }
        .help("Discard and close (Esc)")
    }

    // MARK: Refinement toolbar

    @ViewBuilder
    private var refinementToolbar: some View {
        startupProgressLabel

        brushSizeControls

        Divider().frame(height: 24)

        paintEraseButtons

        Button {
            paintState.clear()
        } label: {
            Label("Reset", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.bordered)
        .help("Reset and start over from band selection (R)")

        Divider().frame(height: 24)

        maxDownwardExtensionControl

        Divider().frame(height: 24)

        Toggle("Apply to nearby frames", isOn: $applyToNearbyFrames)
            .toggleStyle(.switch)
            .font(.caption)
            .help("When on, saving this reference will trigger reprocessing of nearby interpolated frames")

        Spacer()

        if paintState.isExpanding {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Detecting…")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .transition(.opacity)
        }

        if let err = saveError {
            Text(err)
                .foregroundColor(.red)
                .font(.caption)
                .lineLimit(1)
                .help(err)
        }

        Button {
            Task { await saveHorizonReference() }

            // XXX HERE if in startup mode for either static of moving video,
            // take the user to the next place after saving the horizon reference frame.
        } label: {
            if isSaving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                }
            } else if viewModel.horizonPainterMode == .startup {
                let indices = viewModel.horizonPainterStartupFrameIndices
                let pos     = viewModel.horizonPainterStartupFramePosition
                let hasMore = !indices.isEmpty && pos + 1 < indices.count
                Label(hasMore ? "Next" : "Continue", systemImage: "checkmark.circle.fill")
            } else {
                Label("Save Reference Horizon", systemImage: "checkmark.circle.fill")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(paintState.lastHorizonY == nil || isSaving || paintState.isExpanding)
        .help(viewModel.horizonPainterMode == .startup
              ? "Save horizon and continue (Return)"
              : "Save the horizon reference (Return)")

        Button("Cancel") { handleCancel() }
        .help("Discard and close (Esc)")
    }

    // MARK: - Paint / Erase buttons

    /// Two-button toggle: the active mode button uses .borderedProminent (blue),
    /// the inactive one uses .bordered.  Ternary can't unify the two concrete
    /// ButtonStyle types, so if/else is used to give each branch a single type.
    @ViewBuilder
    private var paintEraseButtons: some View {
        if paintState.isErasing {
            Button { paintState.isErasing = false } label: {
                Label("Sky", systemImage: "paintbrush.fill")
            }
            .buttonStyle(.bordered)
            .help("Paint sky — adds to the selection (P)")

            Button { paintState.isErasing = true } label: {
                Label("Ground", systemImage: "eraser.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("Erase sky — removes from the selection (E)")
        } else {
            Button { paintState.isErasing = false } label: {
                Label("Sky", systemImage: "paintbrush.fill")
            }
            .buttonStyle(.borderedProminent)
            .help("Paint sky — adds to the selection (P)")

            Button { paintState.isErasing = true } label: {
                Label("Ground", systemImage: "eraser.fill")
            }
            .buttonStyle(.bordered)
            .help("Erase sky — removes from the selection (E)")
        }
    }

    // MARK: - Brush size controls

    @ViewBuilder
    private var brushSizeControls: some View {
        HStack(spacing: 4) {
            Button {
                paintState.shrinkBrush()
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.bordered)
            .help("Shrink brush ([)")

            Text("\(Int(paintState.brushRadius))px")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 45, alignment: .center)

            Button {
                paintState.growBrush()
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.bordered)
            .help("Grow brush (])")
        }
    }

    // MARK: - Max downward extension control

    @ViewBuilder
    private var maxDownwardExtensionControl: some View {
        HStack(spacing: 4) {
            Button {
                adjustMaxDownwardExtension(by: -10)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.bordered)
            .help("Decrease max downward extension by 10px")
            .disabled(tunedParams.maxDownwardExtension <= 0)

            Text("↓\(tunedParams.maxDownwardExtension)px")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(minWidth: 52, alignment: .center)
                .help("Max pixels the refined horizon may go below the merged horizon baseline (0 = disabled)")

            Button {
                adjustMaxDownwardExtension(by: 10)
            } label: {
                Image(systemName: "plus.circle")
            }
            .buttonStyle(.bordered)
            .help("Increase max downward extension by 10px")
        }
    }

    private func loadTunedParams() async {
        guard let frame = viewModel.currentFrameView.frame else { return }
        tunedParams = await frame.loadTunedHorizonParameters()
    }

    private func adjustMaxDownwardExtension(by delta: Int) {
        tunedParams.maxDownwardExtension = max(0, tunedParams.maxDownwardExtension + delta)
        Task {
            guard let frame = viewModel.currentFrameView.frame else { return }
            try? await frame.saveTunedHorizonParameters(tunedParams)
        }
    }

    // MARK: - Startup progress label

    /// Shows "1 / N" when in startup mode with multiple frames to paint.
    @ViewBuilder
    private var startupProgressLabel: some View {
        let indices = viewModel.horizonPainterStartupFrameIndices
        if viewModel.horizonPainterMode == .startup, indices.count > 1 {
            let pos = viewModel.horizonPainterStartupFramePosition + 1
            Text("\(pos) / \(indices.count)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
            Divider().frame(height: 24)
        }
    }

    // MARK: - Cancel helper

    private func handleCancel() {
        cancelledExplicitly = true
        if viewModel.horizonPainterMode == .startup {
            viewModel.returnToMovingViewFromHorizonPainter()
        } else {
            viewModel.isShowingHorizonPainter = false
        }
    }

    // MARK: - Keyboard shortcuts (save / cancel actions)

    @ViewBuilder
    private var actionKeyboardHandlers: some View {
        Button("") { handleCancel() }
        .keyboardShortcut(.escape, modifiers: [])
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

        Button("") {
            if paintState.phase == .refinement { Task { await saveHorizonReference() } }
        }
        .keyboardShortcut(.return, modifiers: [])
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    // MARK: - Save

    @MainActor
    private func saveHorizonReference() async {
        // Allow saving when the horizon was auto-detected from band strokes OR
        // was loaded from an existing reference (lastHorizonY set, strokes empty).
        guard paintState.hasStrokes || paintState.lastHorizonY != nil else { return }
        guard let frame = viewModel.currentFrameView.frame else {
            saveError = "No frame available"
            return
        }
        isSaving  = true
        saveError = nil

        // Prefer the SIOX-detected per-column horizon from the live preview
        // (matches what the user sees).  Fall back to scanning raw brush strokes
        // only when no expansion has run yet.
        let rawY: [Int?]
        if let refined = paintState.lastHorizonY {
            rawY = refined
        } else {
            rawY = paintState.horizonYPerColumn(
                imageWidth:  Int(paintState.viewWidth),
                imageHeight: Int(paintState.viewHeight)
            )
        }

        do {
            try await frame.saveHorizonReferenceMask(
                paintedYPerColumn: rawY,
                viewWidth:  Int(paintState.viewWidth),
                viewHeight: Int(paintState.viewHeight)
            )
            Log.i("HorizonPainterToolbarView: saved reference mask for frame \(frame.frameIndex)")
            savedAlready = true
            isSaving     = false
            if viewModel.horizonPainterMode == .startup {
                let indices = viewModel.horizonPainterStartupFrameIndices
                let pos     = viewModel.horizonPainterStartupFramePosition
                // indices is empty for a static single-frame flow (SelectHorizonView).
                // For moving multi-frame flows it holds the evenly-spaced frame list.
                let hasMoreFrames = !indices.isEmpty && pos + 1 < indices.count
                if hasMoreFrames {
                    // Moving sequence: more horizons to paint — advance to next frame.
                    // Refresh the overlay for the frame we just painted before moving on.
                    viewModel.currentFrameView.existingImages.insert(.userHorizon)
                    viewModel.currentFrameView.refreshHorizonOverlay()
                    viewModel.currentFrameView.refreshFrameHorizonOverlay()
                    savedAlready = false  // reset so the next frame's save is treated as new
                    viewModel.advanceToNextStartupHorizonFrame()
                } else {
                    // Static single frame OR final frame of moving sequence: all done.
                    viewModel.currentFrameView.existingImages.insert(.userHorizon)
                    viewModel.currentFrameView.refreshHorizonOverlay()
                    viewModel.currentFrameView.refreshFrameHorizonOverlay()
                    viewModel.continueToRemovalFromHorizonPainter()
                }
            } else {
                // Refresh both overlays so the change is immediately visible
                // in the filmstrip thumbnail and the frame edit view.
                // Also mark userHorizon as existing so the left-panel "Show:"
                // picker reveals it without requiring a full reload.
                viewModel.currentFrameView.existingImages.insert(.userHorizon)
                viewModel.currentFrameView.refreshHorizonOverlay()
                viewModel.currentFrameView.refreshFrameHorizonOverlay()
                if applyToNearbyFrames {
                    viewModel.recordReferenceHorizonUpdated(frameIndex: viewModel.currentFrameView.frameIndex)
                    viewModel.reprocessHorizonsForUpdatedReferences()
                }
                viewModel.isShowingHorizonPainter = false
            }
        } catch {
            Log.w("HorizonPainterToolbarView: save failed: \(error)")
            isSaving  = false
            saveError = error.localizedDescription
        }
    }
}
