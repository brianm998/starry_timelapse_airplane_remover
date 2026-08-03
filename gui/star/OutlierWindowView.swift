import SwiftUI
import StarCppBridge
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
                    Text(localized("ui.select_some_outliers")) 
                } else if outlierWindowViewModel.selectedOutliers.count == 1 {
                    VStack {
                        Text(localized("ui.hough_lines_for_the_selected_outlier"))
                        Text(localized("ui.select_a_line_to_see_it_on_the_main_window"))
                        Text(localized("ui.or_update_the_line_parameters_to_see_any"))

                        HoughLinesTableView()
                          .environment(outlierWindowViewModel)
                    }
                } else {
                    Text(localized("ui.n_outliers_selected", outlierWindowViewModel.selectedOutliers.count)) 
                }
                Spacer()
                houghLineArgs
            }
        }
          .navigationTitle(localized("ui.star_outlier_info_window"))
    }

    var houghLineArgs: some View {
        Group {
            if let houghLineFinderArgs = outlierWindowViewModel.houghLineFinderArgs {
                ArgableView(title: localized("ui.hough_line_arguments"),
                            description: """
                              Arguments for the hough line finder.
                              Updating values here will generate new lines with the new values.
                              """,
                            args: houghLineFinderArgs,
                            array: HoughLineFinder.Args.ArgType.allCases)
                  .environment(outlierWindowViewModel)
            } else {
                Text(localized("ui.loading_args"))
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

                    
                    Text(localized("ui.select_which_columns_to_show"))
                }
                HStack {
                    Button() {
                        outlierWindowViewModel.selectAll()
                    } label: {
                        Text(localized("ui.select_all"))
                          .buttonStyle(ShrinkingButton())
                    }

                    Button() {
                        outlierWindowViewModel.clearAll()
                    } label: {
                        Text(localized("ui.clear_all"))
                          .buttonStyle(ShrinkingButton())
                    }
                }
                
                Toggle(localized("ui.name"), isOn: $outlierWindowViewModel.showName)
                Toggle(localized("ui.centerx"), isOn: $outlierWindowViewModel.showCenterX)
                Toggle(localized("ui.centery"), isOn: $outlierWindowViewModel.showCenterY)
                Toggle(localized("ui.width"), isOn: $outlierWindowViewModel.showWidth)
                Toggle(localized("ui.height"), isOn: $outlierWindowViewModel.showHeight)
                Toggle(localized("ui.minx"), isOn: $outlierWindowViewModel.showMinX)
                Toggle(localized("ui.miny"), isOn: $outlierWindowViewModel.showMinY)
                Toggle(localized("ui.maxx"), isOn: $outlierWindowViewModel.showMaxX)
                Toggle(localized("ui.maxy"), isOn: $outlierWindowViewModel.showMaxY)
                Toggle(localized("ui.hypotenuse"), isOn: $outlierWindowViewModel.showHypotenuse)
                Toggle(localized("ui.aspectratio"), isOn: $outlierWindowViewModel.showAspectRatio)
                Toggle(localized("ui.fillamount"), isOn: $outlierWindowViewModel.showFillAmount)
                Toggle(localized("ui.surfacearearatio"), isOn: $outlierWindowViewModel.showSurfaceAreaRatio)
                Toggle(localized("ui.averagebrightness"), isOn: $outlierWindowViewModel.showAveragebrightness)
                Toggle(localized("ui.medianbrightness"), isOn: $outlierWindowViewModel.showMedianBrightness)
                Toggle(localized("ui.maxbrightness"), isOn: $outlierWindowViewModel.showMaxBrightness)
                Toggle(localized("ui.numberofnearbyoutliersinsameframe"),
                       isOn: $outlierWindowViewModel.showNumberOfNearbyOutliersInSameFrame)
                Toggle(localized("ui.maxhoughtransformcount"), isOn: $outlierWindowViewModel.showMaxHoughTransformCount)
                Toggle(localized("ui.pixelborderamount"), isOn: $outlierWindowViewModel.showPixelBorderAmount)
                Toggle(localized("ui.averagelinevariance"), isOn: $outlierWindowViewModel.showAverageLineVariance)
                Toggle(localized("ui.linelength"), isOn: $outlierWindowViewModel.showLineLength)
                Toggle(localized("ui.nearbydirectoverlapscore"), isOn: $outlierWindowViewModel.showNearbyDirectOverlapScore)
                Toggle(localized("ui.boundingboxoverlapscore"), isOn: $outlierWindowViewModel.showBoundingBoxOverlapScore)
                Toggle(localized("ui.lineintensityscore"), isOn: $outlierWindowViewModel.showLineIntensityScore)
                Toggle(localized("ui.linepixelscore"), isOn: $outlierWindowViewModel.showLinePixelScore)
                Toggle(localized("ui.borderbrightness"), isOn: $outlierWindowViewModel.showBorderBrightness)
                Toggle(localized("ui.bunchcount"), isOn: $outlierWindowViewModel.showBunchCount)
                Toggle(localized("ui.medianbunchsize"), isOn: $outlierWindowViewModel.showMedianBunchSize)
                Toggle(localized("ui.maxbunchsize"), isOn: $outlierWindowViewModel.showMaxBunchSize)
                Toggle(localized("ui.neighborlinethetascore"), isOn: $outlierWindowViewModel.showNeighborLineThetaScore)
                Toggle(localized("ui.neighborlinerhoscore"), isOn: $outlierWindowViewModel.showNeighborLineRhoScore)
                Toggle(localized("ui.neighborlinesizescore"), isOn: $outlierWindowViewModel.showNeighborLineSizeScore)
                Toggle(localized("ui.neighborlinebrightnessscore"), isOn: $outlierWindowViewModel.showNeighborLineBrightnessScore)
                Toggle(localized("ui.neighborlinedistancescore"), isOn: $outlierWindowViewModel.showNeighborLineDistanceScore)
                Toggle(localized("ui.neighborlinedistancescore"), isOn: $outlierWindowViewModel.showClassificationScore)
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
                Text(localized("ui.parameters_which_can_affect_how_this_step"))
                Grid(alignment: .topLeading) {
                    GridRow {
                        Text(localized("ui.name"))
                          .foregroundColor(.black)
                        Text(localized("ui.value"))
                          .foregroundColor(.black)
                        Text(localized("ui.description"))
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
      .init(\.intensityScore, order: SortOrder.forward)
    ]
    
    var body: some View {
        @Bindable var outlierWindowViewModel = outlierWindowViewModel
        Group {
            if outlierWindowViewModel.selectedOutliers.count == 1 {

                Text(localized("ui.info_about_n_lines", outlierWindowViewModel.lineInfo.count))
                Table(outlierWindowViewModel.lineInfo,
                      selection: $outlierWindowViewModel.selectedLines,
                      sortOrder: $sortOrder)
                {
                    TableColumn(localized("ui.intensity_score"), value: \.intensityScore) { row in
                        Text(String(format: "%.2f", row.intensityScore))
                    }
                    TableColumn(localized("ui.pixel_score"), value: \.pixelScore) { row in
                        Text(String(format: "%.2f", row.pixelScore))
                    }
                    TableColumn(localized("ui.theta"), value: \.line.theta) { row in
                        Text(String(format: "%.2f", row.line.theta))
                    }
                    TableColumn(localized("ui.rho"), value: \.line.rho) { row in
                        Text(String(format: "%.2f", row.line.rho))
                    }
                    TableColumn(localized("ui.votes"), value: \.line.votes) { row in
                        Text(String(row.line.votes))
                    }
                    TableColumn(localized("ui.border"), value: \.border) { row in
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
                Text(localized("ui.please_select_a_single_group_above_to_see"))
            }
        }
    }
}
