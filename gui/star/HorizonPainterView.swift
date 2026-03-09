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

    @State private var mousePosition: CGPoint? = nil

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
            context.fill(
                paintState.displayPath,
                with: .color(.blue.opacity(0.35))
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
                paintState.addStroke(at: gesture.location)
                mousePosition = gesture.location
            }
            .onEnded { gesture in
                paintState.addStroke(at: gesture.location)
                // Mark end of gesture so the next press won't gap-fill back here.
                paintState.endSegment()
                // Trigger async object-selection expansion.
                let frameView = viewModel.currentFrameView
                let ps        = paintState
                Task { await triggerObjectSelection(paintState: ps, frameView: frameView) }
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

        Button("") { paintState.isErasing.toggle() }
            .keyboardShortcut("-", modifiers: [])
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

// MARK: - Object-selection expansion

/// Runs the live object-selection pass: computes the bottom boundary of the
/// painted area, snaps it to Canny edges, and applies the resulting sky mask.
///
/// Called on the `@MainActor` after each gesture ends.  The expensive
/// `computePaintedBoundaries` and `computeLiveObjectSelection` calls run on
/// detached background tasks inside this function (or within the frame method
/// itself), so the main actor is never blocked.
@MainActor
private func triggerObjectSelection(
    paintState: HorizonPaintState,
    frameView: FrameViewModel
) async {
    guard paintState.hasStrokes else { return }

    // Capture immutable value types before any suspension point.
    let rawPath    = paintState.unifiedPaintPath   // Path is a value type — safe copy
    let vw         = Int(paintState.viewWidth)
    let vh         = Int(paintState.viewHeight)
    let generation = paintState.expansionGeneration

    guard let frame = frameView.frame else { return }

    paintState.isExpanding = true

    // 1. Compute both top + bottom boundaries of the painted area off the main thread.
    //    The full painted band is used as the Canny search window so the horizon is
    //    found regardless of brush size.  `Path.contains` on a copied Path is thread-safe.
    let (topBoundary, bottomBoundary) = await Task.detached(priority: .userInitiated) {
        computePaintedBoundaries(path: rawPath, viewWidth: vw, viewHeight: vh)
    }.value

    // Bail if a new stroke arrived while we were computing.
    guard paintState.expansionGeneration == generation else {
        paintState.isExpanding = false
        return
    }

    // 2. Canny snap + interpolation (async, heavy work runs in detached task
    //    inside `computeLiveObjectSelection`).
    let snappedHorizon: [Int?]?
    do {
        snappedHorizon = try await frame.computeLiveObjectSelection(
            topBoundaryY:    topBoundary,
            bottomBoundaryY: bottomBoundary,
            viewWidth:  vw,
            viewHeight: vh
        )
    } catch {
        Log.w("HorizonPainterView: object selection failed: \(error)")
        paintState.isExpanding = false
        return
    }

    // 3. Apply result — only if no new stroke arrived while we were expanding.
    guard paintState.expansionGeneration == generation,
          let horizon = snappedHorizon
    else {
        paintState.isExpanding = false
        return
    }

    paintState.applyExpandedHorizonMask(horizon)
    paintState.isExpanding = false
}

/// Compute both the top (topmost) and bottom (bottommost) painted-Y per column
/// for the given `Path` in view coordinates.
///
/// Returns a tuple `(top, bottom)` where each element is an `[Int?]` of length
/// `viewWidth`.  `nil` means that column has no painted pixels.
///
/// Runs the scan within the path's bounding rect to avoid unnecessary work.
/// Safe to call from any thread — `Path` is a value type and `Path.contains`
/// has no side-effects.
private func computePaintedBoundaries(
    path: Path,
    viewWidth: Int,
    viewHeight: Int
) -> (top: [Int?], bottom: [Int?]) {
    let nils = [Int?](repeating: nil, count: viewWidth)
    guard !path.isEmpty else { return (top: nils, bottom: nils) }

    // Limit vertical scan to the path's bounding rect (+ a small margin).
    let bounds   = path.boundingRect
    let scanMinY = max(0,             Int(bounds.minY) - 4)
    let scanMaxY = min(viewHeight - 1, Int(bounds.maxY) + 4)

    var topResult    = [Int?](repeating: nil, count: viewWidth)
    var bottomResult = [Int?](repeating: nil, count: viewWidth)

    for ix in 0..<viewWidth {
        let vx = CGFloat(ix) + 0.5
        // Top boundary: scan downward — first hit is the topmost painted row.
        for iy in scanMinY...scanMaxY {
            if path.contains(CGPoint(x: vx, y: CGFloat(iy) + 0.5)) {
                topResult[ix] = iy
                break
            }
        }
        // Bottom boundary: scan upward — first hit is the bottommost painted row.
        for iy in stride(from: scanMaxY, through: scanMinY, by: -1) {
            if path.contains(CGPoint(x: vx, y: CGFloat(iy) + 0.5)) {
                bottomResult[ix] = iy
                break
            }
        }
    }
    return (top: topResult, bottom: bottomResult)
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
                guard paintState.hasStrokes,
                      !savedAlready,
                      !cancelledExplicitly,
                      !isSaving
                else { return }

                let frame = viewModel.currentFrameView.frame
                let rawY  = paintState.horizonYPerColumn(
                    imageWidth:  Int(paintState.viewWidth),
                    imageHeight: Int(paintState.viewHeight)
                )
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

    // MARK: - Toolbar layout

    private var bottomToolbar: some View {
        HStack(spacing: 16) {

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
            .disabled(!paintState.hasStrokes)
            .help("Remove all painted strokes")

            Spacer()

            // Object-selection expansion progress indicator.
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
            .disabled(!paintState.hasStrokes || isSaving || paintState.isExpanding)
            .help("Snap to Canny edges and save as the reference horizon (Return)")

            Button("Cancel") {
                cancelledExplicitly = true
                viewModel.isShowingHorizonPainter = false
            }
            .help("Discard painting and close without saving (Esc)")
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

    // MARK: - Keyboard shortcuts (save / cancel actions)

    @ViewBuilder
    private var actionKeyboardHandlers: some View {
        Button("") {
            cancelledExplicitly = true
            viewModel.isShowingHorizonPainter = false
        }
        .keyboardShortcut(.escape, modifiers: [])
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)

        Button("") { Task { await saveHorizonReference() } }
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

        let rawY = paintState.horizonYPerColumn(
            imageWidth:  Int(paintState.viewWidth),
            imageHeight: Int(paintState.viewHeight)
        )

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
