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
    @Environment(\.displayScale) private var displayScale

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

        // Compute screen-stable stroke widths by reading the current CTM scale.
        // The canvas lives inside ZoomableView's scaleEffect, so the CTM encodes
        // the zoom factor.  `ctmScale` is in device pixels per canvas unit.
        // `cpu` (canvas units per screen point) = displayScale / ctmScale.
        // Multiplying nominal screen sizes by `cpu` keeps strokes visually constant.
        var ctmScale: CGFloat = displayScale
        context.withCGContext { cgCtx in
            ctmScale = hypot(cgCtx.ctm.a, cgCtx.ctm.c)
        }
        let cpu      = max(0.001, displayScale / ctmScale)
        let lw       = 1.5  * cpu
        let dashLen  = 4.0  * cpu
        // Phase advances at 20 screen-points/sec — constant speed regardless of zoom.
        let phase = CGFloat(time * 20.0 * Double(cpu))
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

        // Same CTM-based screen-stable scaling as drawMarchingAnts.
        var ctmScale: CGFloat = displayScale
        context.withCGContext { cgCtx in
            ctmScale = hypot(cgCtx.ctm.a, cgCtx.ctm.c)
        }
        let cpu = max(0.001, displayScale / ctmScale)

        let r    = paintState.brushRadius
        let rect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)
        let ring = Path(ellipseIn: rect)
        let color: Color = paintState.isErasing ? .red : .white
        context.stroke(ring, with: .color(.black.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 3.0 * cpu))
        context.stroke(ring, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.5 * cpu))
        let dotR = 2.0 * cpu
        let dot  = Path(ellipseIn: CGRect(x: pos.x - dotR, y: pos.y - dotR,
                                          width: dotR * 2, height: dotR * 2))
        context.fill(dot, with: .color(color))
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
                    paintState.commitGestureConstraints(isErasing: wasErasing)
                    expansionTask?.cancel()
                    expansionTask = Task {
                        await triggerObjectSelection(paintState: ps,
                                                     frameView: frameView)
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
    }
}

// MARK: - Band computation (initial horizon detection)

/// Runs the initial SIOX horizon detection using the painted band as the
/// search window.  Areas above the band are treated as known sky, areas
/// below as known ground.
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

    let horizon: [Int?]?
    do {
        horizon = try await frame.computeLiveObjectSelection(
            topBoundaryY:    bandTop,
            bottomBoundaryY: bandBottom,
            viewWidth:       vw,
            viewHeight:      vh,
            bandMode:        true
        )
    } catch {
        Log.w("HorizonPainterView: band computation failed: \(error)")
        paintState.setPhase(.bandSelection)
        paintState.endExpanding()
        return
    }

    guard let h = horizon else {
        paintState.setPhase(.bandSelection)
        paintState.endExpanding()
        return
    }

    paintState.transitionToRefinement(horizon: h)
    paintState.endExpanding()
}

// MARK: - Object-selection expansion (refinement)

