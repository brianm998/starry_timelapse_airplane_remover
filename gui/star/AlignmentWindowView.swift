import SwiftUI
import KHTSwift
import StarCore
import logging
import Charts

struct AlignmentWindowView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    var body: some View {

        return ZStack {
            if let viewModel = viewModel.imageSequence {
                self.mainView(viewModel)
            } else {
                VStack {
                    Text("No Image sequence loaded.")
                    Text("Load an image sequence in the main star window to see alignment details here.")
                }
            }
        }
          .navigationTitle("Star Alignment Info Window")
    }
        
    func mainView(_ viewModel: ImageSequenceViewModel) -> some View {
        @Bindable var viewModel = viewModel
        return VStack {
            if let results = viewModel.currentFrameView.frameObserver.starAlignmentResults {
                AlignmentDeviationChart(
                  goodFrames: viewModel.goodStarAlignmentInfo,
                  badFrames: viewModel.badStarAlignmentInfo
                )
                  .environment(viewModel)
            }
            /*
            if let results = viewModel.currentFrameView.frameObserver.earthAlignmentResults {
                AlignmentDeviationChart(frames: viewModel.earthAlignmentInfo)
                  .environment(viewModel)
            }*/
        }
    }
}

struct DeviationPoint: Identifiable {
    let id = UUID()
    let baseFrame: Int
    let offset: Int          // neighbor.frameIndex - baseFrame
    let signedDeviation: Double
    let keyPoints: Int
    let isGood: Bool
}

struct AlignmentDeviationChart: View {

    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    let goodFrames: [[AlignmentWarpInfoCodable]]
    let badFrames: [[AlignmentWarpInfoCodable]]

    @State private var hoveredFrame: Int?
    @State private var hoveredOffset: Int?

    @State private var xDomain: ClosedRange<Int>
    
    init(
      goodFrames: [[AlignmentWarpInfoCodable]],
      badFrames: [[AlignmentWarpInfoCodable]]
    ) {
        self.goodFrames = goodFrames
        self.badFrames = badFrames

        let maxFrame = max(goodFrames.count - 1, 0)
        _xDomain = State(initialValue: 0 ... maxFrame)
     }
     
    private var points: [DeviationPoint] {
        makeDeviationPoints(
          goodFrames: goodFrames,
          badFrames: badFrames
        )
    }

    private var pointsByOffset: [(offset: Int, points: [DeviationPoint])] {
        Dictionary(grouping: points, by: \.offset)
          .map { offset, pts in
              (
                offset: offset,
                points: pts.sorted { $0.baseFrame < $1.baseFrame }
              )
          }
          .sorted { $0.offset < $1.offset }
    }

    
    let maxVisibleDeviation: Double = 50.0 // tune this
    
