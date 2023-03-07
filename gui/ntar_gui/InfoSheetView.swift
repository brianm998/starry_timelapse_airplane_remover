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

    var dtSizeColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_size", value: \OutlierGroupTableRow.dt_size) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_size))
        }
    }

    var dtWidthColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_width", value: \OutlierGroupTableRow.dt_width) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_width))
        }
    }

    var dtHeightColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_height", value: \OutlierGroupTableRow.dt_height) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_height))
        }
    }

    var dtCenterXColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_centerX", value: \OutlierGroupTableRow.dt_centerX) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_centerX))
        }
    }

    var dtCenterYColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_centerY", value: \OutlierGroupTableRow.dt_centerY) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_centerY))
        }
    }

    var dtMinXColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_minX", value: \OutlierGroupTableRow.dt_minX) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_minX))
        }
    }

    var dtMinYColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_minY", value: \OutlierGroupTableRow.dt_minY) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_minY))
        }
    }

    var dtMaxXColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_maxX", value: \OutlierGroupTableRow.dt_maxX) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_maxX))
        }
    }

    var dtMaxYColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_maxY", value: \OutlierGroupTableRow.dt_maxY) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_maxY))
        }
    }

    var dtHypotenuseColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_hypotenuse", value: \OutlierGroupTableRow.dt_hypotenuse) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_hypotenuse))
        }
    }

    var dtAspectRatioColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_aspectRatio", value: \OutlierGroupTableRow.dt_aspectRatio) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_aspectRatio))
        }
    }

    var dtFillAmountColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_fillAmount", value: \OutlierGroupTableRow.dt_fillAmount) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_fillAmount))
        }
    }

    var dtSurfaceAreaRatioColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_surfaceAreaRatio", value: \OutlierGroupTableRow.dt_surfaceAreaRatio) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_surfaceAreaRatio))
        }
    }

    var dtAveragebrightnessColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_averagebrightness", value: \OutlierGroupTableRow.dt_averagebrightness) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_averagebrightness))
        }
    }

    var dtMedianBrightnessColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_medianBrightness", value: \OutlierGroupTableRow.dt_medianBrightness) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_medianBrightness))
        }
    }

    var dtMaxBrightnessColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_maxBrightness", value: \OutlierGroupTableRow.dt_maxBrightness) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_maxBrightness))
        }
    }

    var dtAvgCountOfFirst10HoughLinesColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_avgCountOfFirst10HoughLines", value: \OutlierGroupTableRow.dt_avgCountOfFirst10HoughLines) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_avgCountOfFirst10HoughLines))
        }
    }

    var dtMaxThetaDiffOfFirst10HoughLinesColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_maxThetaDiffOfFirst10HoughLines", value: \OutlierGroupTableRow.dt_maxThetaDiffOfFirst10HoughLines) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_maxThetaDiffOfFirst10HoughLines))
        }
    }

    var dtMaxRhoDiffOfFirst10HoughLinesColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_maxRhoDiffOfFirst10HoughLines", value: \OutlierGroupTableRow.dt_maxRhoDiffOfFirst10HoughLines) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_maxRhoDiffOfFirst10HoughLines))
        }
    }

    var dtNumberOfNearbyOutliersInSameFrameColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_numberOfNearbyOutliersInSameFrame", value: \OutlierGroupTableRow.dt_numberOfNearbyOutliersInSameFrame) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_numberOfNearbyOutliersInSameFrame))
        }
    }

    var dtAdjecentFrameNeighboringOutliersBestThetaColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_adjecentFrameNeighboringOutliersBestTheta", value: \OutlierGroupTableRow.dt_adjecentFrameNeighboringOutliersBestTheta) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_adjecentFrameNeighboringOutliersBestTheta))
        }
    }

    var dtHistogramStreakDetectionColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_histogramStreakDetection", value: \OutlierGroupTableRow.dt_histogramStreakDetection) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_histogramStreakDetection))
        }
    }

    var dtMaxHoughTransformCountColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_maxHoughTransformCount", value: \OutlierGroupTableRow.dt_maxHoughTransformCount) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_maxHoughTransformCount))
        }
    }

    var dtMaxHoughThetaColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_maxHoughTheta", value: \OutlierGroupTableRow.dt_maxHoughTheta) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_maxHoughTheta))
        }
    }

    var dtNeighboringInterFrameOutlierThetaScoreColumn: TableColumn<OutlierGroupTableRow,
                                  KeyPathComparator<OutlierGroupTableRow>,
                                  Text,
                                  Text>
    {
        TableColumn("dt_neighboringInterFrameOutlierThetaScore", value: \OutlierGroupTableRow.dt_neighboringInterFrameOutlierThetaScore) { (row: OutlierGroupTableRow) in
            Text(String(format: "%3g", row.dt_neighboringInterFrameOutlierThetaScore))
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

