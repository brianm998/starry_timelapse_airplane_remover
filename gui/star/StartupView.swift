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

/// A subdued "go to the previous question" control, shown on every startup screen after the
/// first. Lets the user correct an earlier answer (e.g. horizon or moving) without restarting
/// star — mirrors the escape hatch the horizon painter's own Cancel button already provides.
struct StartupBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text(localized("ui.back"))
            }
              .font(.title2)
              .foregroundColor(.white)
              .opacity(0.8)
        }
          .buttonStyle(PlainButtonStyle())
    }
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
                  .accessibilityIdentifier("startup.horizon.no")

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
                  .accessibilityIdentifier("startup.horizon.yes")
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
                StartupBackButton { self.state = .horizon }
                Spacer()
                Button {
                    viewModel.cameraMotion = .fixed
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
                  .accessibilityIdentifier("startup.moving.static")

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
                  .accessibilityIdentifier("startup.moving.moving")
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
                StartupBackButton { self.state = .moving }
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
                  .accessibilityIdentifier("startup.selectmovinghorizons.no")

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
                StartupBackButton { self.state = .moving }
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
                  .accessibilityIdentifier("startup.selecthorizon.no")

                Space(width: 20)

                Button {
                    viewModel.startStaticHorizonStartupFlow()
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
                  .accessibilityIdentifier("startup.selecthorizon.yes")
                Spacer()
            }
        }
    }
}

/// One of the two top-level processing modes: a radio-style row with a short description beneath it.
private struct ModeChoice: View {
    let title: String
    let description: String
    let selected: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                  .font(.title2)
                  .foregroundColor(.white)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                      .font(.title)
                      .foregroundColor(.white)
                    Text(description)
                      .font(.callout)
                      .foregroundColor(.white)
                      .opacity(0.8)
                      .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
              .padding(.vertical, 6)
              .contentShape(Rectangle())
        }
          .buttonStyle(PlainButtonStyle())
          .accessibilityIdentifier(identifier)
          .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct RemovalView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @Binding fileprivate var state: StartupState

    @State private var selectiveMode: Bool = false
    @State private var autoSelective: Bool = false
    @State private var groundAlignment: Bool = true

    /// Owned here rather than inside `KeypointDivisorStartupView` so that view can set the
    /// initial state from the machine's advice and still be collapsed by the user.
    @State private var showKeypointDivisor: Bool = false

    private var cleanMethod: CleanMethod {
        if selectiveMode { return .selective }
        return .automatic(autoSelective)
    }

    /// Which question screen "Back" should return to — derived from the answers already given
    /// rather than a separate history stack, since they fully determine how this screen was
    /// reached (directly from `.moving`, or via one of the horizon selection screens).
    private var previousStartupState: StartupState {
        guard viewModel.horizonDetectionEnabled else { return .moving }
        return viewModel.cameraMotion == .fixed ? .selectHorizon : .selectMovingHorizons
    }

    var body: some View {
        VStack {
            Text(localized("ui.startup_mode_title"))
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 10)
            Divider()

            ModeChoice(title: localized("ui.startup_mode_automatic"),
                       description: localized("ui.startup_mode_automatic_desc"),
                       selected: !selectiveMode,
                       identifier: "startup.removal.automatic") { selectiveMode = false }
            if !selectiveMode {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(localized("ui.startup_auto_selective_toggle"), isOn: $autoSelective)
                      .accessibilityIdentifier("startup.removal.autoselective")
                      .font(.title3)
                      .foregroundColor(.white)
                    Text(localized("ui.startup_auto_selective_desc"))
                      .font(.callout)
                      .foregroundColor(.white)
                      .opacity(0.8)
                      .fixedSize(horizontal: false, vertical: true)
                }
                  .padding(.leading, 34)
            }
            ModeChoice(title: localized("ui.startup_mode_selective"),
                       description: localized("ui.startup_mode_selective_desc"),
                       selected: selectiveMode,
                       identifier: "startup.removal.selective") { selectiveMode = true }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle(localized("ui.startup_ground_alignment_toggle"), isOn: $groundAlignment)
                  .accessibilityIdentifier("startup.removal.groundalignment")
                  .font(.title3)
                  .foregroundColor(.white)
                Text(localized("ui.startup_ground_alignment_desc"))
                  .font(.callout)
                  .foregroundColor(.white)
                  .opacity(0.8)
                  .fixedSize(horizontal: false, vertical: true)
            }
              .frame(maxWidth: .infinity, alignment: .leading)

            Space(height: 14)
            Divider()
            Space(height: 10)
            KeypointDivisorStartupView(isExpanded: $showKeypointDivisor)
            Space(height: 10)
            Divider()

            Space(height: 10)
            HStack {
                StartupBackButton { self.state = self.previousStartupState }
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
                        viewModel.allowEarthAlignment = groundAlignment
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
                  .accessibilityIdentifier("startup.removal.start")
                  .keyboardShortcut(.defaultAction)
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

