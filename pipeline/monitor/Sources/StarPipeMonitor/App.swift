import AppKit
import StarPipeMonitorCore
import SwiftUI

@main
struct StarPipeMonitorApp: App {
    @State private var store = MonitorStore()
    private let notifier = Notifier()

    var body: some Scene {
        Window("Star Pipeline", id: "main") {
            MonitorWindow(store: store)
                .frame(minWidth: 980, minHeight: 600)
                .task { await launch() }
        }
        MenuBarExtra {
            MenuBarContent(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
    }

    @MainActor
    private func launch() async {
        notifier.requestAuthorization()
        store.onAlert = { notifier.deliver($0) }
        do {
            store.start(client: APIClient(config: try APIConfig.load()))
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

struct MenuBarLabel: View {
    let store: MonitorStore

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: StarIcon.menuBarImage(for: store.pipelineState))
            if store.needsYouCount > 0 { Text("\(store.needsYouCount)") }
        }
        // The label is always alive (the window is not), so it keeps the Dock icon in step with the menu bar star.
        .onChange(of: store.pipelineState, initial: true) { _, state in
            NSApp.applicationIconImage = StarIcon.dockImage(for: state)
        }
    }
}

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let store: MonitorStore

    var body: some View {
        Text(store.needsYouCount == 0 ? "Nothing needs you" : "\(store.needsYouCount) need you")
        if store.daemonDown { Text("Daemon is not answering") }
        if let stop = store.snapshot?.landing.stopLine { Text("develop red: \(stop)") }
        Divider()
        if store.recentChanges.isEmpty {
            Text("No changes yet")
        } else {
            ForEach(store.recentChanges) { Text($0.text) }
        }
        Divider()
        Button("Open window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
