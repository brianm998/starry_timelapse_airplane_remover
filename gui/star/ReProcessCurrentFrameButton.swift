import SwiftUI
import StarCore
import logging

struct ReProcessCurrentFrameButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Group {
            Button(action: action) {
                Text(localized("ui.re_process_this_frame_from_the_start"))
            }
              .help(localized("ui.re_process_this_frame_from_the_start"))
        }
    }

    private func action() {
        Task {
            if let frame = viewModel.currentFrame {
              frame.imageAccessor.deleteAllImages(frameIndex: frame.frameIndex, reprocessingType: viewModel.reprocessingType)
                viewModel.frameViewMode = .original
                viewModel.frames[frame.frameIndex].existingImages = [.original]
                let binaryBlobFilename = await frame.blobBinaryFilename
                // get rid of the outlier files
                do {
                    Log.d("trying to remove \(binaryBlobFilename)")
                    try FileManager.default.removeItem(atPath: binaryBlobFilename)
                } catch {
                    Log.e("error removing \(binaryBlobFilename): \(error)")
                }
                // re-find them
                viewModel.findOutliersAndRender(frame: frame)
            } else {
                // XXX probably should do something here
            }
        }
    }
}












