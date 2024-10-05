import SwiftUI
import StarCore

// this is the menu bar at the top of the screen

struct StarCommands: Commands {
    let viewModel: ViewModel

    var body: some Commands {
        CommandMenu("Actions") {

            PaintAllButton()
              .environment(viewModel)
              .keyboardShortcut("p", modifiers: [])
            ClearAllButton()
              .environment(viewModel)
              .keyboardShortcut("c", modifiers: [])
            ClearUndecidedButton()
              .environment(viewModel)
              .keyboardShortcut("k", modifiers: [])
            /*
            contentView.outlierInfoButton()
             */
            ApplyAllDecisionTreeButton()
              .environment(viewModel)
            ApplyDecisionTreeButton()
              .environment(viewModel)
            RenderCurrentFrameButton()
              .environment(viewModel)
            RenderAllFramesButton()
              .environment(viewModel)
            LoadAllOutliersButton(loadingType: .fromCurrentFrame)
              .environment(viewModel)
            LoadAllOutliersButton(loadingType: .all)
              .environment(viewModel)
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
