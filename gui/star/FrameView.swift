import SwiftUI
import StarCore
import Zoomable

    
// shows either a zoomable view of the current frame
// just the frame itself for scrubbing and video playback
// or a place holder when we have no image for it yet

struct FrameView: View {
    @ObservedObject var viewModel: ViewModel
    @Binding private var interactionMode: InteractionMode
    @Binding private var showFullResolution: Bool

    public init(viewModel: ViewModel,
                interactionMode: Binding<InteractionMode>,
                showFullResolution: Binding<Bool>)
    {
        self.viewModel = viewModel
        _interactionMode = interactionMode
        _showFullResolution = showFullResolution
    }
    
    var body: some View {
        HStack {
            if let frame_image = self.viewModel.current_frame_image {
                switch self.interactionMode {
                case .scrub:
                    frame_image
                      .resizable()
                      .aspectRatio(contentMode: . fit)

                case .edit: 
                    GeometryReader { geometry in
                        let extra_space_on_edges: CGFloat = 140
                        let min = (geometry.size.height/(viewModel.frame_height+extra_space_on_edges))
                        let full_max = self.showFullResolution ? 1 : 0.3
                        let max = min < full_max ? full_max : min

                        ZoomableView(size: CGSize(width: viewModel.frame_width,
                                                  height: viewModel.frame_height),
                                     min: min,
                                     max: max,
                                     showsIndicators: true)
                        {
                            // the currently visible frame
                            FrameEditView(viewModel: viewModel,
                                          image: frame_image,
                                          interactionMode: self.$interactionMode)
                            //self.frameView(frame_image)//.aspectRatio(contentMode: .fill)
                        }
                          .transition(.moveAndFade)
                    }
                }
            } else {
                // XXX pre-populate this crap as an image
                ZStack {
                    Rectangle()
                      .foregroundColor(.yellow)
                      .aspectRatio(CGSize(width: 4, height: 3), contentMode: .fit)
                    Text(viewModel.no_image_explaination_text)
                }
                  .transition(.moveAndFade)
            }
        }
    }
}
