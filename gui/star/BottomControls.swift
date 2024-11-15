import SwiftUI
import StarCore

// controls below the selected frame and above the filmstrip and scrub slider

enum BottomControlLayout {
    case fullyHorizontal
    case twoVerticalLayers
    case threeVerticalLayers
}

struct BottomControls: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    @State private var layout: BottomControlLayout = .fullyHorizontal

    @State private var playbackButtonWidth: CGFloat = 0
    @State private var leftViewWidth: CGFloat = 0
    @State private var rightViewWidth: CGFloat = 0

    @State private var spaceAvailable = CGSize(width: 0, height: 0)

    var body: some View {
        HStack {
            switch layout {
            case .fullyHorizontal:
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

            case .twoVerticalLayers:
                VStack {
                    HStack {
                        self.leftView()
                        Spacer()
                        self.rightView()
                    }
                    buttonsView()
                }
                
            case .threeVerticalLayers:
                VStack {
                    self.leftView()
                    self.rightView()
                    buttonsView()
                }
            }
        }
          .frame(maxWidth: .infinity)
          .readSize {
              self.spaceAvailable = $0
              handleSizeUpdate()
          }
    }

    // maybe adjust the layout if some of the sizes change
    func handleSizeUpdate() {
        // how much space we have available to fill
        let totalWidth = spaceAvailable.width

        // how much space is left on the side with the playback buttons in the middle
        let spaceOnSide = (totalWidth - self.playbackButtonWidth)/2
        
        switch viewModel.interactionMode {
        case .edit:
            if spaceOnSide >= self.rightViewWidth,
               spaceOnSide >= self.leftViewWidth
            {
                self.layout = .fullyHorizontal
            } else {
                if self.rightViewWidth + self.leftViewWidth < totalWidth {
                    self.layout = .twoVerticalLayers
                } else {
                    self.layout = .threeVerticalLayers
                }
            }

        case .scrub:
            if (totalWidth - self.playbackButtonWidth)/2 >= self.leftViewWidth {
                self.layout = .fullyHorizontal
            } else {
                self.layout = .twoVerticalLayers
            }
        }
    }

    // whatever is on the right side
    func rightView() -> some View {
        BottomRightView()
          .frame(alignment: .trailing)
          .readSize {
              self.rightViewWidth = $0.width
              handleSizeUpdate()
          }
    }

    // the video playback buttons in the middle
    func buttonsView() -> some View {
        VideoPlaybackButtons()
          .frame(height: 40, alignment: .center)
          .fixedSize()
          .readSize {
              self.playbackButtonWidth = $0.width
              handleSizeUpdate()
          }
    }

    // whatever is on the left side
    func leftView() -> some View {
        BottomLeftView()
          .frame(alignment: .leading)
          .readSize {
              self.leftViewWidth = $0.width 
              handleSizeUpdate()
          }
    }

}

// XXX move these
extension View {
    func readSize(onChange: @escaping (CGSize) -> Void) -> some View {
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
  static let defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) {}
}

extension View {
    func cursor(_ cursor: NSCursor, tag: String) -> some View {
        Group {
        background(
              Color.clear
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    print("FUCKING FRAME \(frame)")
                    _cursor_frames[tag] = frame
                }
                .onAppear {
                    print("FUCKING CURSOR ON APPEAR")
                    _cursors[tag] = cursor
                }
                .onDisappear {
                    // erg, this happens almost immediately after it appears,
                    // still visible on screen for a long time afterwards

                    // XXX fix this, as the cursor areas remain after is gone :(
                    print("FUCKING CURSOR ON DISAPPEAR \(tag)")
//                    _cursor_frames[tag] = nil
                }

        )
        }
          .onDisappear {
              print("FUCKING GROUP DISAPPEAR \(tag)")
          }
    }
}

  /*
  extension View {
    func cursor(_ cursor: NSCursor, tag: String) -> some View {
        background(
          GeometryReader { reader in
              Color.clear
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    print("FUCKING FRAME \(frame)")
                    _cursor_frames[tag] = frame
                }
                .onAppear {
                    print("FUCKING CURSOR ON APPEAR")
                    _cursors[tag] = cursor
                    _cursor_frames[tag] = reader.frame(in: .global)
                }
                .onDisappear {
                    // erg, this happens almost immediately after it appears,
                    // still visible on screen for a long time afterwards
                    print("FUCKING CURSOR ON DISAPPEAR")
//                    _cursor_frames[tag] = nil
                }
                .onChange(of: reader.size) { _ in
                    let frame = reader.frame(in: .global)
                    print("FUCKING CURSOR ON CHANGE \(frame)")
                    _cursor_frames[tag] = frame
                }
          }
        )
    }
}

*/
