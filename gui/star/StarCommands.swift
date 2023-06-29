import SwiftUI
import StarCore

// this is the menu bar at the top of the screen

struct StarCommands: Commands {
    let contentView: ContentView

    var body: some Commands {
        CommandMenu("Actions") {

            PaintAllButton(viewModel: contentView.viewModel)
              .keyboardShortcut("p", modifiers: [])
            ClearAllButton(viewModel: contentView.viewModel)
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
    }
}
