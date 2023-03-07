import SwiftUI
import NtarCore

struct OutlierGroupTableRow: Identifiable {
    var id = UUID()
    
    let name: String
    let size: UInt

    // decision tree values
    let dt_size: Double
    let dt_width: Double
    let dt_height: Double
    let dt_centerX: Double
    let dt_centerY: Double
    let dt_minX: Double
    let dt_minY: Double
    let dt_maxX: Double
    let dt_maxY: Double
    let dt_hypotenuse: Double
    let dt_aspectRatio: Double
    let dt_fillAmount: Double
    let dt_surfaceAreaRatio: Double
    let dt_averagebrightness: Double
    let dt_medianBrightness: Double
    let dt_maxBrightness: Double
    let dt_avgCountOfFirst10HoughLines: Double
    let dt_maxThetaDiffOfFirst10HoughLines: Double
    let dt_maxRhoDiffOfFirst10HoughLines: Double
    let dt_numberOfNearbyOutliersInSameFrame: Double
    let dt_adjecentFrameNeighboringOutliersBestTheta: Double
    let dt_histogramStreakDetection: Double
    let dt_maxHoughTransformCount: Double
    let dt_maxHoughTheta: Double
    let dt_neighboringInterFrameOutlierThetaScore: Double


    init(_ group: OutlierGroup) async {
        name = await group.name
        size = await group.size

        dt_size = await group.decisionTreeValue(for: .size)
        dt_width = await group.decisionTreeValue(for: .width)
        dt_height = await group.decisionTreeValue(for: .height)
        dt_centerX = await group.decisionTreeValue(for: .centerX)
        dt_centerY = await group.decisionTreeValue(for: .centerY)
        dt_minX = await group.decisionTreeValue(for: .minX)
        dt_minY = await group.decisionTreeValue(for: .minY)
        dt_maxX = await group.decisionTreeValue(for: .maxX)
        dt_maxY = await group.decisionTreeValue(for: .maxY)
        dt_hypotenuse = await group.decisionTreeValue(for: .hypotenuse)
        dt_aspectRatio = await group.decisionTreeValue(for: .aspectRatio)
        dt_fillAmount = await group.decisionTreeValue(for: .fillAmount)
        dt_surfaceAreaRatio = await group.decisionTreeValue(for: .surfaceAreaRatio)
        dt_averagebrightness = await group.decisionTreeValue(for: .averagebrightness)
        dt_medianBrightness = await group.decisionTreeValue(for: .medianBrightness)
        dt_maxBrightness = await group.decisionTreeValue(for: .maxBrightness)
        dt_avgCountOfFirst10HoughLines = await group.decisionTreeValue(for: .avgCountOfFirst10HoughLines)
        dt_maxThetaDiffOfFirst10HoughLines = await group.decisionTreeValue(for: .maxThetaDiffOfFirst10HoughLines)
        dt_maxRhoDiffOfFirst10HoughLines = await group.decisionTreeValue(for: .maxRhoDiffOfFirst10HoughLines)
        dt_numberOfNearbyOutliersInSameFrame = await group.decisionTreeValue(for: .numberOfNearbyOutliersInSameFrame)
        dt_adjecentFrameNeighboringOutliersBestTheta = await group.decisionTreeValue(for: .adjecentFrameNeighboringOutliersBestTheta)

        dt_histogramStreakDetection = await group.decisionTreeValue(for: .histogramStreakDetection)
        dt_maxHoughTransformCount = await group.decisionTreeValue(for: .maxHoughTransformCount)
        dt_maxHoughTheta = await group.decisionTreeValue(for: .maxHoughTheta)
        dt_neighboringInterFrameOutlierThetaScore = await group.decisionTreeValue(for: .neighboringInterFrameOutlierThetaScore)
    }
}

typealias DTColumn = TableColumn<OutlierGroupTableRow,
                                             KeyPathComparator<OutlierGroupTableRow>,
                                             Text,
                                             Text>

struct InfoSheetView: View {
    @Binding var isVisible: Bool
    @ObservedObject var viewModel: ViewModel

    @Binding var outlierGroupTableRows: [OutlierGroupTableRow]
    
    var closure: () -> Void

