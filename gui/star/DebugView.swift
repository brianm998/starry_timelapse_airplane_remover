import SwiftUI
import logging

import StarCore
/*
  add number of images in cache
  allow sorting data by time
  allow searching by text

 * allow sorting existing data by log level (instead of changing the log level reported at)
 * update gui logging to report structured data
 * filter logs
 * add switch to enable file logging at separate log level (show file name in gui somewhere)
 * keep maximum number of lines in gui logs
 * disable bottom scrolling when not at the bottom
 * add scroll to bottom button
 * allow copying log data to clipboard


 */

struct DebugView: View {

    @Environment(ViewModel.self) var viewModel: ViewModel
    @Environment(LoggingViewModel.self) var loggingViewModel: LoggingViewModel

    // show only this level and above in the gui
    @State private var filterLevel: Log.Level = .warn

    @State private var lastItemBottom: CGFloat = .zero
    @State private var viewportHeight: CGFloat = .zero
    @State private var isPinnedToBottom: Bool = true

    @State private var isScrolling: Bool = false

    // Bumped from the @Sendable onPreferenceChange closure to request a
    // scroll-to-bottom. The actual scroll happens in an @MainActor
    // .onChange handler below — see the long comment on .onPreferenceChange
    // for why we can't call proxy.scrollTo directly from there.
    @State private var scrollToBottomNonce: Int = 0

    /// How close (in points) the last message’s bottom must be
    /// to the viewport bottom to be considered “at bottom.”
    private let bottomThreshold: CGFloat = 20
    
    private let dateFormatter = DateFormatter()

    public init() {
        dateFormatter.dateFormat = "H:mm:ss.SSSS"
    }
    
    var body: some View {
        @Bindable var loggingViewModel = loggingViewModel
        return VStack(alignment: .leading) {
            Space(height: 10)
            ScrollViewReader { proxy in
                VStack(alignment: .leading) {
                    topView(with: proxy)
                    logView(with: proxy)
                }
            }
        }
          .navigationTitle(localized("ui.star_debug"))
    }


    
    @State private var allowFocus = false

    
    // the top bar of buttons above the logs
    func topView(with proxy: ScrollViewProxy) -> some View {
        @Bindable var loggingViewModel = loggingViewModel
        return HStack {
            Spacer()

            Picker(localized("ui.log_level"), selection: $loggingViewModel.level) {
                ForEach(Log.Level.allCases, id: \.self) { level in
                    Text("\(level.emo) \(level.rawValue)")
                }
            }
              .pickerStyle(.menu)
              .fixedSize(horizontal: true, vertical: false)

            Picker(localized("ui.show"), selection: $filterLevel) {
                ForEach(Log.Level.allCases, id: \.self) { level in
                    Text("\(level.emo) \(level.rawValue)")
                }
            }
              .pickerStyle(.menu)
              .fixedSize(horizontal: true, vertical: false)

            Text(localized("ui.max_log_lines")) 
            TextField("\(loggingViewModel.maxGUILogLines)",
                      text: $loggingViewModel.maxGUILogLinesString)

              .focusable(allowFocus)          // If false, field will not accept focus
              .onAppear {
                  // Prevent initial focus
                  allowFocus = false
                  // Re-enable normal focusing after a tiny delay
                  DispatchQueue.main.async {
                      allowFocus = true
                  }
              }            
              .onSubmit {
                  let filtered = loggingViewModel.maxGUILogLinesString.filter { "0123456789".contains($0) }
                  if let newValue = Int(filtered) {
                      loggingViewModel.maxGUILogLines = newValue
                      loggingViewModel.maxGUILogLinesString = "\(newValue)"
                      //self.trashLevelIsFirstResponder = false
                  }
              }
              .fixedSize(horizontal: true, vertical: false)

            Button {
                copyToClipboard(string: loggingViewModel.rawLogs)
            } label: {
                Text(localized("ui.copy_to_clipboard"))
            }
            
            Button {
                self.isPinnedToBottom = true
                if let last = loggingViewModel.logs.indices.last  {
                    withAnimation(.none) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            } label: {
                Text(localized("ui.scroll_to_bottom"))
            }
              .disabled(isPinnedToBottom)

            Button {
                loggingViewModel.clearLogs()
            } label: {
                Text(localized("ui.clear"))
            }

            Divider()
              .frame(width: 4)
              .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 0) {
                Toggle(isOn: $loggingViewModel.fileLogEnabled) {
                    Text("")
                      .foregroundColor(loggingViewModel.fileLogEnabled ? .black : .gray)
                }
                
                Picker(selection: $loggingViewModel.fileLogLevel) {
                    ForEach(Log.Level.allCases, id: \.self) { level in
                        Text("\(level.emo) \(level.rawValue)")
                    }
                } label: {
                    Text(localized("ui.log_to_file_at_level"))
                      .foregroundColor(loggingViewModel.fileLogEnabled ? .black : .gray)
                }
                  .pickerStyle(.menu)
                  .fixedSize(horizontal: true, vertical: false)
                  .disabled(!loggingViewModel.fileLogEnabled)
            }
            Spacer()
        }
        
    }

