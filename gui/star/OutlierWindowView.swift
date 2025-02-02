import SwiftUI
import KHTSwift
import StarCore
import logging

struct OutlierWindowView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    let outlierWindowViewModel = OutlierWindowViewModel()

    var body: some View {
        VStack {
            HStack {
                Spacer()
                OutlierGroupTable() { }
                  .environment(outlierWindowViewModel)
                Spacer()
                tableControls
                  .environment(outlierWindowViewModel)
            }
            HStack {
                Spacer()
                // put view for hough lines here
                if outlierWindowViewModel.selectedOutliers.count == 0 {
                    Text("Select some outliers") 
                } else if outlierWindowViewModel.selectedOutliers.count == 1 {
                    VStack {
                        Text("Hough Lines for the selected outlier")
                        Text("select a line to see it on the main window,")
                        Text("or update the line parameters to see any potential differences.")

                        HoughLinesTableView()
                          .environment(outlierWindowViewModel)
                    }
                } else {
                    Text("\(outlierWindowViewModel.selectedOutliers.count) outliers selected") 
                }
                Spacer()
                houghLineArgs
            }
        }
    }

    var houghLineArgs: some View {
        Group {
            if let houghLineFinderArgs = outlierWindowViewModel.houghLineFinderArgs {
                ArgableView(title: "Hough Line Arguments",
                            description: """
                              Arguments for the hough line finder.
                              Updating values here will generate new lines with the new values.
                              """,
                            args: houghLineFinderArgs,
                            array: HoughLineFinder.Args.ArgType.allCases)
                  .environment(outlierWindowViewModel)
            } else {
                Text("Loading Args")
            }
        }
    }
    
    var tableControls: some View {
        Group {
            if outlierWindowViewModel.isSidePanelShowing {
                openTableControls
            } else {
                closedTableControls
            }
        }
    }

    var closedTableControls: some View {
        @Bindable var outlierWindowViewModel = outlierWindowViewModel
        return
          VStack(alignment: .leading) {
              HStack(alignment: .top) {
                  Button() {
                      outlierWindowViewModel.isSidePanelShowing = true
                  } label: {
                      Image(systemName: "chevron.left.2")
                        .foregroundColor(.gray)
                  }
                    .buttonStyle(PlainButtonStyle())
              }
              Spacer()
          }
    }

    var openTableControls: some View {
            
        @Bindable var outlierWindowViewModel = outlierWindowViewModel
        return ScrollView {
            VStack(alignment: .leading) {
                HStack {
                    Button() {
                        outlierWindowViewModel.isSidePanelShowing = false
                    } label: {
                        Image(systemName: "chevron.right.2")
                          .foregroundColor(.gray)
                    }
                      .buttonStyle(PlainButtonStyle())

                    
                    Text("Select which columns to show")
                }
                HStack {
                    Button() {
                        outlierWindowViewModel.selectAll()
                    } label: {
                        Text("Select All")
                          .buttonStyle(ShrinkingButton())
                    }

                    Button() {
                        outlierWindowViewModel.clearAll()
                    } label: {
                        Text("Clear All")
                          .buttonStyle(ShrinkingButton())
                    }
                }
                
                Toggle("Name", isOn: $outlierWindowViewModel.showName)
                Toggle("CenterX", isOn: $outlierWindowViewModel.showCenterX)
                Toggle("CenterY", isOn: $outlierWindowViewModel.showCenterY)
                Toggle("Width", isOn: $outlierWindowViewModel.showWidth)
                Toggle("Height", isOn: $outlierWindowViewModel.showHeight)
                Toggle("MinX", isOn: $outlierWindowViewModel.showMinX)
                Toggle("MinY", isOn: $outlierWindowViewModel.showMinY)
                Toggle("MaxX", isOn: $outlierWindowViewModel.showMaxX)
                Toggle("MaxY", isOn: $outlierWindowViewModel.showMaxY)
                Toggle("Hypotenuse", isOn: $outlierWindowViewModel.showHypotenuse)
                Toggle("AspectRatio", isOn: $outlierWindowViewModel.showAspectRatio)
                Toggle("FillAmount", isOn: $outlierWindowViewModel.showFillAmount)
                Toggle("SurfaceAreaRatio", isOn: $outlierWindowViewModel.showSurfaceAreaRatio)
                Toggle("Averagebrightness", isOn: $outlierWindowViewModel.showAveragebrightness)
                Toggle("MedianBrightness", isOn: $outlierWindowViewModel.showMedianBrightness)
                Toggle("MaxBrightness", isOn: $outlierWindowViewModel.showMaxBrightness)
                Toggle("NumberOfNearbyOutliersInSameFrame",
                       isOn: $outlierWindowViewModel.showNumberOfNearbyOutliersInSameFrame)
                Toggle("MaxHoughTransformCount", isOn: $outlierWindowViewModel.showMaxHoughTransformCount)
                Toggle("PixelBorderAmount", isOn: $outlierWindowViewModel.showPixelBorderAmount)
                Toggle("AverageLineVariance", isOn: $outlierWindowViewModel.showAverageLineVariance)
                Toggle("LineLength", isOn: $outlierWindowViewModel.showLineLength)
                Toggle("NearbyDirectOverlapScore", isOn: $outlierWindowViewModel.showNearbyDirectOverlapScore)
                Toggle("BoundingBoxOverlapScore", isOn: $outlierWindowViewModel.showBoundingBoxOverlapScore)
                Toggle("LineFillAmount", isOn: $outlierWindowViewModel.showLineFillAmount)
                Toggle("BorderBrightness", isOn: $outlierWindowViewModel.showBorderBrightness)
                Toggle("BunchCount", isOn: $outlierWindowViewModel.showBunchCount)
                Toggle("MedianBunchSize", isOn: $outlierWindowViewModel.showMedianBunchSize)
                Toggle("MaxBunchSize", isOn: $outlierWindowViewModel.showMaxBunchSize)
                Toggle("NeighborLineThetaScore", isOn: $outlierWindowViewModel.showNeighborLineThetaScore)
                Toggle("NeighborLineRhoScore", isOn: $outlierWindowViewModel.showNeighborLineRhoScore)
                Toggle("NeighborLineSizeScore", isOn: $outlierWindowViewModel.showNeighborLineSizeScore)
                Toggle("NeighborLineBrightnessScore", isOn: $outlierWindowViewModel.showNeighborLineBrightnessScore)
                Toggle("NeighborLineDistanceScore", isOn: $outlierWindowViewModel.showNeighborLineDistanceScore)
                Toggle("NeighborLineDistanceScore", isOn: $outlierWindowViewModel.showClassificationScore)
            }
        }
    }
}

