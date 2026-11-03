import StarPipeMonitorCore
import SwiftUI

struct MonitorWindow: View {
    @Bindable var store: MonitorStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderStrip(store: store)
            Divider()
            NavigationSplitView {
                Sidebar(store: store)
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340)
            } detail: {
                if let ticket = store.selectedTicket {
                    TicketDetailView(store: store, ticket: ticket)
                        .id(ticket.number)
                } else if let issue = store.selectedIssue {
                    IssuePanelView(number: issue.number, title: issue.title, repo: store.snapshot?.repo ?? "")
                        .id(issue.number)
                } else {
                    OverviewView(store: store)
                }
            }
        }
        .scaledFont(.body)
        .onChange(of: store.selected) { Task { await store.refreshSelected() } }
    }
}

struct Chip: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .scaledFont(.caption2, weight: .medium)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// One top-bar stage counter: a big bold count over a one-line label on a rounded tinted tile.
/// Fixed-size, so a narrow window squeezes the header's text items instead of breaking the label inside a word.
struct CounterTile: View {
    let value: String
    let label: String
    let color: Color
    let emphasis: Overview.TileEmphasis

    var body: some View {
        VStack(spacing: 0) {
            Text(value)
                .scaledFont(.counter, weight: .bold)
                .foregroundStyle(emphasis == .idle ? Color.secondary : color)
                .lineLimit(1)
            Text(label)
                .scaledFont(.callout)
                .foregroundStyle(emphasis == .attention ? color : Color.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(minWidth: 56)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8)
            if emphasis == .attention {
                shape.fill(color.opacity(0.15))
                shape.strokeBorder(color.opacity(0.6), lineWidth: 1)
            } else {
                shape.fill(Color.secondary.opacity(0.1))
            }
        }
        .fixedSize()
    }
}

func stateColor(_ state: String) -> Color {
    switch state {
    case "needs-input": .orange
    case "failed", "cancelled": .red
    case "landed": .green
    case "queued", "paused": .gray
    default: .blue
    }
}

struct HeaderStrip: View {
    let store: MonitorStore
    @State private var enqueueing = false

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            Button { store.goBack() } label: { Image(systemName: "chevron.left") }
                .help("Back")
                .disabled(!store.canGoBack)
                .keyboardShortcut("[", modifiers: .command)
            Button { store.goForward() } label: { Image(systemName: "chevron.right") }
                .help("Forward")
                .disabled(!store.canGoForward)
                .keyboardShortcut("]", modifiers: .command)
            Button { store.showOverview() } label: { Image(systemName: "house") }
                .help("Back to the Overview")
                .disabled(store.selected == nil)
            attentionIndicator
            Spacer()
            usageLines
            counters
            Button { enqueueing = true } label: { Image(systemName: "plus") }
                .help("Enqueue GitHub issues from links")
            let muted = store.snapshot?.muted ?? false
            Button { Task { await store.setMuted(!muted) } } label: { Image(systemName: muted ? "speaker.slash" : "speaker.wave.2") }
                .help(muted ? "Unmute the pipeline's spoken alerts" : "Mute the pipeline's spoken alerts")
        }
        .sheet(isPresented: $enqueueing) { EnqueueSheet(store: store) }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .scaledFont(.caption)
    }

    /// Shown only while something needs a look; the details are in the Overview's "Pipeline status" section.
    @ViewBuilder private var attentionIndicator: some View {
        let words = Overview.attentionWords(store.statusRows)
        if !words.isEmpty {
            let color: Color = store.needsAttention ? .red : .orange
            Button { store.showOverview() } label: {
                HStack(spacing: 5) {
                    Circle().fill(color).frame(width: 8, height: 8)
                    Text(words.joined(separator: " · ")).foregroundStyle(color).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .help("Open the Overview for the pipeline status")
        }
    }

    /// The account's 5-hour and weekly usage limits, stacked; always shown ("—" until a stage reports) so the bar does not jump.
    private var usageLines: some View {
        let windows = store.snapshot?.usageWindows
        let now = Date.now
        let lines = [UsageLimitText.line(kind: .fiveHour, window: windows?.fiveHour, now: now, timeZone: .current),
                     UsageLimitText.line(kind: .weekly, window: windows?.sevenDay, now: now, timeZone: .current)]
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(lines.indices, id: \.self) { i in
                Text(lines[i].text).foregroundStyle(usageColor(lines[i].level)).lineLimit(1)
            }
        }
        .fixedSize()
        .layoutPriority(1)
    }

    private func usageColor(_ level: UsageLimitText.Level) -> Color {
        switch level {
        case .ok: .green
        case .warn: .yellow
        case .critical: .red
        case .unknown: .secondary
        }
    }

    /// The pipeline's load by stage; a dash for each while there is no snapshot (never stale or zero).
    private var counters: some View {
        HStack(alignment: .center, spacing: 6) {
            if let snapshot = store.snapshot {
                ForEach(Overview.topBarCounts(snapshot.tickets)) { c in
                    CounterTile(value: "\(c.count)", label: c.label, color: stateColor(c.states[0]), emphasis: c.emphasis)
                        .help("Counts tickets in: \(c.states.joined(separator: ", "))")
                }
            } else {
                ForEach(Overview.topBarBuckets, id: \.label) { b in
                    CounterTile(value: "—", label: b.label, color: .secondary, emphasis: .idle)
                        .help("Counts tickets in: \(b.states.joined(separator: ", "))")
                }
            }
        }
    }
}

