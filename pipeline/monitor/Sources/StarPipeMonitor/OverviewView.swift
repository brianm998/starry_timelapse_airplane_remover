import StarPipeMonitorCore
import SwiftUI

/// The detail pane when no ticket is selected: which models are running what, how many tickets may run at once,
/// and the landing queue.
struct OverviewView: View {
    @Bindable var store: MonitorStore
    @State private var confirming: TicketSnap?
    @State private var confirmingAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Overview").scaledFont(.title2, weight: .bold)
                if let error = store.lastError { Text(error).foregroundStyle(.red).scaledFont(.caption) }
                pipelineStatus
                activeModels
                concurrency
                landingQueue
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .confirmationDialog(
            confirming.map { "Land #\($0.number) without waiting for tests?" } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible, presenting: confirming
        ) { ticket in
            Button("Land now (skip tests)", role: .destructive) { Task { await store.landNow(ticket.number) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("CI, the overlap re-test and the stop-line wait are skipped, and the PR says the owner bypassed them. A conflict still goes to the conflict stage, and an explicit landing pause still holds it.")
        }
        .confirmationDialog("Land every ticket in the queue without waiting for tests?", isPresented: $confirmingAll, titleVisibility: .visible) {
            Button("Land all (skip tests)", role: .destructive) { Task { await store.landAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every ticket in the landing queue is marked land-now at once and lands together. CI, the overlap re-test and the stop-line wait are skipped.")
        }
    }

    // 0. pipeline status --------------------------------------------------------------------------------------------
    private var pipelineStatus: some View {
        section("Pipeline status") {
            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(store.statusRows) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        Text(row.value).foregroundStyle(color(row.severity)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func color(_ severity: Overview.Severity) -> Color {
        switch severity {
        case .normal: .secondary
        case .ok: .green
        case .warn: .orange
        case .bad: .red
        }
    }

    // 1. active models ----------------------------------------------------------------------------------------------
    private var activeModels: some View {
        let groups = Overview.activeModels(store.snapshot?.tickets ?? [])
        let total = groups.reduce(0) { $0 + $1.sessions.count }
        return section("Model sessions running: \(total)") {
            if groups.isEmpty {
                Text("No model session is running.").foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(group.model).scaledFont(.body, weight: .semibold, monospaced: true)
                        Chip(text: "\(group.sessions.count)", color: .blue)
                    }
                    ForEach(group.sessions) { s in
                        HStack(spacing: 8) {
                            Text("#\(s.ticket.number)").monospacedDigit().foregroundStyle(.secondary)
                            Text(s.ticket.title).lineLimit(1)
                            Spacer()
                            Chip(text: s.stage, color: stateColor(s.ticket.state))
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { store.selected = s.ticket.number }
                    }
                }
            }
        }
    }

    // 2. concurrency ------------------------------------------------------------------------------------------------
    private var concurrency: some View {
        let maxActive = store.snapshot?.maxActive ?? 2
        let running = (store.snapshot?.tickets ?? []).filter { Overview.activeStates.contains($0.state) }.count
        return section("Tickets running at once") {
            HStack(spacing: 12) {
                Stepper(value: Binding(get: { maxActive }, set: { n in Task { await store.setMaxActive(n) } }),
                        in: 1...Overview.maxActiveCap) {
                    Text("Up to \(maxActive) at once").monospacedDigit()
                }
                .fixedSize()
                Text("\(running) running now").foregroundStyle(.secondary)
            }
            Text("Lowering it never stops a running ticket; it only holds back new ones.")
                .scaledFont(.caption).foregroundStyle(.secondary)
        }
    }

    // 3. landing queue ----------------------------------------------------------------------------------------------
    private var landingQueue: some View {
        let queue = Overview.landingQueue(store.snapshot?.tickets ?? [])
        let landing = store.snapshot?.landing
        return section("Landing queue") {
            HStack(spacing: 8) {
                if let stop = landing?.stopLine { Chip(text: "stop line: \(stop)", color: .red) }
                if landing?.paused == true { Chip(text: "landing paused", color: .orange) }
                if landing?.stopLine == nil && landing?.paused != true { Chip(text: "landing open", color: .green) }
            }
            ForEach(Array(Overview.landingLines(landing).enumerated()), id: \.offset) { _, line in
                Text(line.text).monospacedDigit().foregroundStyle(ciColor(line.ci) ?? (line.slow ? Color.orange : Color.secondary))
            }
            if queue.isEmpty {
                Text("Nothing is waiting to land.").foregroundStyle(.secondary)
            }
            if queue.count > 1 {
                Button("Land all (skip tests)") { confirmingAll = true }
            }
            ForEach(queue) { t in
                HStack(spacing: 8) {
                    Text("#\(t.number)").monospacedDigit().foregroundStyle(.secondary)
                    Text(t.title).lineLimit(1)
                    Spacer()
                    if t.state == "ready" { Text(t.activity).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    Chip(text: t.state, color: ciColor(Overview.chipCI(t, landing)) ?? stateColor(t.state))
                    Button("Land now (skip tests)") { confirming = t }
                }
                .contentShape(Rectangle())
                .onTapGesture { store.selected = t.number }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).scaledFont(.title3, weight: .semibold)
            content()
        }
    }
}
