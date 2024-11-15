import SwiftUI
import StarCore

// displays a single frame as an image, and nothing else.
// the image is always a preview here

public struct FrameImageView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    public var body: some View {
        let frameView = self.viewModel.frames[self.viewModel.currentIndex]
        return frameView.previewImage(type: viewModel.frameViewMode)
    }
}
