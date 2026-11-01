import Foundation
import Observation

/// One line in the menu bar's "last five changes".
public struct Change: Equatable, Sendable, Identifiable {
    public var id: Int
    public var text: String
    public var at: Double
}

public enum Connection: Equatable, Sendable {
    case connecting
    case live
    case down(String)
}

/// What the views read. Owns the snapshot, the connection state and the recent changes; all mutations go through
/// the API and are followed by a refresh, so the daemon stays the single source of truth.
@MainActor
@Observable
public final class MonitorStore {
    public private(set) var snapshot: Snapshot?
    public private(set) var connection: Connection = .connecting
    public private(set) var recentChanges: [Change] = []
    public private(set) var detail: TicketDetail?
    public private(set) var logLines: [String] = []
    public var selected: Int?
    public var lastError: String?

    public var onAlert: (@MainActor (Alert) -> Void)?

    private var client: APIClient?
    private var tasks: [Task<Void, Never>] = []

    public init(client: APIClient? = nil) { self.client = client }

    // derived, from the snapshot only ----------------------------------------------------------------------------------
    public var needsYouCount: Int { snapshot?.tickets.filter { $0.group == "needs_you" }.count ?? 0 }

    public var developRed: Bool { snapshot?.landing.stopLine != nil }

    public var daemonDown: Bool { if case .down = connection { true } else { false } }

    /// The menu-bar badge: a red dot when develop is red or the daemon is down.
    public var needsAttention: Bool { developRed || daemonDown }

    /// The colour of the star in the menu bar and the Dock.
    public var pipelineState: PipelineState { .of(snapshot: snapshot, daemonDown: daemonDown) }

    public func tickets(in group: String) -> [TicketSnap] { snapshot?.tickets.filter { $0.group == group } ?? [] }

    public var selectedTicket: TicketSnap? { snapshot?.tickets.first { $0.number == selected } }

    // loading ------------------------------------------------------------------------------------------------------
    public func apply(_ new: Snapshot) {
        Alerts.diff(old: snapshot, new: new).forEach { onAlert?($0) }
        snapshot = new
        connection = .live
        if let selected, !new.tickets.contains(where: { $0.number == selected }) { self.selected = nil }
    }

    public func apply(event: ServerEvent) {
        guard event.kind == "state" || event.kind == "landed" || event.kind == "claimed" || event.kind == "ticket-queued" else { return }
        let who = event.ticket.map { "#\($0)" } ?? "pipeline"
        let what = event.data["state"] ?? event.kind
        recentChanges = Array(([Change(id: event.id, text: "\(who) \(what)", at: event.at)] + recentChanges).prefix(5))
    }

    public func refresh() async {
        guard let client else { return }
        do { apply(try await client.snapshot()) } catch { connection = .down("\(error.localizedDescription)") }
    }

    public func refreshSelected() async {
        guard let client, let n = selected else { detail = nil; logLines = []; return }
        detail = try? await client.detail(n)
        logLines = (try? await client.log(n)) ?? []
    }

    /// Poll the snapshot, follow the event stream, and reconnect with backoff. Safe to call once at launch.
    public func start(client: APIClient) {
        self.client = client
        stop()
        tasks = [
            Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    await self?.refreshSelected()
                    try? await Task.sleep(for: .seconds(3))
                }
            },
            Task { [weak self] in
                var delay = 1.0
                while !Task.isCancelled {
                    let cursor = self?.snapshot?.eventsCursor ?? 0
                    do {
                        for try await event in client.events(after: cursor) {
                            delay = 1
                            self?.apply(event: event)
                            await self?.refresh()
                        }
                    } catch {}
                    try? await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 30)
                }
            },
        ]
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    // actions (each followed by a refresh) ------------------------------------------------------------------------
    private func run(_ action: (APIClient) async throws -> Void) async {
        guard let client else { return }
        do {
            try await action(client)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
        await refreshSelected()
    }

    /// For the + sheet: one link's resolution, or the daemon's reason for rejecting it.
    public func resolve(url: String) async -> Result<ResolvedIssue, Error> {
        guard let client else { return .failure(APIError.daemonDown("not connected")) }
        do { return .success(try await client.resolve(url: url)) } catch { return .failure(error) }
    }

    /// Enqueue from the + sheet, then refresh like every other action; nil (with `lastError` set) on failure.
    public func enqueue(numbers: [Int]) async -> [EnqueueResult]? {
        var results: [EnqueueResult]?
        await run { results = try await $0.enqueue(numbers: numbers) }
        return results
    }

    public func answer(_ number: Int, _ text: String) async { await run { try await $0.answer(number, text: text) } }
    public func retry(_ number: Int, stage: String) async { await run { try await $0.retry(number, stage: stage) } }
    public func cancel(_ number: Int) async { await run { try await $0.cancel(number, reason: "cancelled from the monitor") } }
    public func setPriority(_ number: Int, _ priority: Int) async { await run { try await $0.setPriority(number, priority) } }
    public func landNow(_ number: Int) async { await run { try await $0.landNow(number) } }
    public func setMaxActive(_ n: Int) async { await run { try await $0.setMaxActive(n) } }
}
