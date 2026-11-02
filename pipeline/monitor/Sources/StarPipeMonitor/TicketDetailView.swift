import AppKit
import StarPipeMonitorCore
import SwiftUI

struct TicketDetailView: View {
    let store: MonitorStore
    let ticket: TicketSnap
    @State private var answer = ""

    private var repo: String { store.snapshot?.repo ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleBar
                StageTimeline(stages: ticket.stages, now: store.snapshot?.now ?? Date().timeIntervalSince1970)
                if let q = ticket.question ?? store.detail?.question?.text { questionBox(q) }
                if let reason = ticket.parkReason, ticket.question == nil { Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                blockedBy
                if let plan = store.detail?.plan { planBox(plan) }
                checks
                logBox
            }
            .padding(16)
        }
    }

    private var titleBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("#\(ticket.number) \(ticket.title)").scaledFont(.title3, weight: .semibold)
                Chip(text: ticket.state, color: stateColor(ticket.state))
                Chip(text: "p\(ticket.priority)")
            }
            Text(ticket.activity).foregroundStyle(.secondary)
            HStack {
                Button("Issue") { open("https://github.com/\(repo)/issues/\(ticket.number)") }
                if let pr = ticket.prNumber {
                    Button("PR") { open("https://github.com/\(repo)/pull/\(pr)") }
                    Button("CI") { open("https://github.com/\(repo)/pull/\(pr)/checks") }
                }
                if let wt = ticket.worktree {
                    Menu("Open worktree") {
                        Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: wt)]) }
                        Button("Terminal") { run("/usr/bin/open", ["-a", "Terminal", wt]) }
                        Button("Xcode") { run("/usr/bin/open", ["-a", "Xcode", wt]) }
                    }
                }
                Spacer()
                Menu("Retry") {
                    ForEach(["explore", "develop", "review", "publish", "ci"], id: \.self) { stage in
                        Button(stage) { Task { await store.retry(ticket.number, stage: stage) } }
                    }
                }
                Menu("Priority") {
                    ForEach(0...3, id: \.self) { p in Button("p\(p)") { Task { await store.setPriority(ticket.number, p) } } }
                }
                Button("Cancel", role: .destructive) { Task { await store.cancel(ticket.number) } }
            }
            if let error = store.lastError { Text(error).scaledFont(.caption).foregroundStyle(.red) }
        }
    }

    private func questionBox(_ text: String) -> some View {
        GroupBox("Question") {
            VStack(alignment: .leading, spacing: 8) {
                Text(text).textSelection(.enabled)
                HStack {
                    TextField("Your answer", text: $answer, axis: .vertical).textFieldStyle(.roundedBorder)
                    Button("Answer") {
                        let text = answer
                        answer = ""
                        Task { await store.answer(ticket.number, text) }
                    }
                    .disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The open issues this ticket waits for, one link per line; absent when nothing blocks it.
    @ViewBuilder
    private var blockedBy: some View {
        let rows = store.detail.map { $0.number == ticket.number ? BlockerLinks.detailRows(blockers: $0.blockers, repo: repo) : [] } ?? []
        if !rows.isEmpty {
            GroupBox("Blocked by") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Link(row.label, destination: row.url).monospacedDigit().help(row.url.absoluteString)
                            Text(row.title).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func planBox(_ plan: PlanSummary) -> some View {
        GroupBox("Plan") {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.summary).textSelection(.enabled)
                Divider()
                ForEach(plan.acceptance) { row in
                    HStack(alignment: .top) {
                        Text(row.id).bold().frame(width: 28, alignment: .leading)
                        Text(row.check).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var checks: some View {
        if let rows = store.detail?.checks, !rows.isEmpty {
            GroupBox("Checks") {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(rows.suffix(10).enumerated()), id: \.offset) { _, row in
                        HStack {
                            Image(systemName: row.result == "pass" ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(row.result == "pass" ? .green : .red)
                            Text(row.checkId).scaledFont(.callout, monospaced: true)
                            Spacer()
                            Text(row.result).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var logBox: some View {
        GroupBox("Log") {
            ScrollView {
                Text(store.logLines.isEmpty ? "no transcript yet" : store.logLines.joined(separator: "\n"))
                    .scaledFont(.caption, monospaced: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
        }
    }

    private func open(_ url: String) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }

    private func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
    }
}

/// One bar, one segment per stage attempt, sized by wall time; the part spent waiting for the heavy lock is hatched.
struct StageTimeline: View {
    let stages: [StageSnap]
    let now: Double

    var body: some View {
        let total = max(1, stages.reduce(0) { $0 + duration($1) })
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(Array(stages.enumerated()), id: \.offset) { _, s in
                        let w = max(4, geo.size.width * duration(s) / total)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(color(s).opacity(0.75))
                            if s.lockWaitS > 0 {
                                RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.35))
                                    .frame(width: w * min(1, s.lockWaitS / max(1, duration(s))))
                            }
                        }
                        .frame(width: w).help("\(s.stage) \(s.attempt) on \(s.model) · \(Int(duration(s) / 60)) min" +
                                              (s.lockWaitS >= 60 ? " (\(Int(s.lockWaitS / 60)) min waiting for the heavy lock)" : ""))
                    }
                }
            }
            .frame(height: 18)
            Text(stages.map { "\($0.stage) \($0.attempt) (\($0.model))" }.joined(separator: " → ")).scaledFont(.caption).foregroundStyle(.secondary)
        }
    }

    private func duration(_ s: StageSnap) -> Double { max(1, (s.ended ?? now) - s.started) }

    private func color(_ s: StageSnap) -> Color {
        switch s.outcome {
        case "accepted": .green
        case nil: .blue
        case "interrupted": .gray
        default: .orange
        }
    }
}