// XXX STICK THIS VVV IN A NEW FILE

struct ArgableView<T: Hashable>: View {
    let title: String
    let description: String
    let args: any Argable<T>
    let array: [T]

    @Environment(OutlierWindowViewModel.self) var outlierWindowViewModel: OutlierWindowViewModel
    
    public init(title: String,
                description: String,
                args: any Argable<T>,
                array: [T])
    {
        self.title = title
        self.description = description
        self.args = args
        self.array = array
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading) {
                Text(title)
                  .foregroundColor(.black)
                  .font(.largeTitle)
                Text(description)
                Spacer()
                  .frame(maxHeight: 10)
                Text("Parameters which can affect how this step operates:")
                Grid(alignment: .topLeading) {
                    GridRow {
                        Text("Name")
                          .foregroundColor(.black)
                        Text("Value")
                          .foregroundColor(.black)
                        Text("Description")
                          .foregroundColor(.black)
                    }
                      .padding(.vertical, 2)

                    // index of paramters in list
                    ForEach(Array(array.enumerated()), id: \.element) { index, value in
                        ArgableRowView(args,
                                       argType: value,
                                       intUpdate: { args, argType, intValue in
                                           Task {
                                               let args = await constants.getHoughLineFinderArgs()
                                               if let argType = argType as? HoughLineFinder.Args.ArgType,
                                                  let updatedArgs = args.intUpdate(for: argType, value: intValue)
                                               {
                                                   Log.d("updatedArgs \(updatedArgs)")
                                                   await constants.set(houghLineFinderArgs: updatedArgs)
                                                   await outlierWindowViewModel.loadLineInfo()
                                               }
                                           }
                                       },
                                       doubleUpdate: { args, argType, doubleValue in
                                           Task {
                                               let args = await constants.getHoughLineFinderArgs()
                                               if let argType = argType as? HoughLineFinder.Args.ArgType,
                                                  let updatedArgs = args.doubleUpdate(for: argType, value: doubleValue)
                                               {
                                                   Log.d("updatedArgs \(updatedArgs)")
                                                   await constants.set(houghLineFinderArgs: updatedArgs)
                                                   await outlierWindowViewModel.loadLineInfo()
                                               }
                                           }
                                       })
                          .padding(.vertical, 2)
                    }
                }
            }
              .layoutPriority(10)
        }
          .padding(10)
    }
}

