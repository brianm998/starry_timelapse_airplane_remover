import SwiftUI
import StarCore

// progress bars for loading indications

struct ProgressBars: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        VStack {
            if viewModel.loading_outliers {
                HStack {
                    Text("Loading Outliers for this frame")
                    Spacer()
                    ProgressView()
                      .progressViewStyle(.linear)
                      .frame(maxWidth: .infinity)
                }
            }

            if viewModel.initial_load_in_progress {
                HStack {
                    Text("Loading Image Sequence")
                    Spacer()
                    ProgressView(value: viewModel.frameLoadingProgress)
                }

            }

            if viewModel.loading_all_outliers {
                HStack {
                    Text("Loading Outlier Groups for all frames")
                    Spacer()
                    ProgressView(value: viewModel.outlierLoadingProgress)
                }
            }
        }
          .frame(maxHeight: .infinity, alignment: .bottom)
          .opacity(0.6)
    }
}