struct Sidebar: View {
    @Bindable var store: MonitorStore

    var body: some View {
        VStack(spacing: 0) {
            Label("Overview", systemImage: "gauge.with.dots.needle.67percent")
                .scaledFont(.body, weight: .semibold)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(store.selected == nil ? Color.accentColor.opacity(0.2) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { store.showOverview() }
            Divider()
            List(selection: $store.selected) {
                ForEach(store.snapshot?.groups ?? [], id: \.self) { group in
                    let rows = store.tickets(in: group)
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { TicketRow(ticket: $0, repo: store.snapshot?.repo ?? "", onSelect: { store.selectIssue($0) }).tag($0.number) }
                        } header: {
                            Text(GroupTitle.title(group)).scaledFont(.body, weight: .semibold)
                        }
                    }
                }
            }
            .overlay {
                if store.snapshot?.tickets.isEmpty == true {
                    ContentUnavailableView {
                        Label("No tickets in flight", systemImage: "tray").scaledFont(.title2, weight: .bold)
                    }
                }
            }
        }
    }
}

struct TicketRow: View {
    let ticket: TicketSnap
    let repo: String
    var onSelect: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("#\(ticket.number)").monospacedDigit().foregroundStyle(.secondary)
                Text(ticket.title).lineLimit(1)
                Spacer()
                Chip(text: ticket.state, color: stateColor(ticket.state))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                activityLine
                Spacer(minLength: 0)
                if let model = ticket.model {
                    Text(model).scaledFont(.caption2, monospaced: true).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// `queued: #84, #85` with each blocker a button that shows that issue in the detail pane.
    @ViewBuilder
    private var activityLine: some View {
        if let row = BlockerLinks.row(activity: ticket.activity, blockedBy: ticket.blockedBy, repo: repo) {
            HStack(spacing: 0) {
                Text(row.prefix + " ").foregroundStyle(.secondary)
                ForEach(Array(row.links.enumerated()), id: \.element.id) { i, link in
                    if i > 0 { Text(", ").foregroundStyle(.secondary) }
                    Button(link.label) { onSelect(link.number) }.buttonStyle(.link).help("Show \(link.label) here")
                }
            }
            .scaledFont(.caption).lineLimit(1)
        } else {
            Text(ticket.activity).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}
