import SwiftUI
import StarCore
import logging

typealias DTColumn = TableColumn<OutlierGroupTableRow,
                                 KeyPathComparator<OutlierGroupTableRow>,
                                 Text,
                                 Text>

enum WillRemoveType: Comparable {
    case willRemove
    case keep
    case unknown
}

struct OutlierGroupTableRow: Identifiable {
  
    let id = UUID()
    
    let name: UInt16
    let size: UInt
    let willRemove: Bool?
    let centerX: Int
    let centerY: Int
    
    var willRemoveType: WillRemoveType {
        if let willRemove = willRemove {
            if willRemove {
                return .willRemove
            } else {
                return .keep
            }
        } else {
            return .unknown
        }
    }
    
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
    let dt_numberOfNearbyOutliersInSameFrame: Double
    let dt_maxHoughTransformCount: Double
    let dt_pixelBorderAmount: Double
    let dt_averageLineVariance: Double
    let dt_lineLength: Double

    let dt_nearbyDirectOverlapScore: Double
    let dt_boundingBoxOverlapScore: Double
    let dt_lineFillAmount: Double
    let dt_borderBrightness : Double

    let dt_bunchCount : Double
    let dt_medianBunchSize : Double
    let dt_maxBunchSize : Double

    let dt_neighborLineThetaScore: Double
    let dt_neighborLineRhoScore: Double
    let dt_neighborLineSizeScore: Double
    let dt_neighborLineBrightnessScore: Double
    let dt_neighborLineDistanceScore: Double

    let dt_classificationScore: Double
    
    init(_ group: OutlierGroup) async {
        name = group.id
        size = group.size
        centerX = group.bounds.center.x
        centerY = group.bounds.center.y

        let shouldPaint = await group.shouldPaint()
        if let shouldPaint = shouldPaint {
            willRemove = shouldPaint.willRemove
        } else {
            willRemove = nil
        }

        dt_size = await group.decisionTreeValueAsync(for: .size)
        dt_width = await group.decisionTreeValueAsync(for: .width)
        dt_height = await group.decisionTreeValueAsync(for: .height)
        dt_centerX = await group.decisionTreeValueAsync(for: .centerX)
        dt_centerY = await group.decisionTreeValueAsync(for: .centerY)
        dt_minX = await group.decisionTreeValueAsync(for: .minX)
        dt_minY = await group.decisionTreeValueAsync(for: .minY)
        dt_maxX = await group.decisionTreeValueAsync(for: .maxX)
        dt_maxY = await group.decisionTreeValueAsync(for: .maxY)
        dt_hypotenuse = await group.decisionTreeValueAsync(for: .hypotenuse)
        dt_aspectRatio = await group.decisionTreeValueAsync(for: .aspectRatio)
        dt_fillAmount = await group.decisionTreeValueAsync(for: .fillAmount)
        dt_surfaceAreaRatio = await group.decisionTreeValueAsync(for: .surfaceAreaRatio)
        dt_averagebrightness = await group.decisionTreeValueAsync(for: .averagebrightness)
        dt_medianBrightness = await group.decisionTreeValueAsync(for: .medianBrightness)
        dt_maxBrightness = await group.decisionTreeValueAsync(for: .maxBrightness)
        dt_numberOfNearbyOutliersInSameFrame = await group.decisionTreeValueAsync(for: .numberOfNearbyOutliersInSameFrame)

        dt_maxHoughTransformCount = await group.decisionTreeValueAsync(for: .maxHoughTransformCount)

        dt_pixelBorderAmount = await group.decisionTreeValueAsync(for: .pixelBorderAmount)
        dt_averageLineVariance = await group.decisionTreeValueAsync(for: .averageLineVariance)
        dt_lineLength = await group.decisionTreeValueAsync(for: .lineLength)

        dt_nearbyDirectOverlapScore = await group.decisionTreeValueAsync(for: .nearbyDirectOverlapScore)
        dt_boundingBoxOverlapScore = await group.decisionTreeValueAsync(for: .boundingBoxOverlapScore)
        dt_lineFillAmount = await group.decisionTreeValueAsync(for: .lineFillAmount)
        dt_borderBrightness = await group.decisionTreeValueAsync(for: .borderBrightness)

        dt_bunchCount = await group.decisionTreeValueAsync(for: .bunchCount)
        dt_medianBunchSize = await group.decisionTreeValueAsync(for: .medianBunchSize)
        dt_maxBunchSize = await group.decisionTreeValueAsync(for: .maxBunchSize)
        dt_neighborLineThetaScore = await group.decisionTreeValueAsync(for: .neighborLineThetaScore)
        dt_neighborLineRhoScore = await group.decisionTreeValueAsync(for: .neighborLineRhoScore)
        dt_neighborLineSizeScore = await group.decisionTreeValueAsync(for: .neighborLineSizeScore)
        dt_neighborLineBrightnessScore = await group.decisionTreeValueAsync(for: .neighborLineBrightnessScore)
        dt_neighborLineDistanceScore = await group.decisionTreeValueAsync(for: .neighborLineDistanceScore)
        dt_classificationScore = await classification(of: group)
    }
}

