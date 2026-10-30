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
            CommandMenu(localized("menu.actions")) {
                RemoveAllButton()
                  .environment(viewModel)
                  .keyboardShortcut("a", modifiers: [])
                  .disabled(!viewModel.menuHotkeysEnabled)
                KeepAllButton()
                  .environment(viewModel)
                  .keyboardShortcut("k", modifiers: [])
                  .disabled(!viewModel.menuHotkeysEnabled)
                ClearUndecidedButton()
                  .environment(viewModel)
                  .keyboardShortcut("u", modifiers: [])
                  .disabled(!viewModel.menuHotkeysEnabled)
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
                  .disabled(!viewModel.menuHotkeysEnabled)
                ApplyDecisionTreeToAllFramesButton()
                  .environment(viewModel)
                  .disabled(!viewModel.menuHotkeysEnabled)
                ApplyDecisionTreeButton()
                  .environment(viewModel)
                RenderCurrentFrameButton()
                  .environment(viewModel)
                  .keyboardShortcut("r", modifiers: [])
                  .disabled(!viewModel.menuHotkeysEnabled)
                RenderAllFramesButton()
                  .environment(viewModel)
            }
            
            // this is really just here to enable keyboard shortcuts
            CommandMenu(localized("menu.tools")) {
                ChangeToolButton(tool: .remove)
                  .environment(viewModel)
                  .keyboardShortcut("1", modifiers: [])
                  .disabled(!viewModel.menuHotkeysEnabled)
                ChangeToolButton(tool: .keep)
                  .environment(viewModel)
                  .keyboardShortcut("2", modifiers: [])
                  .disabled(!viewModel.menuHotkeysEnabled)
                ChangeToolButton(tool: .razor)
                  .environment(viewModel)
                  .keyboardShortcut("3", modifiers: [])
                  .disabled(!viewModel.menuHotkeysEnabled)
                ChangeToolButton(tool: .shovel)
                  .environment(viewModel)
                  .keyboardShortcut("4", modifiers: [])
                  .disabled(!viewModel.menuHotkeysEnabled)
                ChangeToolButton(tool: .trash)
                  .environment(viewModel)
                  .keyboardShortcut("5", modifiers: [])
                  .disabled(!viewModel.menuHotkeysEnabled)
                ChangeToolButton(tool: .removeFromTrash)
                  .environment(viewModel)
                  .keyboardShortcut("6", modifiers: [])
                  .disabled(!viewModel.menuHotkeysEnabled)
                ChangeToolButton(tool: .multi)
                  .environment(viewModel)
                  .keyboardShortcut("7", modifiers: [])
                  .disabled(!viewModel.menuHotkeysEnabled)
                ChangeToolButton(tool: .information)
                  .environment(viewModel)
                  .keyboardShortcut("8", modifiers: [])
                  .disabled(!viewModel.menuHotkeysEnabled)

                Divider()

                // E — switch to edit interaction mode
                Button(localized("ui.edit_mode")) {
                    viewModel.interactionMode = .edit
                }
                .environment(viewModel)
                .keyboardShortcut("e", modifiers: [])
                .disabled(!viewModel.menuHotkeysEnabled)

                // S — switch to scrub interaction mode.
                // Disabled while the user is painting horizons on
                // manual keyframes for a moving video, since switching
                // interaction mode there leaves the user in a weird state.
                Button(localized("ui.scrub_mode")) {
                    viewModel.interactionMode = .scrub
                }
                .environment(viewModel)
                .keyboardShortcut("s", modifiers: [])
                .disabled(!viewModel.menuHotkeysEnabled)
                .disabled(viewModel.isShowingHorizonPainter
                          && viewModel.horizonPainterMode == .startup)

                // G — switch to grid mode (Lightroom-style thumbnail grid)
                Button(localized("ui.grid_mode")) {
                    viewModel.interactionMode = .grid
                }
                .environment(viewModel)
                .keyboardShortcut("g", modifiers: [])
                .disabled(!viewModel.menuHotkeysEnabled)

                // H — toggle the horizon painter overlay
                Button(viewModel.isShowingHorizonPainter
                       ? localized("ui.close_horizon_painter")
                       : localized("ui.paint_horizon_reference")) {
                    // The painter is drawn over the edit view: opened from scrub or grid it showed nothing, and every
                    // key that belongs to the edit view (E/S/G/A/K/U/R/D/1-8) went dead behind it.
                    if !viewModel.isShowingHorizonPainter, viewModel.interactionMode != .edit {
                        viewModel.interactionMode = .edit
                    }
                    viewModel.isShowingHorizonPainter.toggle()
                }
                .environment(viewModel)
                .keyboardShortcut("h", modifiers: [])
                .disabled(viewModel.isProcessingModalUp)

                // Toggle side panels. The tab keyboard shortcut for this
                // is handled by TabCatcher inside ImageSequenceView, since
                // SwiftUI traps tab and won't deliver it to a CommandMenu.
                Button(localized("ui.toggle_side_panels")) {
                    viewModel.toggleSidePanels()
                }
                .environment(viewModel)
            }
            
        }

        // remove File -> New Window
        CommandGroup(replacing: .newItem) { }

        // replace File -> Close
        CommandGroup(replacing: .saveItem) {
            Button(localized("ui.close")) {
                Task { @MainActor in
                    if let seq = viewModel.imageSequence, seq.hasPendingWork {
                        viewModel.closeConfirmationMessage =
                            localized("ui.work_in_progress.closing",
                                      seq.pendingWorkDescription)
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

        // Add Preferences to the app menu
        CommandGroup(replacing: .appSettings) {
            Button(localized("menu.preferences")) {
                viewModel.showUserPreferencesSheet = true
            }
            .keyboardShortcut(",", modifiers: [.command])

            // Star ▸ Language ▸ …, immediately below Preferences. The app menu is where macOS
            // users look for a setting that is about the app rather than about the document,
            // and a checkmarked submenu is the standard shape for a one-of-many choice.
            //
            // Each language is listed in its own script, which is the point: someone who has
            // landed in a language they cannot read has to be able to find their way out by
            // recognising their own, and a list of English names would not let them.
            Menu(localized("language.menu")) {
                Button {
                    viewModel.setLanguage(nil)
                } label: {
                    // A leading checkmark rather than `Toggle`, so the label keeps its native
                    // script instead of being reflowed by a control style.
                    Text(viewModel.isFollowingSystemLanguage
                           ? "✓ " + localized("language.follow_system")
                           : "   " + localized("language.follow_system"))
                }

                Divider()

                ForEach(viewModel.availableLanguages) { language in
                    Button {
                        viewModel.setLanguage(language)
                    } label: {
                        let selected = !viewModel.isFollowingSystemLanguage
                          && viewModel.languageCode == language.code
                        Text((selected ? "✓ " : "   ") + language.nativeName)
                    }
                }
            }
        }
    }
}
