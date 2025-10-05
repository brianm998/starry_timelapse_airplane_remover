import SwiftUI

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
                Text("Loading \(text)")
                  .font(.title)
                  .foregroundColor(.white)
            }
            Spacer()
            ZStack {
                if viewModel.isProbingImageSequence {
                    VStack {
                        Text("Examining Video")
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
                            Text("All \(viewModel.numberExtracted) frames extracted")
                              .foregroundColor(.green)
                            ProgressView()
                              .colorScheme(.dark)
                        }
                    } else {
                      Text("\(viewModel.numberExtracted) frames extracted")
                          .foregroundColor(.white)
                    }
                } else if viewModel.amountPreviewsSaved != 1.0 {
                    CircularProgressView(progress: $viewModel.amountPreviewsSaved)
                      .frame(maxWidth: 500, maxHeight: 500)
                    Spacer()
                      .frame(maxHeight: 50)
                    if viewModel.amountPreviewsSaved == 1.0 {
                        VStack {
                            Text("All \(viewModel.numberPreviewsSaved) previews created")
                              .foregroundColor(.green)
                            ProgressView()
                              .colorScheme(.dark)
                        }
                    } else {
                      Text("\(viewModel.numberPreviewsSaved) previews created")
                          .foregroundColor(.white)
                    }
                } else {
                    CircularProgressView(progress: $viewModel.amountLoaded)
                      .frame(maxWidth: 500, maxHeight: 500)
                    Spacer()
                      .frame(maxHeight: 50)
                    if viewModel.amountLoaded == 1.0 {
                        VStack {
                            Text("All \(viewModel.numberLoaded) frames loaded")
                              .foregroundColor(.green)
                            ProgressView()
                              .colorScheme(.dark)
                        }
                    } else {
                        Text("\(viewModel.numberLoaded) frames loaded")
                          .foregroundColor(.white)
                    }
                }
            }
            Spacer()
            Button() {
                viewModel.isLoadingImageSequence = false
                viewModel.imageSequence = nil
            } label: {
                Text("Cancel")
                  .font(.largeTitle)
            }
              .buttonStyle(ShrinkingButton())
            Spacer()
        }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(viewModel.backgroundColor)
    }
}
