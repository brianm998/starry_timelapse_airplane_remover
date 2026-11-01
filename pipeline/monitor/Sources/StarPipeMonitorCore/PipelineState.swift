import Foundation

/// The pipeline at a glance: the colour of the monitor's star.
public enum PipelineState: Equatable, Sendable {
    /// Something needs a human: a ticket needs you or failed, develop is red (stop the line), or the daemon is down.
    case red
    /// Tickets are running or waiting (a usage-limit pause included: it resumes by itself), and nothing needs you.
    case green
    /// Nothing active.
    case grey

    /// Red takes precedence over green. Usage-limit pauses keep their tickets in the running/waiting groups, so they
    /// need no case of their own. Before the first snapshot, and with the daemon answering, the pipeline reads as idle.
    public static func of(snapshot: Snapshot?, daemonDown: Bool) -> PipelineState {
        if daemonDown { return .red }
        guard let snapshot else { return .grey }
        if snapshot.landing.stopLine != nil { return .red }
        let groups = Set(snapshot.tickets.map(\.group))
        if groups.contains("needs_you") || groups.contains("failed") { return .red }
        if groups.contains("running") || groups.contains("waiting") { return .green }
        return .grey
    }
}
