import SwiftUI
import StarCore

// progress bars for loading indications

struct ProgressBars: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    var body: some View {
        VStack {
            if viewModel.loadingOutliers {
                HStack {
                    Text("Loading Outliers for this frame")
                    Spacer()
                    ProgressView()
                      .progressViewStyle(.linear)
                      .frame(maxWidth: .infinity)
                }
            }

            if viewModel.initialLoadInProgress {
                HStack {
                    Text("Loading Image Sequence")
                    Spacer()
                    ProgressView(value: viewModel.frameLoadingProgress)
                }

            }

            if viewModel.loadingAllOutliers {
                HStack {
                    Text("Loading Outlier Groups")
                    Spacer()
                    ProgressView(value: viewModel.outlierLoadingProgress)
                }
            }
        }
          .frame(maxHeight: .infinity, alignment: .bottom)
          .opacity(0.6)
    }
}