    var body: some View {
        Chart {
            // === Lines ===
            ForEach(pointsByOffset, id: \.offset) { group in
                ForEach(group.points) { point in
                    LineMark(
                      x: .value("Frame", point.baseFrame),
                      y: .value("Deviation", point.signedDeviation)
                    )
                      .foregroundStyle(
                        by: .value(
                          "Neighbor",
                          group.offset > 0 ? "+\(group.offset)" : "\(group.offset)"
                        )
                      )
                      .interpolationMethod(.linear)
                      .opacity(point.isGood ? 1.0 : 0.4) // XXX doesn't work
                }
            }

            // === Current frame indicator ===
            RuleMark(
              x: .value("Current Frame", viewModel.currentIndex)
            )
              .lineStyle(StrokeStyle(lineWidth: 2))
              .foregroundStyle(.red)
              .annotation(position: .top, alignment: .leading) {
                  Text("Current")
                    .font(.caption)
                    .foregroundColor(.red)
              }

            // === Hover indicator ===
            if let hoveredFrame, let hoveredOffset {
                RuleMark(
                  x: .value("Hover Frame", hoveredFrame)
                )
                  .foregroundStyle(.gray.opacity(0.4))

                PointMark(
                  x: .value("Frame", hoveredFrame),
                  y: .value(
                    "Deviation",
                    deviationAt(frame: hoveredFrame, offset: hoveredOffset)
                  )
                )
                  .symbolSize(60)
                  .annotation(position: .top) {
                      tooltipView(
                        frame: hoveredFrame,
                        offset: hoveredOffset
                      )
                  }
            }
        }
          .onChange(of: viewModel.currentIndex) { 
              ensureVisible(frame: viewModel.currentIndex)
          }
          .chartXScale(domain: xDomain)
          .chartYScale(domain: -maxVisibleDeviation ... maxVisibleDeviation)
          .chartXAxisLabel("Frame Index")
          .chartYAxisLabel("Deviation")
          .chartLegend(position: .trailing)
          .chartYScale(domain: symmetricDomain())
          .chartOverlay { proxy in
              GeometryReader { geo in
                  Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let hoveredFrame {
                            viewModel.currentIndex = hoveredFrame
                        }
                    }
                    .simultaneousGesture(
                      DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            pan(by: value.translation.width)
                        }
                    )
                    .simultaneousGesture(
                      MagnificationGesture()
                        .onChanged { scale in
                            zoom(scale: scale)
                        }
                        .onEnded { _ in
                            lastMagnification = 1.0
                        }
                    )
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            updateHover(
                              location: location,
                              proxy: proxy,
                              geometry: geo
                            )
                        case .ended:
                            hoveredFrame = nil
                            hoveredOffset = nil
                        }
                    }
              }
          }
          .frame(minHeight: 320)
    }

    private func ensureVisible(frame: Int) {
        guard !xDomain.contains(frame) else { return }

        let span = xDomain.upperBound - xDomain.lowerBound
        let lower = max(0, frame - span / 2)
        let upper = min(goodFrames.count - 1, lower + span)

        xDomain = lower ... upper
    }

    @State private var lastMagnification: CGFloat = 1.0

    private func zoom(scale: CGFloat) {
        let delta = scale / lastMagnification
        lastMagnification = scale

        let center = (xDomain.lowerBound + xDomain.upperBound) / 2
        let currentSpan = xDomain.upperBound - xDomain.lowerBound
        guard delta != 0 else { return }
        var newSpan = max(10, Int(Double(currentSpan) / Double(delta)))

        if newSpan > goodFrames.count { newSpan = goodFrames.count }
        if newSpan < 20 { newSpan = 20 }
        
        let maxFrame = goodFrames.count - 1
        let half = newSpan / 2

        let lower = max(0, center - half)
        let upper = min(maxFrame, center + half)

        xDomain = lower ... upper
    }

    
    private func pan(by translation: CGFloat) {
        let span = xDomain.upperBound - xDomain.lowerBound
        let delta = Int(Double(translation) * Double(span) / 300.0)

        shiftDomain(by: -delta)
    }

    private func shiftDomain(by delta: Int) {
        let maxFrame = goodFrames.count - 1

        let lower = max(0, xDomain.lowerBound + delta)
        let upper = min(maxFrame, lower + (xDomain.count - 1))

        if lower < upper { xDomain = lower ... upper }
    }
    
    var oldBody: some View {
        Chart {
            ForEach(points) { point in
                LineMark(
                  x: .value("Frame", point.baseFrame),
                  y: .value("Deviation", point.signedDeviation)
                )
                  .foregroundStyle(
                    by: .value(
                      "Neighbor",
                      point.offset > 0
                        ? "+\(point.offset)"
                        : "\(point.offset)"
                    )
                  )
                //                  .foregroundStyle(by: .value("Offset", point.offset))
                  .interpolationMethod(.linear)
                
            }
        }
          .chartXAxisLabel("Frame Index")
          .chartYAxisLabel("Deviation")
          .chartLegend(position: .trailing)
          .frame(minHeight: 300)
          .chartYScale(domain: symmetricDomain())
    }

    func symmetricDomain() -> ClosedRange<Double> {
        let maxDeviation = abs(points.map(\.signedDeviation).max() ?? 1)
        return -maxDeviation ... maxDeviation
    }
    
    func makeDeviationPoints(
      goodFrames: [[AlignmentWarpInfoCodable]],
      badFrames: [[AlignmentWarpInfoCodable]]
    ) -> [DeviationPoint] {

        var points: [DeviationPoint] = []

        for (baseFrameIndex, neighbors) in goodFrames.enumerated() {
            for neighbor in neighbors {
                let offset = neighbor.frameIndex - baseFrameIndex
                guard offset != 0 else { continue }

                let signedDeviation =
                  offset > 0 ? neighbor.deviation : -neighbor.deviation

                points.append(
                  DeviationPoint(
                    baseFrame: baseFrameIndex,
                    offset: offset,
                    signedDeviation: signedDeviation,
                    keyPoints: neighbor.neighborKeyPoints,
                    isGood: true
                  )
                )
            }
        }

        for (baseFrameIndex, neighbors) in badFrames.enumerated() {
            for neighbor in neighbors {
                let offset = neighbor.frameIndex - baseFrameIndex
                guard offset != 0 else { continue }

                let signedDeviation =
                  offset > 0 ? neighbor.deviation : -neighbor.deviation

                points.append(
                  DeviationPoint(
                    baseFrame: baseFrameIndex,
                    offset: offset,
                    signedDeviation: signedDeviation,
                    keyPoints: neighbor.neighborKeyPoints,
                    isGood: false
                  )
                )
            }
        }

        return points
    }
}

