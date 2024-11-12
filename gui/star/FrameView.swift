import SwiftUI
import StarCore

    
// shows either an editable view of the current frame or
// just the frame itself for scrubbing and video playback

public struct FrameView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    public var body: some View {
        @Bindable var viewModel = viewModel
        return ZStack {
            switch self.viewModel.interactionMode {
            case .scrub:
                // the current frame by itself for fast video playback and scrubbing
                FrameImageView()
                  .aspectRatio(contentMode: . fit)
                  .padding([.top])

            case .edit: 
                // the currently visible frame with outliers made visible
                FrameEditView()
            }
        }
    }

    // initial view for when we've not loaded images yet
    var loadingView: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle()
                  .foregroundColor(.yellow)
                  .aspectRatio(CGSize(width: 4, height: 3), contentMode: .fit)
                Text(viewModel.noImageExplainationText)
                  .font(.system(size: geometry.size.height/6))
                  .opacity(0.6)
            }
              .padding([.top])
              .frame(maxWidth: .infinity, maxHeight: .infinity)
             // .transition(.moveAndFade)
        }
    }
}
