import SwiftUI
import StarCore

    
// shows either an editable view of the current frame or
// just the frame itself for scrubbing and video playback
// falling back to a place holder when we have no image for
// the current frame yet

public struct FrameView: View {
    @EnvironmentObject var viewModel: ViewModel
    @Binding private var interactionMode: InteractionMode
    @Binding private var showFullResolution: Bool

    public init(interactionMode: Binding<InteractionMode>,
               showFullResolution: Binding<Bool>)
    {
        _interactionMode = interactionMode
        _showFullResolution = showFullResolution
    }
    
    public var body: some View {
        ZStack {
            switch self.interactionMode {
            case .scrub:
                // the current frame by itself for fast video playback and scrubbing
                FrameImageView(interactionMode: self.$interactionMode,
                               showFullResolution: self.$showFullResolution)
                  .aspectRatio(contentMode: . fit)
                  .padding([.top])

            case .edit: 
                // the currently visible frame with outliers made visible
                FrameEditView(interactionMode: self.$interactionMode,
                              showFullResolution: self.$showFullResolution)
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
