import AppKit
import StarCore
import logging

final class AppDelegate: NSObject, NSApplicationDelegate {

    // set by StarApp.onAppear so we can inspect processing state at quit time
    var viewModel: ViewModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let seq = viewModel?.imageSequence, seq.hasPendingWork else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Work In Progress"
        alert.informativeText =
            "Currently \(seq.pendingWorkDescription). " +
            "Quitting now will interrupt this work."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // user chose Cancel
            return .terminateCancel
        }
        // user chose Quit Anyway
        return .terminateNow
    }
}
