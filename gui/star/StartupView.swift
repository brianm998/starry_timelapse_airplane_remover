import SwiftUI
import StarCore
import logging


private enum StartupState: Int, CaseIterable {
    case horizon                // does this sequence have a horizon?
    case moving                 // is the camera moving?
    case removal                // what kind of removal is desired?
}


struct StartupView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    @State private var state: StartupState = .horizon
    
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch state {
                case .horizon:
                    HorizonView(state: $state)
                case .moving:
                    MovingView(state: $state)
                case .removal:
                    RemovalView(state: $state)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: state)
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
            Text("Does this video include a horizon?")
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 10)
            HStack {
                Spacer()
                Button {
                    self.state = .moving
                    viewModel.horizonDetectionEnabled = false
                } label: {
                    Text("No")
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
                    Text("Yes")
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
                          .help("Show Advanced Settings")
                        Text("Advanced")
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
            Text("Was the camera moving during this video")
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 5)
            Text("or")
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 5)
            Text("was it stationary on a tripod the entire time?")
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 10)
            HStack {
                Spacer()
                Button {
                    self.state = .removal
                    viewModel.cameraMotion = .fixed
                } label: {
                    Text("Static")
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
                    self.state = .removal
                    viewModel.cameraMotion = .moving
                } label: {
                    Text("Moving")
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
                          .help("Show Advanced Settings")
                        Text("Advanced")
                          .foregroundColor(.white)
                          .opacity(0.8)
                    }
                }
                  .buttonStyle(PlainButtonStyle())
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
                "Star will run in auto mode, replacing all bad pixels.  It will then do further processing on every frame to then allow users to select removed pixels to return to their original state.  You will have to go into each frame and select any signals you want to keep, Star cannot currently tell the difference between airplanes satellites and meteors"
            } else {
                "Star will run in automatic mode, replacing all bad pixels.  If everything goes well Star will not require any user attention per frame."
            }
        case .selective:
            "Star will run in selective mode, where it will analyze each frame to see what looks like bad signals, and then attempt to automatically categorize them.  The initial results may need some frame by frame attention."
        }
    }
    
    var body: some View {
        VStack {
            Text("What do you want Star to remove?")
              .font(.largeTitle)
              .foregroundColor(.white)
            Space(height: 10)
            Text("Star can remove some or all of these things from this video for you.  The choice here is the default for all frames of this video, and can later be changed on a frame by frame basis as desired.")
              .font(.body)
              .foregroundColor(.white)

            Space(height: 10)
            Divider()
            HStack {
                Text("Star should remove")
                  .font(.title)
                  .foregroundColor(.white)
                
                VStack(alignment: .leading) {
                    Toggle("Airplanes", isOn: $removeAirplanes)
                      .font(.title)
                      .foregroundColor(.white)
                    Toggle("Satellites", isOn: $removeSatellites)
                      .font(.title)
                      .foregroundColor(.white)
                    Toggle("Meteors", isOn: $removeMeteors)
                      .font(.title)
                      .foregroundColor(.white)
                }
            }
            Divider()

            Text(self.descriptionText)
              .font(.body)
              .foregroundColor(.white)
            
            Space(height: 10)
            HStack {
                Spacer()
                Button {
                    withAnimation {
                        viewModel.shouldShowInitialInstructions = false
                    }
                } label: {
                    Text("Close")
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
                        viewModel.showHorizonBar = false

                        viewModel.processAll()
                    }
                } label: {
                    Text("Start Processing")
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
                          .help("Show Advanced Settings")
                        Text("Advanced")
                          .foregroundColor(.white)
                          .opacity(0.8)
                    }
                }
                  .buttonStyle(PlainButtonStyle())
            }
        }
    }
}

