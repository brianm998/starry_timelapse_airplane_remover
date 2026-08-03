import AppKit
import SwiftUI
import StarCore
import logging

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // set by StarApp.onAppear so we can inspect processing state at quit time
    var viewModel: ViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let seq = viewModel?.imageSequence, seq.hasPendingWork else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = localized("ui.work_in_progress")
        alert.informativeText =
            localized("ui.work_in_progress.quitting", seq.pendingWorkDescription)
        alert.alertStyle = .warning
        alert.addButton(withTitle: localized("ui.cancel"))
        alert.addButton(withTitle: localized("ui.quit_anyway"))

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // user chose Cancel
            return .terminateCancel
        }
        // user chose Quit Anyway
        return .terminateNow
    }

    /// Clear the run marker on a normal quit, so the next launch does not report this as a
    /// crash.
    ///
    /// `finishWithoutWaiting()` rather than the actor's `finish()`: this hook is synchronous
    /// and the app is already on its way out, so there is no async context to await from and
    /// blocking the main thread here risks the work not completing at all.
    func applicationWillTerminate(_ notification: Notification) {
        RunMarkerStore.finishWithoutWaiting()
    }

    // Closing the main window goes through here so it mirrors Cmd-Q:
    // confirm if work is in progress, and unload the sequence so the
    // next time the window opens it starts from the initial view.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let viewModel = viewModel else { return true }

        if let seq = viewModel.imageSequence, seq.hasPendingWork {
            let alert = NSAlert()
            alert.messageText = localized("ui.work_in_progress")
            alert.informativeText =
                localized("ui.work_in_progress.closing", seq.pendingWorkDescription)
            alert.alertStyle = .warning
            alert.addButton(withTitle: localized("ui.cancel"))
            alert.addButton(withTitle: localized("ui.close_anyway"))

            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                return false
            }
        }

        viewModel.unloadSequence()
        return true
    }
}

// Captures the NSWindow that hosts the main ContentView so we can
// install our NSWindowDelegate on it.
struct MainWindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReadingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowReadingView)?.onWindow = onWindow
    }

    private final class WindowReadingView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window = self.window {
                onWindow?(window)
            }
        }
    }
}
