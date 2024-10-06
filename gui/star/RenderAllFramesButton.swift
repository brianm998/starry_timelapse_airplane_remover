import SwiftUI
import StarCore


fileprivate actor CounterActor {
    private var count: Int = 0

    func increment() { count += 1 }
    func decrement() { count -= 1 }

    func value() { count }

    func isAboveZero() -> Bool { count > 0 }
}

struct RenderAllFramesButton: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    
    var body: some View {
        let action: () -> Void = {
            let foobar = viewModel
            self.viewModel.renderingAllFrames = true
            let frameSaveQueue = viewModel.frameSaveQueue
            Task {
                await withTaskGroup(of: Void.self) { taskGroup in
//                await withLimitedTaskGroup(of: Void.self) { taskGroup in
/// does this break things when saving thousands of frames at once?

                    let counter = CounterActor()
                    for frameView in viewModel.frames {
                        if let frame = frameView.frame {
                            taskGroup.addTask() {
                                await counter.increment()
                                await frameSaveQueue.saveNow(frame: frame) {
                                    await viewModel.refresh(frame: frame)
                                    /*
                                     if frame.frameIndex == viewModel.currentIndex {
                                     refreshCurrentFrame()
                                     }
                                     */
                                    await counter.decrement()
                                    if !(await counter.isAboveZero()) {
                                        await MainActor.run {
                                            self.viewModel.renderingAllFrames = false
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    await taskGroup.waitForAll()
                }
            }
        }
        
        return Button(action: action) {
            Text("Render All Frames")
        }
          .help("Render all frames of this sequence with current settings")
    }    
}