    init(isVisible: Binding<Bool>,
         outlierGroupTableRows: Binding<[OutlierGroupTableRow]>,
         viewModel: ViewModel,
         closure: @escaping () -> Void)
    {
        self._isVisible = isVisible
        self._outlierGroupTableRows = outlierGroupTableRows
        self.closure = closure
        self.viewModel = viewModel

        // this doesn't work here :(
        //outlierGroupTableRows.sort(using: OutlierGroupTableRow.size)
    }

    var nameColumn: TableColumn<OutlierGroupTableRow,
                                KeyPathComparator<OutlierGroupTableRow>,
                                Text,
                                Text>
    {
        TableColumn("name", value: \OutlierGroupTableRow.name)
    }
    
    var sizeColumn: TableColumn<OutlierGroupTableRow,
                                KeyPathComparator<OutlierGroupTableRow>,
                                Text,
                                Text>
    {
        TableColumn("size", value: \OutlierGroupTableRow.size) { (row: OutlierGroupTableRow) in
            Text(String(row.size))
        }
    }
    
    var dtSizeColumn: DTColumn {
        self.tableColumn(for: "dt_size", value: \.dt_size) { $0.dt_size }
    }
    
    var dtWidthColumn: DTColumn {
        self.tableColumn(for: "dt_width", value: \.dt_width) { $0.dt_width }
    }
    
    var dtHeightColumn: DTColumn {
        self.tableColumn(for: "dt_height", value: \.dt_height) { $0.dt_height }
    }

    var dtCenterXColumn: DTColumn {
        self.tableColumn(for: "dt_centerX", value: \.dt_centerX) { $0.dt_centerX }
    }

    var dtCenterYColumn: DTColumn {
        self.tableColumn(for: "dt_centerY", value: \.dt_centerY) { $0.dt_centerY }
    }

    var dtMinXColumn: DTColumn {
        self.tableColumn(for: "dt_minX", value: \.dt_minX) { $0.dt_minX }
    }

    var dtMinYColumn: DTColumn {
        self.tableColumn(for: "dt_minY", value: \.dt_minY) { $0.dt_minY }
    }

    var dtMaxXColumn: DTColumn {
        self.tableColumn(for: "dt_maxX", value: \.dt_maxX) { $0.dt_maxX }
    }

    var dtMaxYColumn: DTColumn {
        self.tableColumn(for: "dt_maxY", value: \.dt_maxY) { $0.dt_maxY }
    }

    var dtHypotenuseColumn: DTColumn {
        self.tableColumn(for: "dt_hypotenuse", value: \.dt_hypotenuse) { $0.dt_hypotenuse }
    }

    var dtAspectRatioColumn: DTColumn {
        self.tableColumn(for: "dt_aspectRatio", value: \.dt_aspectRatio) { $0.dt_aspectRatio }
    }

    var dtFillAmountColumn: DTColumn {
        self.tableColumn(for: "dt_fillAmount", value: \.dt_fillAmount) { $0.dt_fillAmount }
    }

    var dtSurfaceAreaRatioColumn: DTColumn {
        self.tableColumn(for: "dt_surfaceAreaRatio", value: \.dt_surfaceAreaRatio) { row in
            row.dt_surfaceAreaRatio
        }
    }

    var dtAveragebrightnessColumn: DTColumn {
        self.tableColumn(for: "dt_averagebrightness", value: \.dt_averagebrightness) { row in
            row.dt_averagebrightness
        }
    }

    var dtMedianBrightnessColumn: DTColumn {
        self.tableColumn(for: "dt_medianBrightness", value: \.dt_medianBrightness) { row in
            row.dt_medianBrightness
        }
    }

    var dtMaxBrightnessColumn: DTColumn {
        self.tableColumn(for: "dt_maxBrightness", value: \.dt_maxBrightness) { row in
            row.dt_maxBrightness
        }
    }

    var dtAvgCountOfFirst10HoughLinesColumn: DTColumn {
        self.tableColumn(for: "dt_avgCountOfFirst10HoughLines",
                         value: \.dt_avgCountOfFirst10HoughLines) { row in
            row.dt_avgCountOfFirst10HoughLines
        }
    }

    var dtMaxThetaDiffOfFirst10HoughLinesColumn: DTColumn {
        self.tableColumn(for: "dt_maxThetaDiffOfFirst10HoughLines",
                         value: \.dt_maxThetaDiffOfFirst10HoughLines) { row in
            row.dt_maxThetaDiffOfFirst10HoughLines
        }
    }