/// Runs the live object-selection pass during the **refinement** phase:
/// re-runs band-mode SIOX using the original band boundaries (not brush
/// stroke boundaries), merges locally, enforces user constraints, and
/// clamps to the band.
///
/// Using band boundaries ensures that **all** columns within the band are
/// processed by SIOX — preventing vertical unselected gaps.  The sky and
/// ground centroids are computed from the full regions above and below the
/// band, giving the most reliable colour references.  User refinements
/// (paint / erase) are honoured through the per-column constraint mechanism
/// rather than by altering the SIOX scan direction.
///
/// Called on the `@MainActor` after each refinement gesture ends.
@MainActor
private func triggerObjectSelection(
    paintState: HorizonPaintState,
    frameView: FrameViewModel
) async {
    let vw         = Int(paintState.viewWidth)
    let vh         = Int(paintState.viewHeight)
    let generation = paintState.expansionGeneration

    // Capture gesture bounds, previous horizon, user constraints, and band
    // boundaries for local-effect merging + constraint enforcement + clamping.
    let gestureBounds   = paintState.lastGestureBounds
    let previousHorizon = paintState.lastHorizonY   // [Int?]? in view coords
    let constraints     = paintState.userConstraints // [HorizonConstraint?]? in view coords
    let bandTop         = paintState.bandColumnTop   // [Int?] in view coords
    let bandBot         = paintState.bandColumnBottom

    guard let frame = frameView.frame else { return }

    paintState.beginExpanding()

    // Build reverse-scan flags from user constraints.
    //
    // Paint constraints → reverse scan (bottom-up).  Instead of scanning
    // from the band top down and potentially misclassifying lighter sky as
    // terrain, the reverse scan starts from the band bottom (clear ground)
    // and scans upward to find where sky begins.  This produces a natural
    // terrain-following contour rather than a flat line at the brush bottom.
    //
    // Erase constraints → normal top-down scan; the result is clamped to
    // the erase ceiling afterward.
    var reverseScan: [Bool]? = nil
    if let constraints = constraints {
        var rs = [Bool](repeating: false, count: vw)
        var hasAny = false
        for ix in 0..<vw {
            if case .paintFloor = constraints[ix] {
                rs[ix] = true
                hasAny = true
            }
        }
        if hasAny { reverseScan = rs }
    }

    // SIOX horizon detection using band boundaries as the search window.
    // Band mode gives per-column-group sky centroids (capturing lateral
    // colour variation like dark edges vs bright milky way) and scans
    // all columns — preventing vertical gaps.
    let snappedHorizon: [Int?]?
    do {
        snappedHorizon = try await frame.computeLiveObjectSelection(
            topBoundaryY:       bandTop,
            bottomBoundaryY:    bandBot,
            viewWidth:          vw,
            viewHeight:         vh,
            bandMode:           true,
            reverseScanColumns: reverseScan
        )
    } catch {
        Log.w("HorizonPainterView: object selection failed: \(error)")
        paintState.endExpanding()
        return
    }

    // Apply result — only if not cancelled and no newer stroke arrived.
    guard !Task.isCancelled,
          paintState.expansionGeneration == generation,
          let horizon = snappedHorizon
    else {
        paintState.endExpanding()
        return
    }

    // Merge locally: only update columns near the gesture; keep the
    // previous SIOX-detected horizon everywhere else.
    //
    // This prevents painting/erasing in one area from recalculating the
    // horizon across the entire frame width.  A margin (±200 view px)
    // around the gesture bounds provides a smooth blend zone.
    let mergedHorizon: [Int?]
    if let bounds = gestureBounds, let prev = previousHorizon, prev.count == vw {
        let margin   = 200
        let effectLo = max(0,      Int(bounds.minX) - margin)
        let effectHi = min(vw - 1, Int(bounds.maxX) + margin)
        var merged   = prev
        for ix in 0..<vw {
            if ix >= effectLo && ix <= effectHi {
                // Inside the gesture's effect zone: use the fresh SIOX result.
                merged[ix] = horizon[ix]
            }
            // Outside: keep the previous value (already in `merged`).
        }
        mergedHorizon = merged
    } else {
        // No previous horizon or no gesture bounds — use full SIOX result.
        mergedHorizon = horizon
    }

    // Enforce erase-ceiling constraints only.
    //
    // Paint constraints are handled by the reverse scan (bottom-up) in the
    // SIOX function — they produce a terrain-following contour naturally.
    // Erase constraints remain hard ceilings: the user definitively said
    // "this area is NOT sky", so the horizon must stay at or above the
    // erased Y position.
    var constrained = mergedHorizon
    if let constraints = constraints {
        for ix in 0..<vw {
            guard let y = constrained[ix] else { continue }
            if case .eraseCeiling(let ceiling) = constraints[ix] {
                constrained[ix] = min(y, ceiling)
            }
        }
    }

    // Clamp to band boundaries — the horizon must stay within
    // the user's originally selected horizon band.
    for ix in 0..<vw {
        guard let y = constrained[ix] else { continue }
        let top = bandTop[ix] ?? 0
        let bot = bandBot[ix] ?? (vh - 1)
        constrained[ix] = max(top, min(y, bot))
    }

    paintState.applyExpandedHorizonMask(constrained)
    paintState.endExpanding()
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

    var body: some View {
        bottomToolbar
            .onDisappear {
                // Auto-save when dismissed via toggle (not Cancel / Escape).
                // Only save during refinement — band selection has no horizon.
                guard paintState.phase == .refinement,
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
        Label("Brush: \(Int(paintState.brushRadius))px",
              systemImage: "circle.dashed")
            .foregroundColor(.white)
            .font(.system(.caption, design: .monospaced))
            .help("Use [ and ] to shrink / grow the brush")

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
            Label("Clear", systemImage: "trash")
        }
        .disabled(!paintState.hasStrokes)

        Button("Cancel") {
            cancelledExplicitly = true
            viewModel.isShowingHorizonPainter = false
        }
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
        Button("Cancel") {
            cancelledExplicitly = true
            viewModel.isShowingHorizonPainter = false
        }
    }

    // MARK: Refinement toolbar

    @ViewBuilder
    private var refinementToolbar: some View {
        Label("Brush: \(Int(paintState.brushRadius))px",
              systemImage: "circle.dashed")
            .foregroundColor(.white)
            .font(.system(.caption, design: .monospaced))
            .help("Use [ and ] to shrink / grow the brush")

        Divider().frame(height: 24)

        Toggle(isOn: Binding(
            get: { paintState.isErasing },
            set: { paintState.isErasing = $0 }
        )) {
            Label(
                paintState.isErasing ? "Erasing" : "Painting",
                systemImage: paintState.isErasing ? "eraser.fill" : "paintbrush.fill"
            )
        }
        .toggleStyle(.button)
        .tint(paintState.isErasing ? .red : .blue)
        .help("Press - to toggle between paint and erase mode")

        Button {
            paintState.clear()
        } label: {
            Label("Clear", systemImage: "trash")
        }
        .help("Start over from band selection")

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
        } label: {
            if isSaving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                }
            } else {
                Label("Save Reference Horizon", systemImage: "checkmark.circle.fill")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(paintState.lastHorizonY == nil || isSaving || paintState.isExpanding)
        .help("Save the horizon reference (Return)")

        Button("Cancel") {
            cancelledExplicitly = true
            viewModel.isShowingHorizonPainter = false
        }
        .help("Discard and close (Esc)")
    }

    // MARK: - Keyboard shortcuts (save / cancel actions)

    @ViewBuilder
    private var actionKeyboardHandlers: some View {
        Button("") {
            cancelledExplicitly = true
            viewModel.isShowingHorizonPainter = false
        }
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
        guard paintState.hasStrokes else { return }
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
            viewModel.isShowingHorizonPainter = false
        } catch {
            Log.w("HorizonPainterToolbarView: save failed: \(error)")
            isSaving  = false
            saveError = error.localizedDescription
        }
    }
}
