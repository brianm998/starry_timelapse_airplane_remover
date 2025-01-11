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
         each task group has its own semaphore that determins when it starts
         at first just set them all to wait on their semaphore, and create
         all the tasks that are needed.

         afterwards, start the tasks in order according to how many should run

         then when one finishes, start another
         */
        try? await withThrowingTaskGroup(of: FrameAirplaneRemover.self) { taskGroup in
            var semaphores = await [AsyncSemaphore?](repeating: nil, count: viewModel.frames.count)
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

            for try await frame in taskGroup {
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

                // then see about final processing
                while await self.finalProcess(frames: viewModel.frames,
                                              currentIndex: currentIndex,
                                              numNeighbors: numNeighbors)
                {
                    currentIndex += 1
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

    // process frames that are ready for inter frame processing
    // apply decision tree to outliers
    // render processed output file
    func finalProcess(frames: [FrameViewModel],
                      currentIndex: Int,
                      numNeighbors: Int) async -> Bool
    {
        guard let viewModel,
              currentIndex >= 0,
              currentIndex < frames.count else { return false }
        guard let frame = await frames[currentIndex].frame else { return false }

        if await frame.processingState() == .complete { return true }
        
        var minFrameIndex = frame.frameIndex - numNeighbors
        var maxFrameIndex = frame.frameIndex + numNeighbors
        if minFrameIndex < 0 { minFrameIndex = 0 }
        if maxFrameIndex >= frames.count { maxFrameIndex = frames.count - 1 }
        var positiveCount = 0
        for i in minFrameIndex...maxFrameIndex {
            if let frame = await frames[i].frame,
               await frame.processingState().isReadyForInterframeProcessing
            {
                positiveCount += 1
            }
        }

        if positiveCount == maxFrameIndex - minFrameIndex + 1 {
            // we can now move this one further
            Task.detached(priority: .high) {

                // mark that we're processing
                await viewModel.finalProcessingCount.increase()
                
                await finalSemaphore.wait()
                Log.d("finalProcess currentIndex \(currentIndex)")
                if await frame.processingState() != .complete {

                    await frame.set(state: .interFrameProcessing)
                    
                    await frame.applyDecisionTreeToAllOutliers()

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

                    await viewModel.setOutlierGroups(forFrame: frame)
                    await MainActor.run {
                        viewModel.numberOfFramesProcessed += 1
                    }

                } else {
                    await MainActor.run {
                        viewModel.numberOfFramesProcessed += 1
                    }
                }
                await viewModel.finalProcessingCount.decrease()
                finalSemaphore.signal()
            }
            Log.d("final process done at index \(currentIndex)")
            return true
        }
        return false
    }
}
