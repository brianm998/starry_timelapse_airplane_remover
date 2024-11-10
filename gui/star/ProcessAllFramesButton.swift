import SwiftUI
import StarCore
import logging

struct ProcessAllFramesButton: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    var body: some View {
        Group {
            Button(action: buttonPress) {
                Text("Process all frames")
            }
              .help("Process all frames")
        }
    }

    private func buttonPress() {
        Task {
            // XXX a crude version of the FinalProcessor, could be better
            await withTaskGroup(of: Void.self) { taskGroup in
                for frameView in viewModel.frames {
                    if let frame = frameView.frame {
                        taskGroup.addTask() {
                            await viewModel.findOutliers(frame: frame)
                        }
                    }
                }
                await taskGroup.waitForAll()
            }
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                for frameView in viewModel.frames {
                    if let frame = frameView.frame {
                        taskGroup.addTask() {
                            try await frame.finish() // errors not handled :(
                        }
                    }
                }
                try await taskGroup.waitForAll()
            }
        }
    }
}












