import SwiftUI
import StarCore
import logging

struct ReProcessCurrentFrameButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Group {
            Button(action: action) {
                Text("Re-Process this frame from the start")
            }
              .help("Re-Process this frame from the start")
        }
    }

    private func action() {
        Task {
            if let frame = viewModel.currentFrame {
                frame.imageAccessor.deleteAllImages()
                viewModel.frameViewMode = .original

                let binaryBlobFilename = await frame.blobBinaryFilename
                // get rid of the outlier files
                do {
                    Log.d("trying to remove \(binaryBlobFilename)")
                    try FileManager.default.removeItem(atPath: binaryBlobFilename)
                } catch {
                    Log.e("error removing \(binaryBlobFilename): \(error)")
                }
                // re-find them
                await viewModel.findOutliers(frame: frame)
            } else {
                // XXX probably should do something here
            }
        }
    }
}












