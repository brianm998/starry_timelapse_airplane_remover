import SwiftUI
import StarCore
import logging

struct FindOutliersOnCurrentFrameButton: View { // rename this to reprocess 
    @Environment(ViewModel.self) var viewModel: ViewModel

    var body: some View {
        Group {
            let action: () -> Void = {
                Task {
                    if let frame = viewModel.currentFrame {
                        frame.imageAccessor.deleteAllImages()
                        viewModel.frameViewMode = .original

                        let binaryBlobFilename = await frame.blobBinaryFilename
                        // get rid of the outlier files
                        do {
                            Log.d("trying to remove \(binaryBlobFilename)")
                            try await FileManager.default.removeItem(atPath: binaryBlobFilename)
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
            
            return Button(action: action) {
                Text("Find Outliers for this frame")
            }
              .help("Re-Process this frame from the start")
        }
    }
}












