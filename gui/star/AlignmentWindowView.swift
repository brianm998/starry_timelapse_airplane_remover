import SwiftUI
import KHTSwift
import StarCore
import logging
import Charts

struct AlignmentWindowView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    @State private var showStarDeviation = true
    @State private var showEarthDeviation = true
    
    @State private var showStarKeypoints = true
    @State private var showEarthKeypoints = true

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
          .padding(20)
          .navigationTitle("Star Alignment Info")
    }
        
    func mainView(_ viewModel: ImageSequenceViewModel) -> some View {
        @Bindable var viewModel = viewModel
        return HStack {
            ScrollView {
                VStack(alignment: .leading) {
                    if let results = viewModel.currentFrameView.frameObserver.starAlignmentResults {
                        if showStarDeviation {
                            Text("Deviation in Star Alignment")
                            AlignmentDeviationChart(
                              frames: viewModel.starAlignmentInfo,
                              foregroundColor: .gray
                            )
                              .frame(minHeight: 320)
                        }
                        if showStarKeypoints {
                            AlignmentKeypointsChart(
                              keyPoints: viewModel.skyKeypointCounts
                            )
                        }
                    }
                    if viewModel.allowEarthAlignment,
                       let results = viewModel.currentFrameView.frameObserver.earthAlignmentResults
                    {
                        if showEarthDeviation {
                            Text("Deviation in Earth Alignment")
                            AlignmentDeviationChart(
                              frames: viewModel.earthAlignmentInfo,
                              foregroundColor: .gray
                            )
                              .frame(minHeight: 320)
                        }
                        if showEarthKeypoints {
                            AlignmentKeypointsChart(
                              keyPoints: viewModel.earthKeypointCounts
                            )
                        }
                    }
                }
            }
            self.controlsView
        }
          .environment(viewModel)
    }

    private var controlsView: some View {
        VStack(alignment: .leading) {
            Space(height: 60)
            Text("Show:")
            Toggle("Star Deviation", isOn: $showStarDeviation)
            Toggle("Star Keypoints", isOn: $showStarKeypoints)
            if let viewModel = viewModel.imageSequence,
               viewModel.allowEarthAlignment
            {
                Toggle("Earth Deviation", isOn: $showEarthDeviation)
                Toggle("Earth Keypoints", isOn: $showEarthKeypoints)
            }
            Divider()
              .fixedSize(horizontal: true, vertical: false)
            Spacer()
            Text("Legend")
            OffsetLegendView(offsets: allVisibleOffsets)
        }
    }

    var allVisibleOffsets: [Int] {
        var offsets = Set<Int>()

        func collect(from frames: [[AlignmentWarpInfoCodable]]) {
            for (base, neighbors) in frames.enumerated() {
                for n in neighbors {
                    let offset = n.frameIndex - base
                    if offset != 0 {
                        offsets.insert(offset)
                    }
                }
            }
        }
        if let viewModel = viewModel.imageSequence {
            if showStarDeviation || showStarKeypoints {
                collect(from: viewModel.starAlignmentInfo)
            }

            if showEarthDeviation || showEarthKeypoints {
                collect(from: viewModel.earthAlignmentInfo)
            }
        }

        return offsets.sorted()
    }
}

struct DeviationPoint: Identifiable {
    let id = UUID()
    let baseFrame: Int
    let offset: Int          // neighbor.frameIndex - baseFrame
    let signedDeviation: Double
    let alignmentState: AlignmentState
    let isGood: Bool
}

struct GraphKeyPoint: Identifiable {
    let id = UUID()
    let baseFrame: Int
    let keyPointCount: Int
}

struct AlignmentKeypointsChart: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    let keyPoints: [Int]

    @State private var hoveredFrame: Int?