    var dtMaxRhoDiffOfFirst10HoughLinesColumn: DTColumn {
        self.tableColumn(for: "dt_maxRhoDiffOfFirst10HoughLines",
                         value: \.dt_maxRhoDiffOfFirst10HoughLines) { row in
            row.dt_maxRhoDiffOfFirst10HoughLines
        }
    }
    
    var dtNumberOfNearbyOutliersInSameFrameColumn: DTColumn {
        self.tableColumn(for: "dt_numberOfNearbyOutliersInSameFrame",
                         value: \.dt_numberOfNearbyOutliersInSameFrame) { row in
            row.dt_numberOfNearbyOutliersInSameFrame
        }
    }

    var dtAdjecentFrameNeighboringOutliersBestThetaColumn: DTColumn {
        self.tableColumn(for: "dt_adjecentFrameNeighboringOutliersBestTheta",
                         value: \.dt_adjecentFrameNeighboringOutliersBestTheta) { row in
            row.dt_adjecentFrameNeighboringOutliersBestTheta
        }
    }

    var dtHistogramStreakDetectionColumn: DTColumn {
        self.tableColumn(for: "dt_histogramStreakDetection",
                         value: \.dt_histogramStreakDetection) { row in
            row.dt_histogramStreakDetection
        }
    }

    var dtMaxHoughTransformCountColumn: DTColumn {
        self.tableColumn(for: "dt_maxHoughTransformCount",
                         value: \.dt_maxHoughTransformCount) { row in
            row.dt_maxHoughTransformCount
        }
    }

    var dtMaxHoughThetaColumn: DTColumn {
        self.tableColumn(for: "dt_maxHoughTheta",
                         value: \.dt_maxHoughTheta) { row in
            row.dt_maxHoughTheta
        }
    }

    var dtNeighboringInterFrameOutlierThetaScoreColumn: DTColumn {
        self.tableColumn(for: "dt_neighboringInterFrameOutlierThetaScore",
                         value: \.dt_neighboringInterFrameOutlierThetaScore) { row in
            row.dt_neighboringInterFrameOutlierThetaScore
        }
    }

    func tableColumn(for name: String,
                     value: KeyPath<OutlierGroupTableRow,Double>,
                     closure: @escaping (OutlierGroupTableRow) -> Double) -> DTColumn
    {
        TableColumn(name, value: value) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", closure(row)))
        }
    }
    
    @State var sortOrder: [KeyPathComparator<OutlierGroupTableRow>] = [
      .init(\.size, order: SortOrder.forward)
    ]
    @State private var selectedOutliers = Set<OutlierGroupTableRow.ID>()
    
    var body: some View {
        HStack {
            Spacer()
            VStack {
                Spacer()
                Text("Information about \(outlierGroupTableRows.count) outlier groups")
                Table(outlierGroupTableRows, selection: $selectedOutliers, sortOrder: $sortOrder) {
                    Group {
                        nameColumn
                        sizeColumn
                        dtSizeColumn
                        dtWidthColumn
                        dtHeightColumn
                        dtCenterXColumn
                        dtCenterYColumn
                        dtMinXColumn
                        dtMinYColumn
                        dtMaxXColumn
                    }
                    Group {
                        dtMaxYColumn
                        dtHypotenuseColumn
                        dtAspectRatioColumn
                        dtFillAmountColumn
                        dtSurfaceAreaRatioColumn
                        dtAveragebrightnessColumn
                        dtMedianBrightnessColumn
                        dtMaxBrightnessColumn
                        dtAvgCountOfFirst10HoughLinesColumn
                        dtMaxThetaDiffOfFirst10HoughLinesColumn
                    }
                    Group {
                        dtMaxRhoDiffOfFirst10HoughLinesColumn
                        dtNumberOfNearbyOutliersInSameFrameColumn
                        dtAdjecentFrameNeighboringOutliersBestThetaColumn
                        dtHistogramStreakDetectionColumn
                        dtMaxHoughTransformCountColumn
                        dtMaxHoughThetaColumn
                        dtNeighboringInterFrameOutlierThetaScoreColumn
                    }
                } .onChange(of: sortOrder) {
                    outlierGroupTableRows.sort(using: $0)
                }
                Button("Close") {
                    self.isVisible = false
                }
                Button("Copy to Clipboard") {
                    // XXX do a copy to clipboard here XXXx
                    self.isVisible = false
                }
                Spacer()
            }
            Spacer()
        }
    }
}