    func logView(with proxy: ScrollViewProxy) -> some View {
        @Bindable var loggingViewModel = loggingViewModel
        return VStack(alignment: .leading) {
            HStack {
                Space(width: 10)
                ScrollView {
                    HStack {
                        Grid(alignment: .leading) {
                            ForEach(loggingViewModel.logs.indices, id: \.self) { index in
                                let logLine = loggingViewModel.logs[index]
                                if logLine.level <= filterLevel {
                                    GridRow {
                                        Text(self.dateFormatter.string(from: logLine.time))
                                        Text(logLine.level.emo)
                                        Text(logLine.fileLocation)
                                        Text(logLine.message)
                                    }
                                      // measure this items min Y
                                      .background(
                                        GeometryReader { geo in
                                            ZStack {
                                                Color.clear
                                                  .preference(
                                                    key: LastItemBottomKey.self,
                                                    value: geo.frame(in: .named("scroll")).minY
                                                  )
                                            }
                                        }
                                      )
                                      .id(index)
                                }
                            }
                        }
                        Spacer()    // force things to the left
                    }
                }
                  .coordinateSpace(name: "scroll")

                  .onScrollPhaseChange { oldPhase, newPhase in
                      // Set isScrolling to true when the user is interacting or decelerating
                      self.isScrolling = newPhase != .idle 
                  }                    
                  .readSize() { size in
                      viewportHeight = size.height
                      // if we’re showing fewer messages initially and they fit exactly,
                      // you may want to pin on appear:
                      if lastItemBottom <= size.height + bottomThreshold {
                          isPinnedToBottom = true
                      }
                      
                  }
                
                // Update our state when preferences change.
                //
                // Starting with the macOS 15 / iOS 18 SDK, SwiftUI's
                // onPreferenceChange overload takes a @Sendable closure
                // (because PreferenceKey.Value is now required to be
                // Sendable). That means the body can no longer touch
                // main-actor @State directly, nor capture the non-Sendable
                // ScrollViewProxy. We work around both:
                //   * State mutations are wrapped in Task { @MainActor in }
                //     so they happen back on the main actor.
                //   * The actual proxy.scrollTo call lives in an .onChange
                //     handler keyed on a counter we bump from here —
                //     .onChange's closure is @MainActor, so capturing
                //     `proxy` there is allowed.
                // Older Xcodes resolve to the deprecated, non-@Sendable
                // overload of onPreferenceChange, which is why this still
                // compiled before. Xcode 16+ on the macOS 15 SDK enforces
                // the new signature.
                  .onPreferenceChange(LastItemBottomKey.self) { newBottom in
                      Task { @MainActor in
                          // if that bottom is within threshold of viewport bottom, pin
                          lastItemBottom = newBottom
                          if isScrolling {
                              // only apply this logic when the user is scrolling
                              if lastItemBottom <= viewportHeight + bottomThreshold {
                                  isPinnedToBottom = true
                                  scrollToBottomNonce &+= 1
                              } else {
                                  isPinnedToBottom = false
                              }
                          } else if isPinnedToBottom {
                              scrollToBottomNonce &+= 1
                          }
                      }
                  }
                  .onChange(of: scrollToBottomNonce) {
                      // .onChange's closure is @MainActor, so we can safely
                      // capture and use the non-Sendable ScrollViewProxy here.
                      if let last = loggingViewModel.logs.indices.last {
                          withAnimation(.none) {
                              proxy.scrollTo(last, anchor: .bottom)
                          }
                      }
                  }

                // 6) Only auto-scroll on new messages *if* we’re pinned
                  .onChange(of: loggingViewModel.logs.count) { 
                      guard isPinnedToBottom,
                            let last = loggingViewModel.logs.indices.last else { return }
                      withAnimation(.none) {
                          proxy.scrollTo(last, anchor: .bottom)
                      }
                  }
                // also scroll to bottom on first appear
                  .onAppear {
                      if let last = loggingViewModel.logs.indices.last {
                          proxy.scrollTo(last, anchor: .bottom)
                      }
                  }
                Space(width: 10)
            }
              //.frame(maxWidth: .infinity)
            Space(height: 10)
        }
    }
}

// 1) PreferenceKey for last-item bottom position (in named coordinate space)
private struct LastItemBottomKey: PreferenceKey {
    static let defaultValue: CGFloat = .zero
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        // we only care about the last one
        value = nextValue()
    }
}

func copyToClipboard(string: String) {
    let pasteboard = NSPasteboard.general // 1. Get the general pasteboard instance.
    pasteboard.clearContents() // 2. Clear the existing contents of the pasteboard.
    pasteboard.setString(string, forType: .string) // 3. Set the string to be copied, specifying the data type.
}
