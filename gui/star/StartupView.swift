import SwiftUI
import StarCore
import logging


enum StartupState {
    case horizon                // does this sequence have a horizon?
    case moving                 // is the camera moving?
    case selectHorizon          // static + horizon: ask user to paint it themselves
    case selectMovingHorizons   // moving + horizon: ask how many horizons to define
    case removal                // what kind of removal is desired?
}


struct StartupView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(spacing: 0) {
            ZStack {
                switch viewModel.startupState {
                case .horizon:
                    HorizonView(state: $viewModel.startupState)
                case .moving:
                    MovingView(state: $viewModel.startupState)
                case .selectHorizon:
                    SelectHorizonView(state: $viewModel.startupState)
                case .selectMovingHorizons:
                    SelectMovingHorizonsView(state: $viewModel.startupState)
                case .removal:
                    RemovalView(state: $viewModel.startupState)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: viewModel.startupState)
        }
          .padding(20)
          .background(.gray)
    }
}

struct HorizonView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @Binding fileprivate var state: StartupState

    var body: some View {
        VStack {
            Text(localized("ui.does_this_video_include_a_horizon"))
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 10)
            HStack {
                Spacer()
                Button {
                    self.state = .moving
                    viewModel.horizonDetectionEnabled = false
                } label: {
                    Text(localized("ui.no"))
                      .font(.title)
                      .foregroundColor(.black)
                      .padding(10)
                      .background(
                        RoundedRectangle(cornerRadius: 20)
                          .fill(.white)
                      )
                }
                  .fixedSize(horizontal: true, vertical: true)
                  .buttonStyle(PlainButtonStyle())

                Space(width: 20)
                
                Button {
                    self.state = .moving
                    viewModel.horizonDetectionEnabled = true
                } label: {
                    Text(localized("ui.yes"))
                      .font(.title)
                      .foregroundColor(.white)
                      .padding(10)
                      .background(
                        RoundedRectangle(cornerRadius: 20)
                          .fill(Color.blue.opacity(0.7))
                         
                      )
                }
                  .buttonStyle(PlainButtonStyle())
                  .fixedSize(horizontal: true, vertical: true)
                Spacer()
                
                Button {
                    withAnimation {
                        viewModel.shouldShowProcessingSettings = true
                        viewModel.shouldShowInitialInstructions = false
                    }
                } label: {
                    VStack {
                        Text("⚙")
                          .font(.system(size: 40))
                          .foregroundColor(.white)
                          .opacity(0.8)
                          .help(localized("ui.show_advanced_settings"))
                        Text(localized("ui.advanced"))
                          .foregroundColor(.white)
                          .opacity(0.8)
                    }
                }
                  .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

struct MovingView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @Binding fileprivate var state: StartupState

    var body: some View {
        VStack {
            Text(localized("ui.was_the_camera_moving_during_this_video"))
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 5)
            Text(localized("ui.or"))
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 5)
            Text(localized("ui.was_it_stationary_on_a_tripod_the_entire"))
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 10)
            HStack {
                Spacer()
                Button {
                    viewModel.cameraMotion = .fixed
                    viewModel.allowEarthAlignment = true // default to on for earth
                    if viewModel.horizonDetectionEnabled {
                        self.state = .selectHorizon
                    } else {
                        self.state = .removal
                    }
                } label: {
                    Text(localized("ui.static"))
                      .font(.title)
                      .foregroundColor(.black)
                      .padding(10)
                      .background(
                        RoundedRectangle(cornerRadius: 20)
                          .fill(.white)
                      )
                }
                  .fixedSize(horizontal: true, vertical: true)
                  .buttonStyle(PlainButtonStyle())

                Space(width: 20)
                
                Button {
                    viewModel.cameraMotion = .moving
                    if viewModel.horizonDetectionEnabled {
                        self.state = .selectMovingHorizons
                    } else {
                        self.state = .removal
                    }
                } label: {
                    Text(localized("ui.moving"))
                      .font(.title)
                      .foregroundColor(.white)
                      .padding(10)
                      .background(
                        RoundedRectangle(cornerRadius: 20)
                          .fill(Color.blue.opacity(0.7))
                      )
                }
                  .buttonStyle(PlainButtonStyle())
                  .fixedSize(horizontal: true, vertical: true)
                Spacer()
                
                Button {
                    withAnimation {
                        viewModel.shouldShowProcessingSettings = true
                        viewModel.shouldShowInitialInstructions = false
                    }
                } label: {
                    VStack {
                        Text("⚙")
                          .font(.system(size: 40))
                          .foregroundColor(.white)
                          .opacity(0.8)
                          .help(localized("ui.show_advanced_settings"))
                        Text(localized("ui.advanced"))
                          .foregroundColor(.white)
                          .opacity(0.8)
                    }
                }
                  .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

struct SelectMovingHorizonsView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @Binding fileprivate var state: StartupState

    // placeholder only: onAppear replaces it with the count preferred for this sequence
    @State private var horizonCount: Int = 3

    private var maxCount: Int { max(1, viewModel.imageSequenceSize) }

    var body: some View {
        VStack {
            Text(localized("ui.do_you_want_to_select_the_horizons_yourself"))
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 10)
            Text(localized("ui.star_allows_you_to_tell_it_where_the_horizon_2"))
              .font(.body)
              .foregroundColor(.white)
            Space(height: 10)
            HStack {
                Spacer()
                Button {
                    self.state = .removal
                } label: {
                    Text(localized("ui.no"))
                      .font(.title)
                      .foregroundColor(.black)
                      .padding(10)
                      .background(
                        RoundedRectangle(cornerRadius: 20)
                          .fill(.white)
                      )
                }
                  .fixedSize(horizontal: true, vertical: true)
                  .buttonStyle(PlainButtonStyle())

                Space(width: 30)

                VStack(spacing: 10) {
                    Stepper(
                        horizonCount == 1
                          ? localized("ui.define_n_horizons_one")
                          : localized("ui.define_n_horizons", horizonCount),
                        // not $horizonCount: only a change the user makes goes through this
                        // setter, so the preference is not rewritten by the initial suggestion
                        value: Binding(get: { horizonCount },
                                       set: { newCount in
                                           horizonCount = newCount
                                           viewModel.recordMovingHorizonCount(newCount)
                                       }),
                        in: 1...maxCount
                    )
                    .foregroundColor(.white)
                    .font(.title2)

                    Button {
                        viewModel.startMovingHorizonStartupFlow(count: horizonCount)
                    } label: {
                        Text(horizonCount == 1
                               ? localized("ui.select_n_horizons_one")
                               : localized("ui.select_n_horizons", horizonCount))
                          .font(.title)
                          .foregroundColor(.white)
                          .padding(10)
                          .background(
                            RoundedRectangle(cornerRadius: 20)
                              .fill(Color.blue.opacity(0.7))
                          )
                    }
                      .buttonStyle(PlainButtonStyle())
                      .fixedSize(horizontal: true, vertical: true)
                }

                Spacer()
            }
        }
        .onAppear {
            horizonCount = viewModel.preferredMovingHorizonCount
        }
    }
}

