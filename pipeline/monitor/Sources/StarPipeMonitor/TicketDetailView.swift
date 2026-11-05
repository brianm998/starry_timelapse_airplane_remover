import AppKit
import StarPipeMonitorCore
import SwiftUI

struct TicketDetailView: View {
    let store: MonitorStore
    let ticket: TicketSnap
    @State private var answer = ""
    /// Whether the "Other" row of an option question is open for typing.
    @State private var otherOpen = false

    private var repo: String { store.snapshot?.repo ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                titleBar
                StageTimeline(stages: ticket.stages, now: store.snapshot?.now ?? Date().timeIntervalSince1970)
                if let q = question { questionBox(q) }
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

    /// The open question: the daemon's structured one when its detail is this ticket's, else the snapshot's text alone.
    private var question: QuestionRow? {
        let current = store.detail.flatMap { $0.number == ticket.number ? $0 : nil }
        return current?.question ?? ticket.question.map { QuestionRow(text: $0) }
    }

    private func send(_ text: String) {
        answer = ""
        otherOpen = false
        Task { await store.answer(ticket.number, text) }
    }

    private func questionBox(_ q: QuestionRow) -> some View {
        GroupBox("Question") {
            VStack(alignment: .leading, spacing: 8) {
                Text(q.text).textSelection(.enabled)
                if let why = q.why, !why.isEmpty {
                    Text(why).foregroundStyle(.secondary).textSelection(.enabled)
                }
                let rows = QuestionChoices.rows(for: q)
                if rows.isEmpty {
                    answerField
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in choiceRow(row) }
                    }
                    if otherOpen { answerField }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func choiceRow(_ row: QuestionChoices.Choice) -> some View {
        Button {
            switch row {
            case .option(let text, _): send(text)
            case .other: otherOpen.toggle()
            }
        } label: {
            HStack {
                switch row {
                case .option(let text, let recommended):
                    Text(text).multilineTextAlignment(.leading)
                    Spacer()
                    if recommended { Chip(text: "Recommended", color: .green) }
                case .other:
                    Text("Other\u{2026}").foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
    }

    private var answerField: some View {
        HStack {
            TextField("Your answer", text: $answer, axis: .vertical).textFieldStyle(.roundedBorder)
            Button("Answer") {
                if let text = QuestionChoices.answerText(for: .other, typed: answer) { send(text) }
            }
            .disabled(QuestionChoices.answerText(for: .other, typed: answer) == nil)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    /// The open issues this ticket waits for, one link per line, and the retry held for them; absent when there is neither.
    @ViewBuilder
    private var blockedBy: some View {
        let current = store.detail.flatMap { $0.number == ticket.number ? $0 : nil }
        let rows = current.map { BlockerLinks.detailRows(blockers: $0.blockers, repo: repo) } ?? []
        let held = current?.heldRetry
        if !rows.isEmpty || held != nil {
            GroupBox("Blocked by") {
                VStack(alignment: .leading, spacing: 4) {
                    if let held {
                        Text(held).textSelection(.enabled)
                    }
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Button(row.label) { store.selectIssue(row.number, title: row.title) }
                                .buttonStyle(.link).monospacedDigit().help("Show \(row.label) here")
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

/// The detail pane for an issue that is a blocker but not a pipeline ticket: what is known, and the way to GitHub.
struct IssuePanelView: View {
    let number: Int
    let title: String
    let repo: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(number)").monospacedDigit().foregroundStyle(.secondary)
                if !title.isEmpty { Text(title).scaledFont(.title2, weight: .bold).textSelection(.enabled) }
                Spacer()
                if let url = BlockerLinks.issueURL(repo: repo, number: number) {
                    Button("Issue") { NSWorkspace.shared.open(url) }
                }
            }
            Text("Not a pipeline ticket.").foregroundStyle(.secondary)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The detail pane for a proposed issue: approve it (optionally with a priority), reject it (optionally with a reason),
/// or open it on GitHub. The daemon's refusal (a full queue, an issue that is no longer proposed) shows in the error line.
/// The title and buttons stay pinned; the issue's labels, readiness, blockers, body and comments scroll beneath them.
struct ProposalDetailView: View {
    @Bindable var store: MonitorStore
    let proposal: ProposalSnap
    @State private var rejecting = false
    @State private var reason = ""
    @State private var busy = false

    /// The loaded detail, only when it is this proposal's.
    private var loaded: ProposalDetail? { store.proposalDetail.flatMap { $0.number == proposal.number ? $0 : nil } }
    private var now: Double { store.snapshot?.now ?? Date().timeIntervalSince1970 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Reject #\(proposal.number)?", isPresented: $rejecting) {
            TextField("Reason (optional)", text: $reason)
            Button("Reject", role: .destructive) { reject() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The issue gets a comment with the reason and is closed as not planned.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("#\(proposal.number)").monospacedDigit().foregroundStyle(.secondary)
                Text(proposal.title).scaledFont(.title2, weight: .bold).textSelection(.enabled)
                Spacer()
            }
            Text(proposal.headerSentence(now: now)).foregroundStyle(.secondary)
            HStack {
                Menu("Approve") {
                    Button("Keep the issue's priority") { approve(nil) }
                    Divider()
                    ForEach(["p0", "p1", "p2", "p3"], id: \.self) { p in Button(p) { approve(p) } }
                }
                .fixedSize()
                Button("Reject…") { reason = ""; rejecting = true }
                if let url = BlockerLinks.issueURL(repo: store.snapshot?.repo ?? "", number: proposal.number) {
                    Button("Issue") { NSWorkspace.shared.open(url) }
                }
            }
            .disabled(busy)
            if let error = store.lastError { Text(error).scaledFont(.caption).foregroundStyle(.red) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let d = loaded {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !d.labels.isEmpty {
                        HStack { ForEach(d.labels, id: \.self) { Chip(text: $0) } }
                    }
                    if let r = d.readiness { readinessBox(r) }
                    blockers(d.blockers)
                    MarkdownView(markdown: d.body)
                    comments(d)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let error = store.proposalDetailError {
            Text("Could not load the issue's description: \(error)").scaledFont(.caption).foregroundStyle(.red)
                .textSelection(.enabled)
            Spacer()
        } else {
            Text("Loading…").foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func readinessBox(_ r: ProposalReadiness) -> some View {
        GroupBox("Readiness") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(ProposalReadinessText.lines(r).enumerated()), id: \.offset) { _, line in
                    Label(line.text, systemImage: line.warn ? "exclamationmark.triangle.fill" : "circle.fill")
                        .labelStyle(ReadinessLabelStyle(warn: line.warn))
                        .foregroundStyle(line.warn ? Color.orange : Color.primary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func blockers(_ list: [BlockerRef]) -> some View {
        let rows = BlockerLinks.detailRows(blockers: list, repo: store.snapshot?.repo ?? "")
        if !rows.isEmpty {
            GroupBox("Blocked by") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Button(row.label) { store.selectIssue(row.number, title: row.title) }
                                .buttonStyle(.link).monospacedDigit().help("Show \(row.label) here")
                            Text(row.title).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func comments(_ d: ProposalDetail) -> some View {
        if d.commentCount > 0 || !d.comments.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                Text("Comments").scaledFont(.body, weight: .semibold)
                if let more = ProposalText.commentOverflow(count: d.commentCount, sent: d.comments.count) {
                    Text(more).foregroundStyle(.secondary)
                }
                ForEach(Array(d.comments.enumerated()), id: \.offset) { _, c in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ProposalText.commentHeader(c, now: now)).scaledFont(.caption, weight: .semibold).foregroundStyle(.secondary)
                        MarkdownView(markdown: c.body)
                    }
                }
            }
        }
    }

    private func approve(_ priority: String?) {
        busy = true
        Task {
            await store.approve(proposal.number, priority: priority)
            busy = false
        }
    }

    private func reject() {
        busy = true
        Task {
            await store.reject(proposal.number, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines))
            busy = false
        }
    }
}

private struct ReadinessLabelStyle: LabelStyle {
    let warn: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if warn { configuration.icon } else { Text("•") }
            configuration.title
        }
    }
}

/// Markdown laid out block by block (`MarkdownBlocks.split`): headings, bullets and paragraphs get their inline markdown
/// (code, links, emphasis) rendered by `Text`; fenced code is monospaced. A lazy stack keeps a long body cheap.
struct MarkdownView: View {
    let markdown: String

    var body: some View {
        let blocks = MarkdownBlocks.split(markdown)
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    inline(text).scaledFont(level <= 1 ? .title3 : level == 2 ? .body : .callout, weight: .semibold)
                        .padding(.top, level <= 2 ? 6 : 2)
                case .bullet(let indent, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        inline(text)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case .paragraph(let text):
                    inline(text)
                case .code(let text):
                    Text(text).scaledFont(.caption, monospaced: true).textSelection(.enabled)
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        return Text(attributed).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}
