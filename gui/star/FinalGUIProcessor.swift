import SwiftUI
import StarCore
import Semaphore
import logging

// used for finding outliers in frames when processing
public let maxFramesProcessing = IntegralActor(value: 20) // XXX read this initial value from #-CPU's

// used for final processing (categorizing, painting, saving)
fileprivate let finalSemaphore = AsyncSemaphore(value: 40) // XXX make this configurable

public actor FinalGUIProcessor {
    weak var viewModel: ImageSequenceViewModel?
    
    public init(_ viewModel: ImageSequenceViewModel) {
        self.viewModel = viewModel
    }

    func processAllFrames() async {
        guard let viewModel else { return }


        /*
         each task group has its own semaphore that determines when it starts
         at first just set them all to wait on their semaphore, and create
         all the tasks that are needed.

         afterwards, start the tasks in order according to how many should run

         then when one finishes, start another
         */
        try? await withThrowingTaskGroup(of: FrameAirplaneRemover.self) { taskGroup in
            let framesCount = await viewModel.frames.count
            var semaphores = [AsyncSemaphore?](repeating: nil, count: framesCount)
            var haveOutliers = [Bool](repeating: false, count: framesCount)
            var haveFinalProcessed = [Bool](repeating: false, count: framesCount)
            var numberFramesProcessing: Int = 0
            for (index, frameView) in await viewModel.frames.enumerated() {
                if let frame = await frameView.frame {
                    let semaphore = AsyncSemaphore(value: 0)
                    semaphores[index] = semaphore
                    taskGroup.addTask() {
                        await semaphore.wait()
                        if await !frame.processingState().isReadyForInterframeProcessing {
                            // this frame needs to have outliers found

                            // pause when the final processer has more than this many
                            // actually processing at once (not waiting for processing)
                            while await viewModel.finalProcessingCount.isMore(than: 20) { // XXX constant
                                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                            }
                            
                            await MainActor.run {
                                frameView.outliersLoaded = .loading
                            }
                            await self.findOutliers(frame: frame)
                            await MainActor.run {
                                frameView.outliersLoaded = .loaded
                            }
                        } else {
                            // this frame should already have outliers,  just load them
                            try await frame.loadOutliers(loadOnly: true)
                            await MainActor.run {
                                viewModel.numberOfFramesProcessed += 1
                                frameView.outliersLoaded = .loaded
                            }
                        }
                        return frame
                    }
                }
            }
            
            Log.d("processAllFrames 2")
            
            var num_processed = 0
            var signalIndex = 0
            
            while await num_processed < maxFramesProcessing.getValue(),
                  signalIndex < semaphores.count
            {
                if let semaphore = semaphores[signalIndex] {
                    semaphore.signal()
                    semaphores[signalIndex] = nil
                    num_processed += 1
                }
                signalIndex += 1
            }

            numberFramesProcessing = num_processed

            var currentIndex = 0
            let numNeighbors = await viewModel.config?.config().numberFinalProcessingNeighborsNeeded ?? 1

            /*

             new approach:

             keep an boolean array of frames that have outliers or not, indexed by frameIndex

             at first, iterate through all indexs in the outlier array,
             starting final processing on any frames that meet the criteria.

             then start initial process of remaining frames.
             
             upon return of a frame from the taskgroup,
             update the array with the new frame.

             look for any frames withing criteria distance and see if they match based upon the
             array.  Run final processing on any frames at the top level of the histogram,

             ideally in parallel with a sub-task group
             (or maybe same task group, but return with different frame state?)
             
             */


            for try await frame in taskGroup {
                haveOutliers[frame.frameIndex] = true
                // first see if we can start any more frames processing
                numberFramesProcessing -= 1

                while await numberFramesProcessing < maxFramesProcessing.getValue(),
                      signalIndex < semaphores.count
                {
                    if let semaphore = semaphores[signalIndex] {
                        semaphore.signal()
                        semaphores[signalIndex] = nil
                        numberFramesProcessing += 1
                    }
                    signalIndex += 1
                }
                Log.d("got frame \(frame) currentIndex \(currentIndex)")

                var startIndex = frame.frameIndex - numNeighbors
                if startIndex < 0 { startIndex = 0 }
                var endIndex = frame.frameIndex + numNeighbors
                if endIndex >= framesCount { endIndex = framesCount }

                for frameIndex in startIndex..<endIndex {
                    if !haveFinalProcessed[frameIndex] {

                        var outlierCheckStartIndex = frameIndex - numNeighbors
                        if outlierCheckStartIndex < 0 { outlierCheckStartIndex = 0 }
                        var outlierCheckEndIndex = frameIndex + numNeighbors
                        if outlierCheckEndIndex >= framesCount { outlierCheckEndIndex = framesCount }

                        var haveEnoughOutliers = true
                        for outlierCheckIndex in outlierCheckStartIndex..<outlierCheckEndIndex {
                            if !haveOutliers[outlierCheckIndex] {
                                haveEnoughOutliers = false
                                break
                            }
                        }

                        if haveEnoughOutliers {
                            Task.detached(priority: .userInitiated) {
                                await finalProcess(atIndex: frameIndex,
                                                   frames: viewModel.frames,
                                                   viewModel: viewModel)
                            }
                            haveFinalProcessed[frameIndex] = true
                        }
                    }
                }
            }
            for frameIndex in 0..<framesCount {
                if !haveFinalProcessed[frameIndex] {
                    Task.detached(priority: .userInitiated) {
                        await finalProcess(atIndex: frameIndex,
                                           frames: viewModel.frames,
                                           viewModel: viewModel)
                    }
                    haveFinalProcessed[frameIndex] = true
                }
            }
            Log.d("processAllFrames done")
        }
    }

    // find outliers but don't render now
    func findOutliers(frame: FrameAirplaneRemover) async {
        do {
            try await frame.loadOutliers()
            Task { @MainActor in
                if let frameView = await viewModel?.frames[frame.frameIndex] {
                    frameView.outlierViews = nil
                }
                await viewModel?.setOutlierGroups(forFrame: frame)
            }
            await frame.set(state: .readyForInterFrameProcessing)
        } catch {
            Log.e("error finding outliers for frame \(frame.frameIndex): \(error)")
        }
    }

}