//    @State private var hoveredOffset: Int?

    @State private var xDomain: ClosedRange<Int>
    
    init(
      keyPoints: [Int]
    ) {
        self.keyPoints = keyPoints

        let maxFrame = max(keyPoints.count - 1, 0)
        _xDomain = State(initialValue: 0 ... maxFrame)
     }
     
    private var points: [GraphKeyPoint] {
        makeKeyframePoints()
    }

    var body: some View {
        Chart {
            // === Lines ===
            ForEach(points, id: \.id) { point in
                LineMark(
                  x: .value("Frame", point.baseFrame),
                  y: .value("KeyPoints", point.keyPointCount)
                )
                  //.foregroundStyle(Color.byOffset(group.offset))
                //                        .foregroundStyle(by: .value("Neighbor Offset", group.offset))
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
            if let hoveredFrame {
                RuleMark(
                  x: .value("Hover Frame", hoveredFrame)
                )
                  .foregroundStyle(.gray.opacity(0.4))

                PointMark(
                  x: .value("Frame", hoveredFrame),
                  y: .value(
                    "Key Points",
                    keyPointsAt(frame: hoveredFrame)
                  )
                )
                  .symbolSize(60)
                  .annotation(position: .top) {
                      tooltipView(
                        frame: hoveredFrame
                      )
                  }
            }
        }
          .chartPlotStyle { $0.clipped() }
          .onChange(of: viewModel.currentIndex) { 
              ensureVisible(frame: viewModel.currentIndex)
          }
          .chartXScale(domain: xDomain)
//          .chartYScale(domain: 0 ... maxVisibleDeviation)
          .chartXAxisLabel("Frame Index")
          .chartYAxisLabel("Number of Key Points")
          .chartLegend(.hidden)
          //.chartYScale(domain: symmetricDomain())
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
                         //   hoveredOffset = nil
                        }
                    }
              }
          }
          .frame(minHeight: 320)
    }
    
    @State private var lastMagnification: CGFloat = 1.0

    private func zoom(scale: CGFloat) {
        let delta = scale / lastMagnification
        lastMagnification = scale

        let center = (xDomain.lowerBound + xDomain.upperBound) / 2
        let currentSpan = xDomain.upperBound - xDomain.lowerBound
        guard delta != 0 else { return }
        var newSpan = max(10, Int(Double(currentSpan) / Double(delta)))

        if newSpan > keyPoints.count { newSpan = keyPoints.count }
        if newSpan < 20 { newSpan = 20 }
        
        let maxFrame = keyPoints.count - 1
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
        let maxFrame = keyPoints.count - 1

        let lower = max(0, xDomain.lowerBound + delta)
        let upper = min(maxFrame, lower + (xDomain.count - 1))

        if lower < upper { xDomain = lower ... upper }
    }
    
    func makeKeyframePoints() -> [GraphKeyPoint] {

        var points: [GraphKeyPoint] = []

        for (index, keyPointCount) in keyPoints.enumerated() {
            points.append(
              GraphKeyPoint(
                baseFrame: index,
                keyPointCount: keyPointCount
              )
            )
        }

        return points
    }

    private func ensureVisible(frame: Int) {
        guard !xDomain.contains(frame) else { return }

        let span = xDomain.upperBound - xDomain.lowerBound
        let lower = max(0, frame - span / 2)
        let upper = min(keyPoints.count - 1, lower + span)

        xDomain = lower ... upper
    }

}

struct AlignmentDeviationChart: View {

    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    let frames: [[AlignmentWarpInfoCodable]]

    let foregroundColor: Color
    
    @State private var hoveredFrame: Int?
    @State private var hoveredOffset: Int?

    @State private var xDomain: ClosedRange<Int>
    
    init(
      frames: [[AlignmentWarpInfoCodable]],
      foregroundColor: Color
    ) {
        self.frames = frames
        self.foregroundColor = foregroundColor

        let maxFrame = max(frames.count - 1, 0)
        _xDomain = State(initialValue: 0 ... maxFrame)
     }
     