// view for each parameter for this step, as a GridRow with three elements
struct ArgableRowView<T: Hashable>: View {

    let args: any Argable<T>
    let argType: T
    let intUpdate: (any Argable<T>, T, Int) -> Void
    let doubleUpdate: (any Argable<T>, T, Double) -> Void
    
    @State var stringValue = ""
    
    init(_ args: any Argable<T>,
         argType: T,
         intUpdate: @escaping (any Argable<T>, T, Int) -> Void,
         doubleUpdate: @escaping (any Argable<T>, T, Double) -> Void)
    {
        self.args = args
        self.argType = argType
        self.intUpdate = intUpdate
        self.doubleUpdate = doubleUpdate
    }

    var body: some View {
        GridRow {
            Text("\(argType)")

            let value = args.value(for: argType)
            
            if args.isInteger(argType) {
                TextField("", text: $stringValue)
                  .frame(maxWidth: 80)
                  .onAppear {
                      if let value {
                          stringValue = String(format: "%d", Int(value))
                      }
                  }
                  .onSubmit {
                      if let intValue = Int(stringValue) {
                          intUpdate(args, argType, intValue)
                      }
                  }
                
            } else {
                TextField("", // not integer (real number)
                          text: $stringValue)
                  .frame(maxWidth: 80)
                  .onAppear {
                      if let value {
                          stringValue = String(format: "%.2f", value)
                      }
                  }
                  .onSubmit {
                      if let doubleValue = Double(stringValue) {
                          doubleUpdate(args, argType, doubleValue)
                      }
                  }
            }

            Text(args.description(for: argType))

        }
    }
}

struct HoughLinesTableView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    @Environment(OutlierWindowViewModel.self) var outlierWindowViewModel: OutlierWindowViewModel

    @State var sortOrder: [KeyPathComparator<HoughLineFinder.LineInfo>] = [
      .init(\.score, order: SortOrder.forward)
    ]
    
    var body: some View {
        @Bindable var outlierWindowViewModel = outlierWindowViewModel
        Group {
            if outlierWindowViewModel.selectedOutliers.count == 1 {

                Text("Information about \(outlierWindowViewModel.lineInfo.count) lines")
                Table(outlierWindowViewModel.lineInfo,
                      selection: $outlierWindowViewModel.selectedLines,
                      sortOrder: $sortOrder)
                {
                    TableColumn("Score", value: \.score) { row in
                        Text(String(format: "%.2f", row.score))
                    }
                    TableColumn("Theta", value: \.line.theta) { row in
                        Text(String(format: "%.2f", row.line.theta))
                    }
                    TableColumn("Rho", value: \.line.rho) { row in
                        Text(String(format: "%.2f", row.line.rho))
                    }
                    TableColumn("Votes", value: \.line.votes) { row in
                        Text(String(row.line.votes))
                    }
                    TableColumn("Border", value: \.border) { row in
                        Text(String(row.border))
                    }
                }
                  .onChange(of: outlierWindowViewModel.selectedLines) { old, newValue in
                      outlierWindowViewModel.didSelect(ids: newValue)
                  }                    
                  .onChange(of: sortOrder) {
                      outlierWindowViewModel.lineInfo.sort(using: sortOrder)
                  }

            } else {
                Text("Please select a single group above to see its lines here")
            }
        }
    }
}
