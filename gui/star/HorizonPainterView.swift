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
struct HorizonPainterView: View {

    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

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
                paintState.unifiedPaintPath,
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
        guard paintState.hasStrokes else { return }
        let path = paintState.unifiedPaintPath
        guard !path.isEmpty else { return }
        let phase = CGFloat(time * 20).truncatingRemainder(dividingBy: 8)
        context.stroke(path, with: .color(.white),
                       style: StrokeStyle(lineWidth: 1.5, dash: [4, 4], dashPhase: phase))
        context.stroke(path, with: .color(.black),
                       style: StrokeStyle(lineWidth: 1.5, dash: [4, 4], dashPhase: phase + 4))
    }

    // MARK: - Cursor

    private func drawCursor(_ context: inout GraphicsContext) {
        guard let pos = mousePosition else { return }
        let r = paintState.brushRadius
        let rect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)
        let ring = Path(ellipseIn: rect)
        let color: Color = paintState.isErasing ? .red : .white
        context.stroke(ring, with: .color(.black.opacity(0.5)),
                       style: StrokeStyle(lineWidth: 3.0))
        context.stroke(ring, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.5))
        let dot = Path(ellipseIn: CGRect(x: pos.x - 2, y: pos.y - 2, width: 4, height: 4))
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
            .disabled(!paintState.hasStrokes || isSaving)
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
