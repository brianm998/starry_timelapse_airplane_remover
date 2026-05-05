import SwiftUI
import StarCore

// this is the menu bar at the top of the screen

// SwiftUI's focus system traps the tab key, so a CommandMenu
// keyboardShortcut(KeyEquivalent("\t")) never fires. Drop this
// NSView into the hierarchy to intercept tab keyDown directly.
struct TabCatcher: NSViewRepresentable {
    let onTab: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCatchingView()
        view.onTab = onTab
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? KeyCatchingView)?.onTab = onTab
    }

    private class KeyCatchingView: NSView {
        var onTab: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 48 {
                onTab?()
            } else {
                super.keyDown(with: event)
            }
        }
    }
}

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

                Divider()

                // E — switch to edit interaction mode
                Button("Edit Mode") {
                    viewModel.interactionMode = .edit
                }
                .environment(viewModel)
                .keyboardShortcut("e", modifiers: [])

                // S — switch to scrub interaction mode.
                // Disabled while the user is painting horizons on
                // manual keyframes for a moving video, since switching
                // interaction mode there leaves the user in a weird state.
                Button("Scrub Mode") {
                    viewModel.interactionMode = .scrub
                }
                .environment(viewModel)
                .keyboardShortcut("s", modifiers: [])
                .disabled(viewModel.isShowingHorizonPainter
                          && viewModel.horizonPainterMode == .startup)

                // H — toggle the horizon painter overlay
                Button(viewModel.isShowingHorizonPainter
                       ? "Close Horizon Painter"
                       : "Paint Horizon Reference") {
                    viewModel.isShowingHorizonPainter.toggle()
                }
                .environment(viewModel)
                .keyboardShortcut("h", modifiers: [])

                // Toggle side panels. The tab keyboard shortcut for this
                // is handled by TabCatcher inside ImageSequenceView, since
                // SwiftUI traps tab and won't deliver it to a CommandMenu.
                Button("Toggle Side Panels") {
                    viewModel.toggleSidePanels()
                }
                .environment(viewModel)
            }
            
        }

        // remove File -> New Window 
        CommandGroup(replacing: .newItem) { }
        
        // replace File -> Close
        CommandGroup(replacing: .saveItem) {
            Button("Close") {
                Task { @MainActor in
                    if let seq = viewModel.imageSequence, seq.hasPendingWork {
                        viewModel.closeConfirmationMessage =
                            "Currently \(seq.pendingWorkDescription). " +
                            "Closing now will interrupt this work."
                        viewModel.closeConfirmationAction = {
                            viewModel.unloadSequence()
                        }
                        viewModel.showCloseConfirmation = true
                    } else {
                        viewModel.unloadSequence()
                    }
                }
            }
        }
    }
}