struct SelectHorizonView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @Binding fileprivate var state: StartupState

    var body: some View {
        VStack {
            Text(localized("ui.do_you_want_to_select_the_horizon_yourself"))
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 10)
            Text(localized("ui.star_allows_you_to_tell_it_where_the_horizon"))
              .font(.body)
              .foregroundColor(.white)
            Space(height: 10)
            HStack {
                Spacer()
                Button {
                    self.state = .removal
                } label: {
                    Text(localized("ui.no"))
                      .font(.title)
                      .foregroundColor(.black)
                      .padding(10)
                      .background(
                        RoundedRectangle(cornerRadius: 20)
                          .fill(.white)
                      )
                }
                  .fixedSize(horizontal: true, vertical: true)
                  .buttonStyle(PlainButtonStyle())

                Space(width: 20)

                Button {
                    viewModel.horizonPainterMode = .startup
                    viewModel.shouldShowInitialInstructions = false
                    viewModel.isShowingHorizonPainter = true
                } label: {
                    Text(localized("ui.yes"))
                      .font(.title)
                      .foregroundColor(.white)
                      .padding(10)
                      .background(
                        RoundedRectangle(cornerRadius: 20)
                          .fill(Color.blue.opacity(0.7))
                      )
                }
                  .buttonStyle(PlainButtonStyle())
                  .fixedSize(horizontal: true, vertical: true)
                Spacer()
            }
        }
    }
}

