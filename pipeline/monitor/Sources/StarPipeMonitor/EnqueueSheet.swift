import AppKit
import StarPipeMonitorCore
import SwiftUI

/// The header's + sheet: issue links from the clipboard, each resolved to its title (or the daemon's reason for
/// refusing it) before Enqueue labels the valid ones `pipeline`.
struct EnqueueSheet: View {
    let store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = NSPasteboard.general.string(forType: .string) ?? ""
    @State private var resolved: [String: Resolution] = [:]
    @State private var enqueueing = false
    @State private var problems: [String] = []

    enum Resolution {
        case issue(ResolvedIssue)
        case rejected(String)
    }

    private var links: [String] { IssueLinks.parse(text) }

    /// The resolved, not-yet-queued issue numbers, one each even if two links name the same issue.
    private var enqueueable: [Int] {
        var seen = Set<Int>()
        return links.compactMap { link -> Int? in
            guard case .issue(let issue) = resolved[link], !issue.queued, seen.insert(issue.number).inserted else { return nil }
            return issue.number
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enqueue GitHub issues").font(.headline)
            Text("One or more issue links, separated by spaces or newlines.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90)
                .border(Color.secondary.opacity(0.3))
            List(links, id: \.self) { link in row(link) }
                .frame(minHeight: 140)
                .overlay { if links.isEmpty { Text("No links").foregroundStyle(.secondary) } }
            ForEach(problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Enqueue \(enqueueable.count)") { Task { await enqueue() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(enqueueable.isEmpty || enqueueing)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .task(id: text) { await resolveAll() }
    }

    @ViewBuilder
    private func row(_ link: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            switch resolved[link] {
            case nil:
                Text("resolving…").foregroundStyle(.secondary)
            case .issue(let issue) where issue.queued:
                Text("#\(issue.number) \(issue.title) — already queued").foregroundStyle(.secondary)
            case .issue(let issue):
                Text("#\(issue.number) \(issue.title)")
            case .rejected(let reason):
                Text(reason).foregroundStyle(.red)
            }
            Text(link).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
    }

    /// Resolve every link not yet resolved, after a short pause so typing does not hit GitHub per keystroke.
    private func resolveAll() async {
        try? await Task.sleep(for: .milliseconds(400))
        for link in links where resolved[link] == nil {
            if Task.isCancelled { return }
            switch await store.resolve(url: link) {
            case .success(let issue): resolved[link] = .issue(issue)
            case .failure(APIError.status(_, let reason)): resolved[link] = .rejected(reason)
            case .failure(let error): resolved[link] = .rejected(error.localizedDescription)
            }
        }
    }

    private func enqueue() async {
        enqueueing = true
        defer { enqueueing = false }
        problems = []
        guard let results = await store.enqueue(numbers: enqueueable) else {
            problems = ["Nothing was enqueued: \(store.lastError ?? "the daemon refused")"]
            return
        }
        problems = results.filter { $0.result != "labelled" && $0.result != "already queued" }.map { "#\($0.number): \($0.result)" }
        if problems.isEmpty { dismiss() }
    }
}