private extension AlignmentDeviationChart {

    func updateHover(
        location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        let plotOrigin = geometry[proxy.plotAreaFrame].origin
        let relativeX = location.x - plotOrigin.x
        let relativeY = location.y - plotOrigin.y

        guard
            let frame: Int = proxy.value(atX: relativeX),
            let deviation: Double = proxy.value(atY: relativeY)
        else { return }

        // Find closest offset at this frame
        let candidates = points.filter { $0.baseFrame == frame }

        guard let closest = candidates.min(by: {
            abs($0.signedDeviation - deviation) <
            abs($1.signedDeviation - deviation)
        }) else { return }

        hoveredFrame = frame
        hoveredOffset = closest.offset
    }

    func deviationAt(frame: Int, offset: Int) -> Double {
        points.first {
            $0.baseFrame == frame && $0.offset == offset
        }?.signedDeviation ?? 0
    }

    func keyPointsAt(frame: Int, offset: Int) -> Int {
        points.first {
            $0.baseFrame == frame && $0.offset == offset
        }?.keyPoints ?? 0
    }

    func isGoodAt(frame: Int, offset: Int) -> Bool {
        points.first {
            $0.baseFrame == frame && $0.offset == offset
        }?.isGood ?? false
    }
}


private extension AlignmentDeviationChart {

    func tooltipView(frame: Int, offset: Int) -> some View {
        let deviation = deviationAt(frame: frame, offset: offset)
        let keypoints = keyPointsAt(frame: frame, offset: offset)
        let isGood = isGoodAt(frame: frame, offset: offset)
        
        return VStack(alignment: .leading, spacing: 4) {
            Text("Frame \(frame)")
                .font(.caption.bold())

            Text("Neighbor offset: \(offset > 0 ? "+" : "")\(offset)")
                .font(.caption)

            Text(String(format: "Deviation: %.3f", deviation))
              .font(.caption.monospacedDigit())
              .foregroundColor(isGood ? .green : .red)

            Text("Keypoints: \(keypoints)")
                .font(.caption.monospacedDigit())
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.background)
                .shadow(radius: 3)
        )
    }
}