    private var points: [DeviationPoint] {
        makeDeviationPoints(
          frames: frames
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
                      .foregroundStyle(Color.byOffset(point.offset))
                      .foregroundStyle(by: .value("Neighbor Offset", group.offset))
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
          .chartPlotStyle { $0.clipped() }
          .onChange(of: viewModel.currentIndex) { 
              ensureVisible(frame: viewModel.currentIndex)
          }
          .chartXScale(domain: xDomain)
          .chartYScale(domain: -maxVisibleDeviation ... maxVisibleDeviation)
          .chartXAxisLabel {
              Text("Frame Index")
                .foregroundColor(foregroundColor)
          }
          .chartYAxisLabel {
              Text("Deviation")
                .foregroundColor(foregroundColor)
          }
          .chartLegend(.hidden)
          .chartYScale(domain: symmetricDomain())
          .chartXAxis {
              AxisMarks {
                  AxisGridLine()
                    .foregroundStyle(foregroundColor)
                  AxisTick()
                    .foregroundStyle(foregroundColor)
              }
          }
          .chartYAxis {
              AxisMarks {
                  AxisGridLine()
                    .foregroundStyle(foregroundColor)
                  AxisTick()
                    .foregroundStyle(foregroundColor)
              }
          }
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
    }

    private func ensureVisible(frame: Int) {
        guard !xDomain.contains(frame) else { return }

        let span = xDomain.upperBound - xDomain.lowerBound
        let lower = max(0, frame - span / 2)
        let upper = min(frames.count - 1, lower + span)

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

        if newSpan > frames.count { newSpan = frames.count }
        if newSpan < 20 { newSpan = 20 }
        
        let maxFrame = frames.count - 1
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
        let maxFrame = frames.count - 1

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
                    signedDeviation: signedDeviation,
                    alignmentState: neighbor.alignmentState,
                    isGood: true
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
    func isGoodAt(frame: Int, offset: Int) -> Bool {
        points.first {
            $0.baseFrame == frame && $0.offset == offset
        }?.isGood ?? false
    }

    func alignmentStateAt(frame: Int, offset: Int) -> AlignmentState {
        points.first {
            $0.baseFrame == frame && $0.offset == offset
        }?.alignmentState ?? .unknown
    }
}


private extension AlignmentDeviationChart {

    func tooltipView(frame: Int, offset: Int) -> some View {
        let deviation = deviationAt(frame: frame, offset: offset)
  //      let keypoints = keyPointsAt(frame: frame, offset: offset)
        let isGood = isGoodAt(frame: frame, offset: offset)
        let alignmentState = alignmentStateAt(frame: frame, offset: offset)
        
        return VStack(alignment: .leading, spacing: 4) {
            Text("Frame \(frame)")
                .font(.caption.bold())

            Text("Neighbor offset: \(offset > 0 ? "+" : "")\(offset)")
                .font(.caption)

            Text(String(format: "Deviation: %.3f", deviation))
              .font(.caption.monospacedDigit())
              .foregroundColor(isGood ? .green : .red)

            Text("Aligned: \(alignmentState)")
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

//

private extension AlignmentKeypointsChart {

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
            let keypoints: Double = proxy.value(atY: relativeY)
        else { return }

        // Find closest offset at this frame
        let candidates = points.filter { $0.baseFrame == frame }

        guard let closest = candidates.min(by: {
            abs($0.keyPointCount - Int(keypoints)) <
            abs($1.keyPointCount - Int(keypoints))
        }) else { return }

        hoveredFrame = frame
//        hoveredOffset = closest.offset
    }


    func keyPointsAt(frame: Int) -> Int {
        points.first {
            $0.baseFrame == frame
        }?.keyPointCount ?? 0
    }
}


private extension AlignmentKeypointsChart {

    func tooltipView(frame: Int) -> some View {
        let keypoints = keyPointsAt(frame: frame)
        
        return VStack(alignment: .leading, spacing: 4) {
            Text("Frame \(frame)")
                .font(.caption.bold())

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

struct OffsetLegendView: View {
    let offsets: [Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Neighbor Offset")
                .font(.caption.bold())

            ForEach(offsets, id: \.self) { offset in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: offset))
                        .frame(width: 16, height: 3)

                    Text(offset > 0 ? "+\(offset)" : "\(offset)")
                        .font(.caption.monospacedDigit())
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.background)
                .shadow(radius: 2)
        )
    }

    private func color(for offset: Int) -> Color {
        // MUST match chart mapping
        Color.byOffset(offset)
    }
}

extension Color {
    static func byOffset(_ offset: Int) -> Color {
        let palette: [Color] = [
            .blue, .green, .orange, .purple,
            .pink, .teal, .indigo, .brown
        ]
        return palette[(abs(offset) - 1) % palette.count]
    }
}
