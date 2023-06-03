import SwiftUI
import StarCore

// this is the menu bar at the top of the screen

struct StarCommands: Commands {
    let contentView: ContentView

    var body: some Commands {
        CommandMenu("Actions") {
            contentView.paintAllButton()
              .keyboardShortcut("p", modifiers: [])

            contentView.clearAllButton()
              .keyboardShortcut("c", modifiers: [])

            contentView.outlierInfoButton()
            contentView.applyAllDecisionTreeButton()
            contentView.applyDecisionTreeButton()
            contentView.loadAllOutliersButton()
            contentView.renderCurrentFrameButton()
            contentView.renderAllFramesButton()
        }
        /*
         CommandGroup(replacing: .newItem) {
         //                  CommandMenu("File") {
         Button("New Window") {
         Log.e("NEW WINDOW")
         }
         //                  }
         }

         */

        CommandMenu("File") {
            Button("Close") {
                Log.e("CLOSE")
            }
            Button("Other Button") {
                Log.e("Other Button")
            }
        }
        CommandMenu("Playback") {
            Button("Show first frame") {
                contentView.goToFirstFrameButtonAction()
            }
            Button("Go back many frames") {
                contentView.fastPreviousButtonAction()
            }
            Button("Go back one frame") {
                contentView.transition(numberOfFrames: -1)
            }
            Button(contentView.video_playing ? "Pause Video" : "Play Video") {
                contentView.togglePlay()
            }
            Button("Advance one frame") {
                contentView.transition(numberOfFrames: 1)
            }
            Button("Advance many frames") {
                contentView.fastPreviousButtonAction()
            }
            Button("Show last frame") {
                contentView.goToFirstFrameButtonAction()
            }
        }
    }
}
