import SwiftUI
import StarCore

struct RenderAllFramesButton: View {
    @EnvironmentObject var viewModel: ViewModel
    
    var body: some View {
        let action: () -> Void = {
            Task {
                await withLimitedTaskGroup(of: Void.self) { taskGroup in
                    var number_to_save = 0
                    self.viewModel.renderingAllFrames = true
                    for frameView in viewModel.frames {
                        if let frame = frameView.frame,
                           let frameSaveQueue = viewModel.frameSaveQueue
                        {
                            await taskGroup.addTask() {
                                number_to_save += 1
                                frameSaveQueue.saveNow(frame: frame) {
                                    await viewModel.refresh(frame: frame)
                                    /*
                                     if frame.frame_index == viewModel.currentIndex {
                                     refreshCurrentFrame()
                                     }
                                     */
                                    number_to_save -= 1
                                    if number_to_save == 0 {
                                        self.viewModel.renderingAllFrames = false
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
