import SwiftUI
import StarCore

struct LoadAllOutliersButton: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        let action: () -> Void = {
            Task {
                do {
                    var current_running = 0
                    let startTime = Date().timeIntervalSinceReferenceDate
                    try await withLimitedThrowingTaskGroup(of: Void.self) { taskGroup in
                        let max_concurrent = viewModel.config?.numConcurrentRenders ?? 10
                        // this gets "Too many open files" with more than 2000 images :(
                        viewModel.loadingAllOutliers = true
                        Log.d("foobar starting")
                        viewModel.numberOfFramesWithOutliersLoaded = 0
                        for frameView in viewModel.frames {
                            Log.d("frame \(frameView.frameIndex) attempting to load outliers")
                            var did_load = false
                            while(!did_load) {
                                if current_running < max_concurrent {
                                    Log.d("frame \(frameView.frameIndex) attempting to load outliers")
                                    if let frame = frameView.frame {
                                        Log.d("frame \(frameView.frameIndex) adding task to load outliers")
                                        current_running += 1
                                        did_load = true
                                        try await taskGroup.addTask(/*priority: .userInitiated*/) {
                                            // XXX style the button during this flow?
                                            Log.d("actually loading outliers for frame \(frame.frameIndex)")
                                            try await frame.loadOutliers()
                                            // XXX set this in the view model

                                            Task {
                                                await MainActor.run {
                                                    Task {
                                                        viewModel.numberOfFramesWithOutliersLoaded += 1
                                                        await viewModel.setOutlierGroups(forFrame: frame)
                                                    }
                                                }
                                            }
                                        }
                                    } else {
                                        Log.d("frame \(frameView.frameIndex) no frame, can't load outliers")
                                    }
                                } else {
                                    Log.d("frame \(frameView.frameIndex) waiting \(current_running)")
                                    try await taskGroup.next()
                                    current_running -= 1
                                    Log.d("frame \(frameView.frameIndex) done waiting \(current_running)")
                                }
                            }
                        }
                        do {
                            try await taskGroup.waitForAll()
                        } catch {
                            Log.e("\(error)")
                        }
                        
                        let end_time = Date().timeIntervalSinceReferenceDate
                        viewModel.loadingAllOutliers = false
                        Log.d("foobar loaded outliers for \(viewModel.frames.count) frames in \(end_time - startTime) seconds")
                    }                                 
                } catch {
                    Log.e("\(error)")
                }
            }
        }
        
        return Button(action: action) {
            Text("Load All Outliers")
        }
          .help("Load all outlier groups for all frames.\nThis can take awhile.")
    }
}
