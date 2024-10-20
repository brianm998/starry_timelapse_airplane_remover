import SwiftUI
import StarCore
import logging

enum OutlierLodingType {
    case all
    case fromCurrentFrame
}

struct LoadAllOutliersButton: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    let loadingType: OutlierLodingType
    
    var body: some View {
        let action: () -> Void = {
            Log.d("load all outliers button pressed")
            Task // XXX why does this fail when using a detached task?
                 // it runs, takes forever, and outliers never show up on the UI :(
//            Task.detached(executorPreference: nil,
//                          priority: .userInitiated)
            {
                Log.d("load all outliers button pressed 1")
                do {
                    let startTime = Date().timeIntervalSinceReferenceDate
                    try await withLimitedThrowingTaskGroup(of: Void.self) { taskGroup in
                        Log.d("load all outliers button pressed 2x")
                        let max_concurrent = ProcessInfo.processInfo.activeProcessorCount
                        // this gets "Too many open files" with more than 2000 images :(
                        await MainActor.run {
                            viewModel.loadingAllOutliers = true
                            Log.d("foobar starting")
                            if loadingType == .all {
                                viewModel.numberOfFramesWithOutliersLoaded = 0
                            }
                        }
                        for frameView in await viewModel.frames {
                            if loadingType == .fromCurrentFrame,
                               await frameView.frameIndex < viewModel.currentIndex
                            {
                                Log.d("skipping loading outliers for frame \(frameView.frameIndex)")
                                continue
                            }

                            Log.d("frame \(frameView.frameIndex) attempting to load outliers")
                            if let frame = await frameView.frame {
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
                        await MainActor.run {
                            viewModel.loadingAllOutliers = false
                        }
                      Log.d("foobar loaded outliers for \(await viewModel.frames.count) frames in \(end_time - startTime) seconds")
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
