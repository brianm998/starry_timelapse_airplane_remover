import SwiftUI
import StarCore
import logging

typealias DTColumn = TableColumn<OutlierGroupTableRow,
                                 KeyPathComparator<OutlierGroupTableRow>,
                                 Text,
                                 Text>

enum WillPaintType: Comparable {
    case willPaint
    case willNotPaint
    case unknown
}

struct OutlierGroupTableRow: Identifiable {
    let id = UUID()
    
    let name: UInt16
    let size: UInt
    let willPaint: Bool?
    let centerX: Int
    let centerY: Int
    
    var willPaintType: WillPaintType {
        if let willPaint = willPaint {
            if willPaint {
                return .willPaint
            } else {
                return .willNotPaint
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

    init(_ group: OutlierGroup) async {
        name = group.id
        size = group.size
        centerX = group.bounds.center.x
        centerY = group.bounds.center.y
        let centerY: Int

        let shouldPaint = await group.shouldPaint()
        if let shouldPaint = shouldPaint {
            willPaint = shouldPaint.willPaint
        } else {
            willPaint = nil
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
    }
}

struct OutlierGroupTable: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    var closure: () -> Void

    var nameColumn: DTColumn {
        TableColumn("id", value: \.id) { (row: OutlierGroupTableRow) in
            Text(String(row.name))
        }.width(min: 40, ideal: 60, max: 100)
    }
    
    var sizeColumn: DTColumn {
        TableColumn("size", value: \.size) { (row: OutlierGroupTableRow) in
            Text(String(row.size))
        }.width(min: 30, ideal: 40, max: 80)
    }

    var xColumn: DTColumn {
        TableColumn("X", value: \.centerX) { (row: OutlierGroupTableRow) in
            Text(String(row.centerX))
        }.width(min: 30, ideal: 40, max: 80)
    }

    var yColumn: DTColumn {
        TableColumn("Y", value: \.centerY) { (row: OutlierGroupTableRow) in
            Text(String(row.centerY))
        }.width(min: 30, ideal: 40, max: 80)
    }

    func image(for type: WillPaintType) -> Image {
        switch type {
        case .willPaint:
            return Image(systemName: "paintbrush")
        case .willNotPaint:
            return Image(systemName: "xmark.seal")
        case .unknown:
            return Image(systemName: "camera.metering.unknown")
        }
    }
    
    var willPaintColumn: TableColumn<OutlierGroupTableRow,
                                     KeyPathComparator<OutlierGroupTableRow>,
                                     Image,
                                     Text> {
        TableColumn("paint",
                    value: \OutlierGroupTableRow.willPaintType) { (row: OutlierGroupTableRow) in
            image(for: row.willPaintType)
        }.width(min: 10, ideal: 20, max: 40)
    }
    
    // add paint reason
    
    var dtSizeColumn: DTColumn {
        self.tableColumn(for: "size", value: \.dt_size) { $0.dt_size }
    }
    
    var dtWidthColumn: DTColumn {
        self.tableColumn(for: "width", value: \.dt_width) { $0.dt_width }
    }
    
    var dtHeightColumn: DTColumn {
        self.tableColumn(for: "height", value: \.dt_height) { $0.dt_height }
    }

    var dtCenterXColumn: DTColumn {
        self.tableColumn(for: "centerX", value: \.dt_centerX) { $0.dt_centerX }
    }

    var dtCenterYColumn: DTColumn {
        self.tableColumn(for: "centerY", value: \.dt_centerY) { $0.dt_centerY }
    }

    var dtMinXColumn: DTColumn {
        self.tableColumn(for: "minX", value: \.dt_minX) { $0.dt_minX }
    }

    var dtMinYColumn: DTColumn {
        self.tableColumn(for: "minY", value: \.dt_minY) { $0.dt_minY }
    }

    var dtMaxXColumn: DTColumn {
        self.tableColumn(for: "maxX", value: \.dt_maxX) { $0.dt_maxX }
    }

    var dtMaxYColumn: DTColumn {
        self.tableColumn(for: "maxY", value: \.dt_maxY) { $0.dt_maxY }
    }

    var dtHypotenuseColumn: DTColumn {
        self.tableColumn(for: "hypotenuse", value: \.dt_hypotenuse) { $0.dt_hypotenuse }
    }

    var dtAspectRatioColumn: DTColumn {
        self.tableColumn(for: "aspectRatio", value: \.dt_aspectRatio) { $0.dt_aspectRatio }
    }

    var dtFillAmountColumn: DTColumn {
        self.tableColumn(for: "fillAmount", value: \.dt_fillAmount) { $0.dt_fillAmount }
    }

    var dtSurfaceAreaRatioColumn: DTColumn {
        self.tableColumn(for: "surfaceAreaRatio", value: \.dt_surfaceAreaRatio) { row in
            row.dt_surfaceAreaRatio
        }
    }


//    private func unSixteenBitVersion(ofPercentage percentage: Double) -> Double {
//        return (percentage/Double(0xFFFF))*100
        //return UInt16((percentage/100)*Double(0xFFFF))
//    }
    

    
    var dtAveragebrightnessColumn: DTColumn {
        self.tableColumn(for: "averagebrightness", value: \.dt_averagebrightness) { row in
            row.dt_averagebrightness
        }
    }

    var dtMedianBrightnessColumn: DTColumn {
        self.tableColumn(for: "medianBrightness", value: \.dt_medianBrightness) { row in
            row.dt_medianBrightness
        }
    }

    var dtMaxBrightnessColumn: DTColumn {
        self.tableColumn(for: "maxBrightness", value: \.dt_maxBrightness) { row in
            row.dt_maxBrightness
        }
    }

    var dtNumberOfNearbyOutliersInSameFrameColumn: DTColumn {
        self.tableColumn(for: "numberOfNearbyOutliersInSameFrame",
                         value: \.dt_numberOfNearbyOutliersInSameFrame) { row in
            row.dt_numberOfNearbyOutliersInSameFrame
        }
    }

    var dtMaxHoughTransformCountColumn: DTColumn {
        self.tableColumn(for: "maxHoughTransformCount",
                         value: \.dt_maxHoughTransformCount) { row in
            row.dt_maxHoughTransformCount
        }
    }

    var dtPixelBorderAmount: DTColumn {
        self.tableColumn(for: "pixelBorderAmount",
                         value: \.dt_pixelBorderAmount) { row in
            row.dt_pixelBorderAmount
        }
    }

    var dtAverageLineVariance: DTColumn {
        self.tableColumn(for: "averageLineVariance",
                         value: \.dt_averageLineVariance) { row in
            row.dt_averageLineVariance
        }
    }
    
    var dtLineLength: DTColumn {
        self.tableColumn(for: "lineLength",
                         value: \.dt_lineLength) { row in
            row.dt_lineLength
        }
    }
    
    func tableColumn(for name: String,
                     value: KeyPath<OutlierGroupTableRow,Double>,
                     closure: @escaping (OutlierGroupTableRow) -> Double) -> DTColumn
    {
        TableColumn(name, value: value) { (row: OutlierGroupTableRow) in
            Text(String(format: "%.5g", closure(row)))
        }.width(min: 40, ideal: 60, max: 100)
    }

    @State var sortOrder: [KeyPathComparator<OutlierGroupTableRow>] = [
      .init(\.size, order: SortOrder.forward)
    ]

    var body: some View {

//        let displayDtSizeColumn = viewModel.outlierGroupTableDisplayGroups[.size] ?? true
        //let displayDtSizeColumn = true
      @Bindable var viewModel = viewModel

            return
        HStack {
            Spacer()
            VStack {
                Spacer()
                Text("Information about \(viewModel.outlierGroupTableRows.count) outlier groups")
                Table(viewModel.outlierGroupTableRows,
                      selection: $viewModel.selectedOutliers,
                      sortOrder: $sortOrder)
                {
                    // current compiler can't take more than 10 columns at once here
                    Group {
                        nameColumn
                        willPaintColumn
                        self.sizeColumn
                        //dtSizeColumn
                        //dtWidthColumn
                        //dtHeightColumn
                    }

                    Group {
//                        if displayDtSizeColumn {
                        //            }
                        xColumn
                        yColumn
                        //dtCenterXColumn
                        //dtCenterYColumn
                        //dtMinXColumn
                        //dtMinYColumn
                        //dtMaxXColumn
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
                    }
                    Group {
                        dtNumberOfNearbyOutliersInSameFrameColumn
                        dtPixelBorderAmount
                    }
                    Group {
                        dtAverageLineVariance
                        dtLineLength
                    }

                } .onChange(of: viewModel.selectedOutliers) {newValue in 
                    Log.d("selected outliers \(newValue)")
                    if let frame = viewModel.outlierGroupWindowFrame {
                        let frameView = viewModel.frames[frame.frameIndex]
                        if let outlierViews = frameView.outlierViews {

                            for outlierView in outlierViews {
                                outlierView.isSelected = false
                            }
                            
                            //var outlier_is_selected = false
                            for value in newValue {
                                if let row = viewModel.outlierGroupTableRows.first(where: { $0.id == value }) {
                                    Log.d("selected row \(row.name)")
                                    for outlierView in outlierViews {
                                        if outlierView.name == row.name {
                                            // set this outlier view to selected
                                            Log.d("outlier \(outlierView.name) is selected)")
                                            outlierView.isSelected = true
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

