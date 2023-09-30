import SwiftUI
import StarCore

// this is the menu bar at the top of the screen

struct StarCommands: Commands {
    let viewModel: ViewModel

    var body: some Commands {
        CommandMenu("Actions") {

            PaintAllButton()
              .environmentObject(viewModel)
              .keyboardShortcut("p", modifiers: [])
            ClearAllButton()
              .environmentObject(viewModel)
              .keyboardShortcut("c", modifiers: [])
            /*
            contentView.outlierInfoButton()
             */
            ApplyAllDecisionTreeButton()
              .environmentObject(viewModel)
            ApplyDecisionTreeButton()
              .environmentObject(viewModel)
            RenderCurrentFrameButton()
              .environmentObject(viewModel)
            RenderAllFramesButton()
              .environmentObject(viewModel)
            LoadAllOutliersButton(loadingType: .fromCurrentFrame)
              .environmentObject(viewModel)
            LoadAllOutliersButton(loadingType: .all)
              .environmentObject(viewModel)
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
