import SwiftUI

import StarCore
// displayed when loading an image sequence
@available(macOS 13.0, *) 
struct ImageSequenceLoadingView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    var body: some View {
        @Bindable var viewModel = viewModel

        // XXX needs to show error messages when they occur

        VStack {
            Spacer()
            if let text = viewModel.loadingImageSequenceFilename {
                Text(localized("ui.loading_x", text))
                  .font(.title)
                  .foregroundColor(.white)
            }
            Spacer()
            ZStack {
                if viewModel.isProbingImageSequence {
                    VStack {
                        Text(localized("ui.examining_video"))
                          .font(.title)
                          .foregroundColor(.white)
                        ProgressView()
                          .colorScheme(.dark)
                    }
                } else if viewModel.isExtractingImageSequence {
                    CircularProgressView(progress: $viewModel.amountExtracted)
                      .frame(maxWidth: 500, maxHeight: 500)
                    Spacer()
                      .frame(maxHeight: 50)
                    if viewModel.amountExtracted == 1.0 {
                        VStack {
                            Text(localized("ui.all_n_frames_extracted", viewModel.numberExtracted))
                              .foregroundColor(.green)
                            ProgressView()
                              .colorScheme(.dark)
                        }
                    } else {
                      Text(localized("ui.n_frames_extracted", viewModel.numberExtracted))
                          .foregroundColor(.white)
                    }
                } else {
                    CircularProgressView(progress: $viewModel.amountLoaded)
                      .frame(maxWidth: 500, maxHeight: 500)
                    Spacer()
                      .frame(maxHeight: 50)
                    if viewModel.amountLoaded == 1.0 {
                        VStack {
                            Text(localized("ui.all_n_frames_loaded", viewModel.numberLoaded))
                              .foregroundColor(.green)
                            ProgressView()
                              .colorScheme(.dark)
                        }
                    } else {
                        Text(localized("ui.n_frames_loaded", viewModel.numberLoaded))
                          .foregroundColor(.white)
                    }
                }
            }
            Spacer()
            Button() {
                viewModel.isLoadingImageSequence = false
                viewModel.imageSequence = nil
            } label: {
                Text(localized("ui.cancel"))
                  .font(.largeTitle)
            }
              .buttonStyle(ShrinkingButton())
            Spacer()
        }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(viewModel.backgroundColor)
    }
}
