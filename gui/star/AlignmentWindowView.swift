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
                AlignmentDeviationChart(frames: viewModel.starAlignmentInfo)
                  .environment(viewModel)
            }
            if let results = viewModel.currentFrameView.frameObserver.earthAlignmentResults {
                AlignmentDeviationChart(frames: viewModel.earthAlignmentInfo)
                  .environment(viewModel)
            }
        }
    }
}

struct DeviationPoint: Identifiable {
    let id = UUID()
    let baseFrame: Int
    let offset: Int          // neighbor.frameIndex - baseFrame
    let signedDeviation: Double
}

struct AlignmentDeviationChart: View {

    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    let frames: [[AlignmentWarpInfoCodable]]


    @State private var hoveredFrame: Int?
    @State private var hoveredOffset: Int?

    
    private var points: [DeviationPoint] {
        makeDeviationPoints(frames: frames)
    }

    var body: some View {
        Chart {
            // === Lines ===
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
                  .interpolationMethod(.linear)
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
          .chartXAxisLabel("Frame Index")
          .chartYAxisLabel("Deviation")
          .chartLegend(position: .trailing)
          .chartYScale(domain: symmetricDomain())
          .chartOverlay { proxy in
              GeometryReader { geo in
                  Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
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
      frames: [[AlignmentWarpInfoCodable]]
    ) -> [DeviationPoint] {

        var points: [DeviationPoint] = []

        for (baseFrameIndex, neighbors) in frames.enumerated() {
            for neighbor in neighbors {
                let offset = neighbor.frameIndex - baseFrameIndex
                guard offset != 0 else { continue }

                let signedDeviation =
                  offset > 0 ? neighbor.deviation : -neighbor.deviation

                points.append(
                  DeviationPoint(
                    baseFrame: baseFrameIndex,
                    offset: offset,
                    signedDeviation: signedDeviation
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
}


private extension AlignmentDeviationChart {

    func tooltipView(frame: Int, offset: Int) -> some View {
        let deviation = deviationAt(frame: frame, offset: offset)

        return VStack(alignment: .leading, spacing: 4) {
            Text("Frame \(frame)")
                .font(.caption.bold())

            Text("Neighbor offset: \(offset > 0 ? "+" : "")\(offset)")
                .font(.caption)

            Text(String(format: "Deviation: %.3f", deviation))
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
