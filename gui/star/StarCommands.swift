import SwiftUI
import StarCore

// this is the menu bar at the top of the screen

struct StarCommands: Commands {
    let contentView: ContentView

    var body: some Commands {
        CommandMenu("Actions") {
            PaintAllButton(contentView: contentView)
              .keyboardShortcut("p", modifiers: [])
            ClearAllButton(contentView: contentView)
              .keyboardShortcut("c", modifiers: [])
            
            /*
            contentView.outlierInfoButton()
            contentView.applyAllDecisionTreeButton()
            contentView.applyDecisionTreeButton()
            contentView.renderCurrentFrameButton()
            contentView.renderAllFramesButton()
             */
            
            LoadAllOutliersButton(viewModel: contentView.viewModel)
        }

        // remove File -> New Window 
        CommandGroup(replacing: .newItem) { }
        
        // replace File -> Close 
        CommandGroup(replacing: .saveItem) {
            Button("Close") {
                Task {
                    await MainActor.run {
                        // XXX make sure the current sequence isn't still processing somehow
                        contentView.viewModel.unloadSequence()
                    }
                }
            }
        }
        CommandMenu("Playback") {
            Button("Show first frame") {
                contentView.imageSequenceView.goToFirstFrameButtonAction()
            }
            Button("Go back many frames") {
                contentView.imageSequenceView.fastPreviousButtonAction()
            }
            Button("Go back one frame") {
                contentView.imageSequenceView.transition(numberOfFrames: -1)
            }
            /*
            Button(contentView.viewModel.video_playing ? "Pause Video" : "Play Video") {
                contentView.imageSequenceView.togglePlay()
            }
             */
            Button("Advance one frame") {
                contentView.imageSequenceView.transition(numberOfFrames: 1)
            }
            Button("Advance many frames") {
                contentView.imageSequenceView.fastPreviousButtonAction()
            }
            Button("Show last frame") {
                contentView.imageSequenceView.goToFirstFrameButtonAction()
            }
        }
    }
}
