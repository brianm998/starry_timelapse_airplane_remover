import SwiftUI
import StarCore

// progress bars for loading indications

struct ProgressBars: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        VStack {
            if viewModel.loadingOutliers {
                HStack {
                    Text("Loading Outliers for this frame")
                      .foregroundColor(.white)
                    Spacer()
                    ProgressView()
                      .colorScheme(.dark)
                      .progressViewStyle(.linear)
                      .frame(maxWidth: .infinity)
                }
            }

            if viewModel.loadingAllOutliers {
                HStack {
                    Text("Loading Outlier Groups")
                      .foregroundColor(.white)
                    Spacer()
                    ProgressView(value: viewModel.outlierLoadingProgress)
                }
            }
        }
          .frame(maxHeight: .infinity, alignment: .bottom)
          .opacity(0.6)
    }
}
