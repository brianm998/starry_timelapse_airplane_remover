import SwiftUI
import StarCore
import logging

enum OutlierLodingType {
    case all
    case fromCurrentFrame
}

fileprivate let taskMaster = TaskMaster(maxConcurrentTasks: 2) // XXX guess

struct LoadAllOutliersButton: View {
    @EnvironmentObject var viewModel: ViewModel
    let loadingType: OutlierLodingType
    
    var body: some View {
        let action: () -> Void = {
            Task {
                do {
                    let startTime = Date().timeIntervalSinceReferenceDate
                    Log.d("starting load with task mster \(taskMaster)")
                    try await withLimitedThrowingTaskGroup(of: Void.self, with: taskMaster) { taskGroup in
                        let max_concurrent = ProcessInfo.processInfo.activeProcessorCount
                        // this gets "Too many open files" with more than 2000 images :(
                        viewModel.loadingAllOutliers = true
                        Log.d("foobar starting")
                        if loadingType == .all {
                            viewModel.numberOfFramesWithOutliersLoaded = 0
                        }
                        for frameView in viewModel.frames {
                            if loadingType == .fromCurrentFrame,
                               frameView.frameIndex < viewModel.currentIndex
                            {
                                Log.d("skipping loading outliers for frame \(frameView.frameIndex)")
                                continue
                            }

                            Log.d("frame \(frameView.frameIndex) attempting to load outliers")
                            if let frame = frameView.frame {
                                Log.d("frame \(frameView.frameIndex) adding task to load outliers")
                                try await taskGroup.addTask(/*priority: .userInitiated*/) {
                                    // XXX style the button during this flow?
                                    Log.d("actually loading outliers for frame \(frame.frameIndex)")
                                    try await frame.loadOutliers()
                                    // XXX set this in the view model

                                    await MainActor.run {
                                        Task {
                                            viewModel.numberOfFramesWithOutliersLoaded += 1
                                            await viewModel.setOutlierGroups(forFrame: frame)
                                        }
                                    }
                                }
                            } else {
                                Log.d("frame \(frameView.frameIndex) no frame, can't load outliers")
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

        switch loadingType {
        case .all:
            return Button(action: action) {
                Text("Load All Outliers")
            }
              .help("Load all outlier groups for all frames.\nThis can take awhile.")
        case .fromCurrentFrame:
            return Button(action: action) {
                Text("Load Outliers to End")
            }
              .help("Load all outlier groups for frames from the current index to the end.\nThis can take awhile.")
        }
    }
}
