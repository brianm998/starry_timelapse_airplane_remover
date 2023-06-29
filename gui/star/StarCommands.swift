import SwiftUI
import StarCore

// this is the menu bar at the top of the screen

struct StarCommands: Commands {
    let viewModel: ViewModel

    var body: some Commands {
        CommandMenu("Actions") {

            PaintAllButton(viewModel: viewModel)
              .keyboardShortcut("p", modifiers: [])
            ClearAllButton(viewModel: viewModel)
              .keyboardShortcut("c", modifiers: [])
            
            /*
            contentView.outlierInfoButton()
            contentView.applyAllDecisionTreeButton()
            contentView.applyDecisionTreeButton()
             */
            RenderCurrentFrameButton(viewModel: viewModel)
            RenderAllFramesButton(viewModel: viewModel)
            
            LoadAllOutliersButton(viewModel: viewModel)
        }

        // remove File -> New Window 
        CommandGroup(replacing: .newItem) { }
        
        // replace File -> Close 
        CommandGroup(replacing: .saveItem) {
            Button("Close") {
                Task {
                    await MainActor.run {
                        // XXX make sure the current sequence isn't still processing somehow
                        viewModel.unloadSequence()
                    }
                }
            }
        }
    }
}
