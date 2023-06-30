import SwiftUI
import StarCore

// controls below the selected frame and above the filmstrip
// XXX this is a mess, clean it up

enum BottomControlLayout {
    case hStack
    case vStack2
    case vStack3
}

struct BottomControls: View {
    @EnvironmentObject var viewModel: ViewModel
    let scroller: ScrollViewProxy

    @State private var layout: BottomControlLayout = .vStack2//.hStack

    @State private var playbackButtonWidth: CGFloat = 0
    @State private var leftViewWidth: CGFloat = 0
    @State private var rightViewWidth: CGFloat = 0
    @State private var totalWidth: CGFloat = 0
    
    var body: some View {
        HStack {
            switch layout {
            case .hStack:
                ZStack(alignment: .center) {
                    HStack {
                        self.leftView()
                        Spacer()
                    }
                    
                    buttonsView()

                    HStack {
                        Spacer()
                        self.rightView()
                    }
                }

            case .vStack2:
                VStack {
                    HStack {
                        self.leftView()
                        self.rightView()
                    }
                    buttonsView()
                }
                
            case .vStack3:
                VStack {
                    self.leftView()
                    self.rightView()
                    buttonsView()
                }
            }
        }
          .frame(maxWidth: .infinity)
          .readSize { handleSize(size: $0) }
    }

    func handleSize(size: CGSize) {
        totalWidth = size.width
        if viewModel.interactionMode == .edit {
            if (totalWidth - self.playbackButtonWidth)/2 >= self.rightViewWidth {
                self.layout = .hStack
            } else {
                if self.rightViewWidth + self.leftViewWidth/* + 300*/ < totalWidth {
                    self.layout = .vStack2
                } else {
                    self.layout = .vStack3
                }
            }
        } else {
            if (totalWidth - self.playbackButtonWidth)/2 >= self.leftViewWidth {
                self.layout = .hStack
            } else {
                self.layout = .vStack2
            }
        }
    }
    
    func buttonsView() -> some View {
        VideoPlaybackButtons(scroller: scroller)
          .frame(height: 40, alignment: .center)
          .fixedSize()
          .readSize { self.playbackButtonWidth = $0.width }
    }
    
    func rightView() -> some View {
        HStack() {
            if viewModel.interactionMode == .edit {
                let frameView = viewModel.currentFrameView
                VStack(alignment: .trailing) {
                    let numChanged = viewModel.numberOfFramesChanged
                    if numChanged > 0 {
                        Text("\(numChanged) frames changed")
                          .foregroundColor(.yellow)
                    }
                    let numSaving = viewModel.frameSaveQueue?.saving.count ?? -1
                    if numSaving > 0 {
                        Text("saving \(numSaving) frames")
                          .foregroundColor(.green)
                    }
                }
                VStack {
                    Text("frame \(viewModel.currentIndex)")
                    if let _ = frameView.outlierViews {
                        if let numPositive = frameView.numberOfPositiveOutliers {
                            Text("\(numPositive) will paint")
                              .foregroundColor(numPositive == 0 ? .white : .red)
                        }
                        if let numNegative = frameView.numberOfNegativeOutliers {
                            Text("\(numNegative) will not paint")
                              .foregroundColor(numNegative == 0 ? .white : .green)
                        }
                        if let numUndecided = frameView.numberOfUndecidedOutliers,
                           numUndecided > 0
                        {
                            Text("\(numUndecided) undecided")
                              .foregroundColor(.orange)
                        }
                    }
                }

                let paintAction = {
                    Log.d("PAINT")
                    viewModel.paintSheetShowing = !viewModel.paintSheetShowing
                }
                Button(action: paintAction) {
                    buttonImage("square.stack.3d.forward.dottedline", size: 44)
                    
                }
                  .buttonStyle(PlainButtonStyle())           
                  .help("effect multiple frames")
                
                let gearAction = {
                    Log.d("GEAR")
                    viewModel.settingsSheetShowing = !viewModel.settingsSheetShowing
                }
                Button(action: gearAction) {
                    buttonImage("gearshape.fill", size: 44)
                    
                }
                  .buttonStyle(PlainButtonStyle())           
                  .help("settings")
                
                toggleViews()
              .sheet(isPresented: $viewModel.settingsSheetShowing) {
                  SettingsSheetView(isVisible: self.$viewModel.settingsSheetShowing,
                                    fastSkipAmount: $viewModel.fastSkipAmount,
                                    videoPlaybackFramerate: self.$viewModel.videoPlaybackFramerate,
                                    fastAdvancementType: $viewModel.fastAdvancementType)
              }
              .sheet(isPresented: $viewModel.paintSheetShowing) {
                  MassivePaintSheetView(isVisible: self.$viewModel.paintSheetShowing) { shouldPaint, startIndex, endIndex in
                      
                      viewModel.updatingFrameBatch = true
                      
                      for idx in startIndex ... endIndex {
                          // XXX use a task group?
                          viewModel.setAllFrameOutliers(in: viewModel.frames[idx], to: shouldPaint)
                      }
                      viewModel.updatingFrameBatch = false
                      
                      Log.d("shouldPaint \(shouldPaint), startIndex \(startIndex), endIndex \(endIndex)")
                  }
              }
            } else {
                Spacer()
                  .border(.purple)
                Text("")
                  .border(.yellow)
            }
        }
          .frame(alignment: .trailing)
          .readSize { self.rightViewWidth = $0.width }
    }
    
