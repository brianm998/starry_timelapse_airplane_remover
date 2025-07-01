import SwiftUI
import StarCore

// this is the menu bar at the top of the screen

struct StarCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    let viewModel: ViewModel

    var body: some Commands {
        if let viewModel = viewModel.imageSequence {
            CommandMenu("Actions") {
                RemoveAllButton()
                  .environment(viewModel)
                  .keyboardShortcut("a", modifiers: [])
                KeepAllButton()
                  .environment(viewModel)
                  .keyboardShortcut("k", modifiers: [])
                ClearUndecidedButton()
                  .environment(viewModel)
                  .keyboardShortcut("u", modifiers: [])
                ProcessAllFramesButton()
                  .environment(viewModel)
                ProcessRemainingFramesButton()
                  .environment(viewModel)
                ReProcessCurrentFrameButton()
                  .environment(viewModel)
                FindOutliersOnCurrentFrameButton()            
                  .environment(viewModel)
                ApplyAllDecisionTreeButton()
                  .environment(viewModel)
                ApplyDecisionTreeButton()
                  .environment(viewModel)
                RenderCurrentFrameButton()
                  .environment(viewModel)
                  .keyboardShortcut("r", modifiers: [])
                RenderAllFramesButton()
                  .environment(viewModel)
                LoadAllOutliersButton(loadingType: .fromCurrentFrame)
                  .environment(viewModel)
                LoadAllOutliersButton(loadingType: .all)
                  .environment(viewModel)
            }
            
            // this is really just here to enable keyboard shortcuts 
            CommandMenu("Tools") {
                ChangeToolButton(tool: .remove)
                  .environment(viewModel)
                  .keyboardShortcut("1", modifiers: [])
                ChangeToolButton(tool: .keep)
                  .environment(viewModel)
                  .keyboardShortcut("2", modifiers: [])
                ChangeToolButton(tool: .razor)
                  .environment(viewModel)
                  .keyboardShortcut("3", modifiers: [])
                ChangeToolButton(tool: .shovel)
                  .environment(viewModel)
                  .keyboardShortcut("4", modifiers: [])
                ChangeToolButton(tool: .trash)
                  .environment(viewModel)
                  .keyboardShortcut("5", modifiers: [])
                ChangeToolButton(tool: .removeFromTrash)
                  .environment(viewModel)
                  .keyboardShortcut("6", modifiers: [])
                ChangeToolButton(tool: .multi)
                  .environment(viewModel)
                  .keyboardShortcut("7", modifiers: [])
                ChangeToolButton(tool: .information)
                  .environment(viewModel)
                  .keyboardShortcut("8", modifiers: [])
            }
            
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