func classification(of group: OutlierGroup) async -> Double {
    guard let classifier = await currentClassifier.get(for: .all) else { return 0 }
    return await classifier.classification(of: group)
}

struct OutlierGroupTable: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    @Environment(OutlierWindowViewModel.self) var outlierWindowViewModel: OutlierWindowViewModel

    var closure: () -> Void

    public init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }

    var nameColumn: DTColumn {
        TableColumn("id", value: \.id) { (row: OutlierGroupTableRow) in
            Text(String(row.name))
        }.width(min: 40, ideal: 60, max: 100)
    }
    
    var sizeColumn: DTColumn {
        TableColumn("size", value: \.size) { (row: OutlierGroupTableRow) in
            Text(String(row.size))
        }.width(min: 40, ideal: 40, max: 80)
    }

    var xColumn: DTColumn {
        TableColumn("X", value: \.centerX) { (row: OutlierGroupTableRow) in
            Text(String(row.centerX))
        }//}.width(min: 30, ideal: 40, max: 80)
    }

    var yColumn: DTColumn {
        TableColumn("Y", value: \.centerY) { (row: OutlierGroupTableRow) in
            Text(String(row.centerY))
        }//}.width(min: 30, ideal: 40, max: 80)
    }

    func image(for type: WillRemoveType) -> Image {
        switch type {
        case .willRemove:
            return Image(systemName: "paintbrush")
        case .keep:
            return Image(systemName: "xmark.seal")
        case .unknown:
            return Image(systemName: "camera.metering.unknown")
        }
    }
    
    var willRemoveColumn: TableColumn<OutlierGroupTableRow,
                                     KeyPathComparator<OutlierGroupTableRow>,
                                     Image,
                                     Text> {
        TableColumn("paint",
                    value: \OutlierGroupTableRow.willRemoveType) { (row: OutlierGroupTableRow) in
            image(for: row.willRemoveType)
        }.width(min: 10, ideal: 20, max: 80)
    }
    
    // add paint reason

    func tableColumn(for name: String,
                     value: KeyPath<OutlierGroupTableRow,Double>,
                     closure: @escaping (OutlierGroupTableRow) -> Double) -> DTColumn
    {
        TableColumn(name, value: value) { (row: OutlierGroupTableRow) in
            Text(String(format: "%.5g", closure(row)))
        }//}.width(min: 40, ideal: 60, max: 100)
    }

    @State var sortOrder: [KeyPathComparator<OutlierGroupTableRow>] = [
      .init(\.size, order: SortOrder.forward)
    ]

    var body: some View {
        @Bindable var viewModel = viewModel

        return ZStack {
            if let viewModel = viewModel.imageSequence {
                self.mainView(viewModel)
                //        let displayDtSizeColumn = viewModel.outlierGroupTableDisplayGroups[.size] ?? true
                //let displayDtSizeColumn = true
            } else {
                VStack {
                    Text("No Image sequence loaded.")
                    Text("Load an image sequence in the main star window, and then select details for some outlier groups to see their data here.")
                }
            }
        }
    }

    func mainView(_ viewModel: ImageSequenceViewModel) -> some View {
        @Bindable var viewModel = viewModel
        return HStack {
            Spacer()
            VStack {
                Spacer()
                Text("Information about \(viewModel.outlierGroupTableRows.count) outlier groups")
                Table(viewModel.outlierGroupTableRows,
                      selection: $viewModel.selectedOutliers,
                      sortOrder: $sortOrder)
                {
                    // current compiler can't take more than 10 columns at once here

                    if self.outlierWindowViewModel.showName { nameColumn }
                    willRemoveColumn
                    self.sizeColumn

    // not used now, it's ugly being scaled w/ image size, we show actual pixels in gui
//    var dtSizeColumn: DTColumn {
//        self.tableColumn(for: "size", value: \.dt_size) { $0.dt_size }
//    }
    
                    Group {
                        if self.outlierWindowViewModel.showWidth {
                            self.tableColumn(for: "width", value: \.dt_width) { $0.dt_width }
                        }

                        if self.outlierWindowViewModel.showHeight {
                            self.tableColumn(for: "height", value: \.dt_height) { $0.dt_height }
                        }
                        
                        if self.outlierWindowViewModel.showCenterX {
                            self.tableColumn(for: "centerX", value: \.dt_centerX) { $0.dt_centerX }
                        }
                        if self.outlierWindowViewModel.showCenterY {
                            //yColumn
                            self.tableColumn(for: "centerY", value: \.dt_centerY) { $0.dt_centerY }
                        }

                    }

                    Group {
                        if self.outlierWindowViewModel.showMinX {
                            self.tableColumn(for: "minX", value: \.dt_minX) { $0.dt_minX }
                        }
                        if self.outlierWindowViewModel.showMinY {
                            self.tableColumn(for: "minY", value: \.dt_minY) { $0.dt_minY }
                        }
                        if self.outlierWindowViewModel.showMaxX {
                            self.tableColumn(for: "maxX", value: \.dt_maxX) { $0.dt_maxX }
                        }
                        if self.outlierWindowViewModel.showMaxY {
                            self.tableColumn(for: "maxY", value: \.dt_maxY) { $0.dt_maxY }
                        }

                        if self.outlierWindowViewModel.showHypotenuse {
                            self.tableColumn(for: "hypotenuse", value: \.dt_hypotenuse) { $0.dt_hypotenuse }
                        }

                        if self.outlierWindowViewModel.showAspectRatio {
                            self.tableColumn(for: "aspectRatio", value: \.dt_aspectRatio) { $0.dt_aspectRatio }
                        }
                        if self.outlierWindowViewModel.showFillAmount {
                            self.tableColumn(for: "fillAmount", value: \.dt_fillAmount) { $0.dt_fillAmount }
                        }
                        if self.outlierWindowViewModel.showSurfaceAreaRatio {
                            self.tableColumn(for: "surfaceAreaRatio", value: \.dt_surfaceAreaRatio) { row in
                                row.dt_surfaceAreaRatio
                            }
                        }
                        if self.outlierWindowViewModel.showAveragebrightness {
                            self.tableColumn(for: "averagebrightness", value: \.dt_averagebrightness) { row in
                                row.dt_averagebrightness
                            }
                        }
                    }
                    Group {
                        if self.outlierWindowViewModel.showMedianBrightness {
                            self.tableColumn(for: "medianBrightness", value: \.dt_medianBrightness) { row in
                                row.dt_medianBrightness
                            }
                        }

                        if self.outlierWindowViewModel.showMaxBrightness {
                            self.tableColumn(for: "maxBrightness", value: \.dt_maxBrightness) { row in
                                row.dt_maxBrightness
                            }
                        }
                        if self.outlierWindowViewModel.showNumberOfNearbyOutliersInSameFrame {
                            self.tableColumn(for: "numberOfNearbyOutliersInSameFrame",
                                             value: \.dt_numberOfNearbyOutliersInSameFrame) { row in
                                row.dt_numberOfNearbyOutliersInSameFrame
                            }
                        }
                        if self.outlierWindowViewModel.showMaxHoughTransformCount {
                            self.tableColumn(for: "maxHoughTransformCount",
                                             value: \.dt_maxHoughTransformCount) { row in
                                row.dt_maxHoughTransformCount
                            }
                        }
                        if self.outlierWindowViewModel.showPixelBorderAmount {
                            self.tableColumn(for: "pixelBorderAmount",
                                             value: \.dt_pixelBorderAmount) { row in
                                row.dt_pixelBorderAmount
                            }
                        }
                        if self.outlierWindowViewModel.showAverageLineVariance {
                            self.tableColumn(for: "averageLineVariance",
                                             value: \.dt_averageLineVariance) { row in
                                row.dt_averageLineVariance
                            }
                        }
                        if self.outlierWindowViewModel.showLineLength {
                            self.tableColumn(for: "lineLength",
                                             value: \.dt_lineLength) { row in
                                row.dt_lineLength
                            }
                        }
                        if self.outlierWindowViewModel.showNearbyDirectOverlapScore {
                            self.tableColumn(for: "nearbyDirectOverlapScore",
                                             value: \.dt_nearbyDirectOverlapScore) { row in
                                row.dt_nearbyDirectOverlapScore
                            }
                        }
                    }
                    Group {
                        if self.outlierWindowViewModel.showBoundingBoxOverlapScore {
                            self.tableColumn(for: "boundingBoxOverlapScore",
                                             value: \.dt_boundingBoxOverlapScore) { row in
                                row.dt_boundingBoxOverlapScore
                            }
                        }
                        if self.outlierWindowViewModel.showLineFillAmount {
                            self.tableColumn(for: "lineFillAmount",
                                             value: \.dt_lineFillAmount) { row in
                                row.dt_lineFillAmount
                            }
                        }
                        if self.outlierWindowViewModel.showBorderBrightness {
                            self.tableColumn(for: "borderBrightness",
                                             value: \.dt_borderBrightness) { row in
                                row.dt_borderBrightness
                            }
                        }
                        if self.outlierWindowViewModel.showBunchCount {
                            self.tableColumn(for: "bunchCount",
                                             value: \.dt_bunchCount) { row in
                                row.dt_bunchCount
                            }
                        }
                        if self.outlierWindowViewModel.showMedianBunchSize {
                            self.tableColumn(for: "medianBunchSize",
                                             value: \.dt_medianBunchSize) { row in
                                row.dt_medianBunchSize
                            }
                        }
                        if self.outlierWindowViewModel.showMaxBunchSize {
                            self.tableColumn(for: "maxBunchSize",
                                             value: \.dt_maxBunchSize) { row in
                                row.dt_maxBunchSize
                            }
                        }
                    }
                    Group {
                        if self.outlierWindowViewModel.showNeighborLineThetaScore {
                            self.tableColumn(for: "neighborLineThetaScore",
                                             value: \.dt_neighborLineThetaScore) { row in
                                row.dt_neighborLineThetaScore
                            }
                        }
                        if self.outlierWindowViewModel.showNeighborLineRhoScore {
                            self.tableColumn(for: "neighborLineRhoScore",
                                             value: \.dt_neighborLineRhoScore) { row in
                                row.dt_neighborLineRhoScore
                            }
                        }
                        if self.outlierWindowViewModel.showNeighborLineSizeScore {
                            self.tableColumn(for: "neighborLineSizeScore",
                                             value: \.dt_neighborLineSizeScore) { row in
                                row.dt_neighborLineSizeScore
                            }
                        }
                        if self.outlierWindowViewModel.showNeighborLineBrightnessScore {
                            self.tableColumn(for: "neighborLineBrightnessScore",
                                             value: \.dt_neighborLineBrightnessScore) { row in
                                row.dt_neighborLineBrightnessScore
                            }
                        }
                        if self.outlierWindowViewModel.showNeighborLineDistanceScore {
                            self.tableColumn(for: "neighborLineDistanceScore",
                                             value: \.dt_neighborLineDistanceScore) { row in
                                row.dt_neighborLineDistanceScore
                            }
                            
                        }
                        if self.outlierWindowViewModel.showClassificationScore {
                            self.tableColumn(for: "classificationScore",
                                             value: \.dt_classificationScore) { row in
                                row.dt_classificationScore
                            }
                        }
                    }
                } .onChange(of: viewModel.selectedOutliers) {newValue in 
                    Log.d("selected outliers \(newValue)")
                    Task { await outlierWindowViewModel.loadLineInfo() }
                    if let frame = viewModel.outlierGroupWindowFrame {
                        let frameView = viewModel.frames[frame.frameIndex]
                        if let outlierViews = frameView.outlierViews {

                            for outlierView in outlierViews {
                                outlierView.isSelected = false
                            }
                            outlierWindowViewModel.selectedOutliers = []
                            
                            //var outlier_is_selected = false
                            for value in newValue {
                                if let row = viewModel.outlierGroupTableRows.first(where: { $0.id == value }) {
                                    Log.d("selected row \(row.name)")
                                    for outlierView in outlierViews {
                                        if outlierView.name == row.name {
                                            // set this outlier view to selected
                                            Log.d("outlier \(outlierView.name) is selected)")
                                            outlierView.isSelected = true

                                            outlierWindowViewModel.selectedOutliers.append(outlierView.group)
                                            break
                                        }
                                    }
                                }
                            }
                        } else {
                            Log.w("no frame")
                        }
                    }
                } .onChange(of: sortOrder) {
                    viewModel.outlierGroupTableRows.sort(using: $0)
                } .onDisappear() {
                    // without this selection will persist 
                    if let frame = viewModel.outlierGroupWindowFrame {
                        let frameView = viewModel.frames[frame.frameIndex]
                        if let outlierViews = frameView.outlierViews {
                            for outlierView in outlierViews {
                                outlierView.isSelected = false
                            }
                        }
                    }
                }
                
                Spacer()
            }
            Spacer()
        }.navigationTitle(viewModel.outlierGroupWindowFrame == nil ?
                                  OTHER_WINDOW_TITLE :
                                  "\(OUTLIER_WINDOW_PREFIX) for frame \(viewModel.outlierGroupWindowFrame!.frameIndex)")
    }

}