// process frames that are ready for inter frame processing
// apply decision tree to outliers
// render processed output file
fileprivate func finalProcess(atIndex currentIndex: Int,
                              frames: [FrameViewModel],
                              viewModel: ImageSequenceViewModel) async
{
    guard let frame = await frames[currentIndex].frame else { return }

    if await frame.processingState() == .complete { return }
    
    // we can now move this one further
    Log.d("frame \(frame.frameIndex) about to final process")

    // mark that we're processing
    Task { @MainActor in
        await viewModel.finalProcessingCount.increase()
    }
    
    //await finalSemaphore.wait()
    Log.d("finalProcess currentIndex \(currentIndex)")
    if await frame.processingState() != .complete {

        Log.d("frame \(frame.frameIndex) about to final process step 3")

        await frame.set(state: .secondClassification)
        
        await frame.applyDecisionTreeToAllOutliers(includingDustbin: viewModel.shouldShowDustbin)
      
        await frame.set(state: .outlierProcessingComplete)

        await frame.set(frameSavingState: .saving)
        Log.d("frame \(frame.frameIndex) saveNow for real")
        do {

            try await frame.loadOutliers()
            try await frame.finish()
            await frame.changesHandled()
        } catch {
            Log.e("frame \(frame.frameIndex) frame save error: \(error)")
        }
        await frame.set(frameSavingState: .notSaving)

        Task { @MainActor in
            await viewModel.setOutlierGroups(forFrame: frame)
            viewModel.numberOfFramesProcessed += 1
        }

    } else {
        Log.d("frame \(frame.frameIndex) about to final process already complete")
        Task { @MainActor in
            viewModel.numberOfFramesProcessed += 1
        }
    }
    Task { @MainActor in
        await viewModel.finalProcessingCount.decrease()
    }
    //finalSemaphore.signal()

    Log.d("final process done at index \(currentIndex)")
}