struct RemovalView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @Binding fileprivate var state: StartupState

    @State private var removeAirplanes: Bool = true
    @State private var removeSatellites: Bool = true
    @State private var removeMeteors: Bool = true

    /// Owned here rather than inside `KeypointDivisorStartupView` so that view can set the
    /// initial state from the machine's advice and still be collapsed by the user.
    @State private var showKeypointDivisor: Bool = false

    private var cleanMethod: CleanMethod {
        if removeAirplanes {
            if removeSatellites {
                if removeMeteors {
                    // remove all
                    .automatic(false)
                } else {
                    // remove all but meteors
                    .automatic(true)
                }
            } else {
                if removeMeteors {
                    // remove meteors and airplanes but not satellites
                    .selective
                } else {
                    // remove airplanes only
                    .selective
                }
            }
        } else {
            if removeSatellites {
                if removeMeteors {
                    // remove all but airplanes
                    .automatic(true)
                } else {
                    // remove only satellites
                    .automatic(true)
                }
            } else {
                if removeMeteors {
                    // remove meteors only
                    .automatic(true)
                } else {
                    // remove nothing
                    .selective
                }
            }
        }
    }

    private var descriptionText: String {

        switch cleanMethod {
        case .automatic(let usesOutliers):
            if usesOutliers {
                localized("ui.mode_desc_auto_selective")
            } else {
                localized("ui.mode_desc_automatic")
            }
        case .selective:
            localized("ui.mode_desc_selective")
        }
    }
    
    var body: some View {
        VStack {
            Text(localized("ui.what_do_you_want_star_to_remove"))
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 10)
            Text(localized("ui.star_can_remove_some_or_all_of_these_things"))
              .font(.body)
              .foregroundColor(.white)

            Space(height: 10)
            Divider()
            HStack {
                Text(localized("ui.star_should_remove"))
                  .font(.title)
                  .foregroundColor(.white)
                
                VStack(alignment: .leading) {
                    Toggle(localized("ui.airplanes"), isOn: $removeAirplanes)
                      .font(.title)
                      .foregroundColor(.white)
                    Toggle(localized("ui.satellites"), isOn: $removeSatellites)
                      .font(.title)
                      .foregroundColor(.white)
                    Toggle(localized("ui.meteors"), isOn: $removeMeteors)
                      .font(.title)
                      .foregroundColor(.white)
                }
            }
            Divider()

            Text(self.descriptionText)
              .font(.body)
              .foregroundColor(.white)

            Space(height: 14)
            Divider()
            Space(height: 10)
            KeypointDivisorStartupView(isExpanded: $showKeypointDivisor)
            Space(height: 10)
            Divider()

            Space(height: 10)
            HStack {
                Spacer()
                Button {
                    withAnimation {
                        viewModel.shouldShowInitialInstructions = false
                    }
                } label: {
                    Text(localized("ui.close"))
                      .font(.title)
                      .foregroundColor(.black)
                      .padding(10)
                      .background(
                        RoundedRectangle(cornerRadius: 20)
                          .fill(.white)
                      )
                }
                  .fixedSize(horizontal: true, vertical: true)
                  .buttonStyle(PlainButtonStyle())

                Space(width: 20)
                
                Button {
                    withAnimation {
                        viewModel.shouldShowInitialInstructions = false
                        viewModel.cleanMethod = self.cleanMethod
                        viewModel.processAll()
                    }
                } label: {
                    Text(localized("ui.start_processing"))
                      .font(.title)
                      .foregroundColor(.white)
                      .padding(10)
                      .background(
                        RoundedRectangle(cornerRadius: 20)
                          .fill(Color.blue.opacity(0.7))
                         
                      )
                }
                  .buttonStyle(PlainButtonStyle())
                  .fixedSize(horizontal: true, vertical: true)
                Spacer()
                
                Button {
                    withAnimation {
                        viewModel.shouldShowProcessingSettings = true
                        viewModel.shouldShowInitialInstructions = false
                    }
                } label: {
                    VStack {
                        Text("⚙")
                          .font(.system(size: 40))
                          .foregroundColor(.white)
                          .opacity(0.8)
                          .help(localized("ui.show_advanced_settings"))
                        Text(localized("ui.advanced"))
                          .foregroundColor(.white)
                          .opacity(0.8)
                    }
                }
                  .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

