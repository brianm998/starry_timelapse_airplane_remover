import SwiftUI

/// The import robot's height inside a progress ring: 60% of the ring's inner diameter, at most 120 pt (0 when there is no inner room).
func loadingRingArtSize(outerDiameter: CGFloat, stroke: CGFloat) -> CGFloat {
    let inner = outerDiameter - 2 * stroke
    guard inner > 0 else { return 0 }
    return min(0.6 * inner, 120)
}

/// A piece of art drawn at a given height, keeping its aspect. Decoration: hidden from accessibility, no strings.
struct ScaledArtImage: View {
    let art: StarArt
    let height: CGFloat

    init(_ art: StarArt, height: CGFloat) { self.art = art; self.height = height }

    var body: some View {
        Image(art.rawValue)
            .resizable()
            .interpolation(.high)
            .aspectRatio(art.size.width / art.size.height, contentMode: .fit)
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

/// A progress ring with a VStack centred in it: the import robot on top, `content` (the caption) below, with `spacing` between them so they never touch.
struct CircularProgressView<Content: View>: View {

    /// Gap between the robot and the caption beneath it.
    static var artSpacing: CGFloat { 20 }

    @Binding private var progress: Double
    private let content: Content

    init(progress: Binding<Double>, @ViewBuilder content: () -> Content) {
        _progress = progress
        self.content = content()
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    Color.blue.opacity(0.5),
                    lineWidth: 80
                )
            Circle()
                // 2
                .trim(from: 0, to: progress)
                .stroke(
                    Color.blue,
                    style: StrokeStyle(
                      lineWidth: 80,
                      lineCap: .round
                    )
                )
                .rotationEffect(.degrees(-90))
            // The stroke is centred on the frame's edge, so the ring's inner diameter is the side minus the stroke on both sides.
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                let h = loadingRingArtSize(outerDiameter: side + 80, stroke: 80)
                VStack(spacing: Self.artSpacing) {
                    if h > 0 {
                        ScaledArtImage(.import, height: h)
                    }
                    content
                }
                  .multilineTextAlignment(.center)
                  .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

extension CircularProgressView where Content == EmptyView {
    init(progress: Binding<Double>) {
        self.init(progress: progress) { EmptyView() }
    }
}
