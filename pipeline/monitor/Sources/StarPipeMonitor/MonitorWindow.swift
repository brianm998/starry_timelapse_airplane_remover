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
        HStack(alignment: .top, spacing: 22) {
            item("Daemon", daemonText, color: store.daemonDown ? .red : .green)
            item("Heavy lock", lockText, color: .secondary)
            item("Landing", landingText, color: store.snapshot?.landing.paused == true || store.developRed ? .orange : .secondary)
            item("develop", developText, color: store.developRed ? .red : .secondary)
            if let until = store.snapshot?.usagePauseUntil, let t = Double(until) {
                item("Usage limit", "model stages wait until \(Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .shortened))", color: .orange)
            }
            if store.updateAvailable {
                item("Monitor", "Update available — \(MonitorUpdates.rebuildCommand)", color: .orange)
            }
            if let pause = store.snapshot?.pause { item("Paused", pause, color: .orange) }
            item("Last nightly", store.snapshot?.nightly?.line ?? "none yet",
                 color: (store.snapshot?.nightly?.reds ?? 0) > 0 || store.snapshot?.nightly?.status == "error" ? .orange : .secondary)
            Spacer()
            if let week = store.snapshot?.interventionsWeek, !week.isEmpty {
                item("Interventions (7 d)", week.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "), color: .secondary)
            }
            Button { enqueueing = true } label: { Image(systemName: "plus") }
                .help("Enqueue GitHub issues from links")
        }
        .sheet(isPresented: $enqueueing) { EnqueueSheet(store: store) }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .scaledFont(.caption)
    }

    private func item(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).foregroundStyle(.secondary)
            Text(value).foregroundStyle(color).lineLimit(2)
        }
    }

    private var daemonText: String {
        if case .down(let why) = store.connection { return "down: \(why)" }
        guard let s = store.snapshot else { return "connecting…" }
        let behind = s.runtime.behindDevelop > 0 ? ", behind develop by \(s.runtime.behindDevelop)" : ""
        return "up, \(s.runtime.sha)\(behind)"
    }

    private var lockText: String {
        guard let heavy = store.snapshot?.heavy else { return "—" }
        guard let h = heavy.holders.first else { return heavy.queue.isEmpty ? "idle" : "\(heavy.queue.count) waiting" }
        let elapsed = Int((store.snapshot?.now ?? h.since) - h.since)
        let who = h.ticket.isEmpty ? "interactive" : "#\(h.ticket)"
        return "\(who) \(h.cmd.prefix(36)) \(elapsed / 60)m" + (heavy.queue.isEmpty ? "" : " · \(heavy.queue.count) queued")
    }

    private var landingText: String {
        guard let l = store.snapshot?.landing else { return "—" }
        if let stop = l.stopLine { return "stopped: \(stop)" }
        return l.paused ? "paused" : "running"
    }

    private var developText: String {
        guard let d = store.snapshot?.develop else { return "—" }
        let gate = d.gate.isEmpty ? "pr-gate: no data" : "pr-gate " + (d.gate.values.allSatisfy { $0 == "success" } ? "green" : "red")
        return "\(gate), \(d.knownRed) known red"
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
                .onTapGesture { store.selected = nil }
            Divider()
            List(selection: $store.selected) {
                ForEach(store.snapshot?.groups ?? [], id: \.self) { group in
                    let rows = store.tickets(in: group)
                    if !rows.isEmpty {
                        Section {
                            ForEach(rows) { TicketRow(ticket: $0).tag($0.number) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("#\(ticket.number)").monospacedDigit().foregroundStyle(.secondary)
                Text(ticket.title).lineLimit(1)
                Spacer()
                Chip(text: ticket.state, color: stateColor(ticket.state))
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ticket.activity).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if let model = ticket.model {
                    Text(model).scaledFont(.caption2, monospaced: true).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
