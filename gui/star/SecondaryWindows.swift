import SwiftUI
import StarCore

/// The four secondary windows, as single-instance `Window` scenes (parity plan D11, M11).
///
/// Each Window-menu item and its ⌥ shortcut toggles its window: it opens it, or closes it when it is open.  It used to open a
/// new copy every time.  The outlier and alignment windows are about the open sequence, so their items are off without one and
/// the windows close when the sequence is unloaded; the blob and debug windows are not about a sequence and stay.  The desktop
/// client's windows behave the same.
enum SecondaryWindow: String, CaseIterable {
    case blob, outlier, alignment, debug

    var id: String {
        switch self {
        case .blob: return StarApp.blobProcessingStepsWindowName
        case .outlier: return StarApp.outlierGroupTableWindowName
        case .alignment: return StarApp.alignmentWindowName
        case .debug: return StarApp.debugWindowName
        }
    }

    /// Whether the window is about the open sequence: it needs one to be opened, and goes when the sequence does.
    var isAboutTheSequence: Bool { self == .outlier || self == .alignment }
}

/// Which secondary windows are open, kept up to date by the windows themselves as they appear and disappear.
struct SecondaryWindowState: Equatable {
    private(set) var open: Set<SecondaryWindow> = []

    enum MenuAction: Equatable { case open, close }

    mutating func appeared(_ window: SecondaryWindow) { open.insert(window) }
    mutating func disappeared(_ window: SecondaryWindow) { open.remove(window) }

    func menuAction(for window: SecondaryWindow) -> MenuAction { open.contains(window) ? .close : .open }

    func isMenuItemEnabled(_ window: SecondaryWindow, hasSequence: Bool) -> Bool {
        hasSequence || !window.isAboutTheSequence
    }

    /// What goes when the sequence is unloaded.
    var closingWithTheSequence: [SecondaryWindow] { SecondaryWindow.allCases.filter { $0.isAboutTheSequence && open.contains($0) } }
}

extension View {
    /// Tell the app that this secondary window is open for as long as its content is on screen.
    func secondaryWindow(_ window: SecondaryWindow, in viewModel: ViewModel) -> some View {
        self
          .onAppear { viewModel.secondaryWindows.appeared(window) }
          .onDisappear { viewModel.secondaryWindows.disappeared(window) }
    }
}

/// The Window menu's four items, after the system's window list.
struct SecondaryWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    let viewModel: ViewModel

    var body: some Commands {
        CommandGroup(after: .windowList) {
            Divider()
            item(.blob, label: localized("ui.blob_processing_window"), shortcut: "p")
            item(.outlier, label: localized("ui.outlier_information_window"), shortcut: "o")
            item(.alignment, label: localized("ui.alignment_information_window"), shortcut: "a")
            item(.debug, label: localized("ui.debug_window"), shortcut: "d")
        }
    }

    private func item(_ window: SecondaryWindow, label: String, shortcut: KeyEquivalent) -> some View {
        Button(label) {
            switch viewModel.secondaryWindows.menuAction(for: window) {
            case .open: openWindow(id: window.id)
            case .close: dismissWindow(id: window.id)
            }
        }
          .keyboardShortcut(shortcut, modifiers: [.option])
          .disabled(!viewModel.secondaryWindows.isMenuItemEnabled(window, hasSequence: viewModel.imageSequence != nil))
    }
}