    func leftView() -> some View {
        HStack {
            VStack {
                ZStack {
                    Button("") {
                        self.viewModel.interactionMode = .edit
                    }
                      .opacity(0)
                      .keyboardShortcut("e", modifiers: [])

                    Button("") {
                        self.viewModel.interactionMode = .scrub
                    }
                      .opacity(0)
                      .keyboardShortcut("s", modifiers: [])
                    
                    Picker("I will", selection: $viewModel.interactionMode) {
                        ForEach(InteractionMode.allCases, id: \.self) { value in
                            Text(value.localizedName).tag(value)
                        }
                    }
                      .help("""
                              Choose between quickly scrubbing around the video
                              and editing an individual frame.
                              """)
                      .disabled(viewModel.videoPlaying)
                      .onChange(of: viewModel.interactionMode) { mode in
                          Log.d("interactionMode change \(mode)")
                          switch mode {
                          case .edit:
                              viewModel.refreshCurrentFrame()
                              
                          case .scrub:
                              break
                          }
                      }
                      .frame(maxWidth: 220)
                      .pickerStyle(.segmented)
                }
                Picker("I will see", selection: $viewModel.frameViewMode) {
                    ForEach(FrameViewMode.allCases, id: \.self) { value in
                        Text(value.localizedName).tag(value)
                    }
                }
                  .disabled(viewModel.videoPlaying)
                  .help("""
                          Show each frame as either the original   
                          or with star processing applied.
                          """)
                  .frame(maxWidth: 220)
                  .help("show original or processed frame")
                  .onChange(of: viewModel.frameViewMode) { pick in
                      Log.d("pick \(pick)")
                      viewModel.refreshCurrentFrame()
                  }
                  .pickerStyle(.segmented)
            }
            
            // outlier opacity slider
            if self.viewModel.interactionMode == .edit {
                VStack {
                    Text("Outlier Group Opacity")
                    
                    Slider(value: $viewModel.outlierOpacitySliderValue, in : 0...1) { _ in
                        viewModel.update()
                    }
                      .frame(maxWidth: 140, alignment: .bottom)
                }
            }
        }
          .frame(alignment: .leading)
          .readSize { self.leftViewWidth = $0.width }
    }

    func toggleViews() -> some View {
        VStack(alignment: .leading) {
            Picker("selection mode", selection: $viewModel.selectionMode) {
                ForEach(SelectionMode.allCases, id: \.self) { value in
                    Text(value.localizedName).tag(value)
                }
            }
              .help("""
                      What happens when outlier groups are selected?
                      paint   - they will be marked for painting
                      clear   - they will be marked for not painting
                      details - they will be shown in the info window
                      """)
              .frame(maxWidth: 280)
              .pickerStyle(.segmented)

            HStack {
                Toggle("full resolution", isOn: $viewModel.showFullResolution)
                  .onChange(of: viewModel.showFullResolution) { modeOn in
                      viewModel.refreshCurrentFrame()
                  }
                Toggle("show filmstip", isOn: $viewModel.showFilmstrip)
            }
        }
    }
}

// XXX move these
extension View {
    func readSize(onChange: @escaping (CGSize) -> Void) -> some View
    {
        background(
          GeometryReader { geometryProxy in
              Color.clear
                .preference(key: SizePreferenceKey.self, value: geometryProxy.size)
          }
        )
          .onPreferenceChange(SizePreferenceKey.self, perform: onChange)
    }
}
struct SizePreferenceKey: PreferenceKey {
  static var defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) {}
}
