import Foundation
import StarCoreC
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Gates large operations to prevent over-committing RAM.
///
/// Uses pure accounting: tracks `reservedBytes` (sum of estimates for all
/// in-flight ops) and refuses to start a new op when
/// `reservedBytes + needed > physicalMemory * budgetFraction`.
///
/// Ignores actual free RAM — assumes the OS will page things out — so there
/// is no race between when an op starts and when it peaks.
///
/// Waiters are patient by design. A request that cannot ever fit (bigger than the
/// whole budget) is admitted immediately with an error, so every waiter that stays
/// queued is one that *can* eventually be satisfied. Beyond that, a waiter is only
/// forced over budget as a deadlock escape hatch: at most one at a time, spaced by
/// `forcedAdmissionInterval`. That matters because waiters tend to enqueue together
/// — they become ready at the same barrier — so their deadlines also expire
/// together, and "admit everything past its deadline" would admit everything at
/// once, which is precisely the overload the monitor exists to prevent.
///
/// API:
///   - `reserve(bytes:)` — call before starting heavy work; suspends until
///     the accounting budget allows it.
///   - `release(bytes:)` — call when the op finishes.
///   - `waitForMemory(needed:)` / `memoryFreed()` — no-ops retained for
///     call-site compatibility.
public actor MemoryMonitor {

    // MARK: - Singleton

    public static let shared = MemoryMonitor()

    // MARK: - Configuration

    /// Fraction of physical memory star is allowed to reserve (0.1–0.95).
    /// Default 0.85 = 85%.
    private var budgetFraction: Double = 0.85

    /// How long a waiter waits before the monitor considers forcing it through.
    private var maxWaitTime: TimeInterval = 60.0

    /// Minimum gap between forced over-budget admissions.
    ///
    /// Forcing exists only so a stuck queue cannot deadlock; it is not a throughput
    /// valve. Admitting every timed-out waiter in one pass turns a congested queue
    /// into a stampede — and because waiters generally enqueue together (they all
    /// become ready at the same barrier) their deadlines all expire together, so
    /// "release everything past its deadline" means releasing *everything*.
    ///
    /// One at a time, spaced by roughly the duration of a heavy op, keeps the
    /// overshoot to a single operation. If ops are actually completing, reservations
    /// are released and the normal fits-in-budget path admits waiters long before
    /// this matters.
    private var forcedAdmissionInterval: TimeInterval = 60.0

    /// When the last over-budget waiter was forced through, if any.
    private var lastForcedAdmission: Date?

    // MARK: - Ground truth

    /// Where the monitor reads actual memory state from. Injectable so tests can drive
    /// the brake below without allocating gigabytes.
    public struct RealityProbe: Sendable {
        public var processFootprint: @Sendable () -> UInt64
        public var systemAvailable: @Sendable () -> UInt64

        public init(processFootprint: @escaping @Sendable () -> UInt64,
                    systemAvailable: @escaping @Sendable () -> UInt64) {
            self.processFootprint = processFootprint
            self.systemAvailable = systemAvailable
        }

        public static let live = RealityProbe(
          processFootprint: { star_process_footprint() },
          systemAvailable: { star_available_system_memory() }
        )
    }

    private var reality: RealityProbe = .live

    /// Refuse new admissions when the system has less than this much left. Below this
    /// the OS starts swapping, and swapping is the failure mode being avoided — an op
    /// that "fits the ledger" is no help if the machine is already thrashing.
    private var systemFloorBytes: UInt64 = 2 * 1024 * 1024 * 1024

    /// Set by the OS memory-pressure source. Stays false where there is no such source
    /// to set it — see `startPressureMonitoringIfNeeded`.
    private var underMemoryPressure = false
    #if canImport(Darwin)
    private var pressureSources: [DispatchSourceMemoryPressure] = []
    #endif

    /// Count of admissions the reality brake has held back, for `stats()`.
    private var realityHolds: Int = 0

    public func setRealityProbe(_ probe: RealityProbe) { self.reality = probe }

    public func setSystemFloor(bytes: UInt64) { self.systemFloorBytes = bytes }

    // MARK: - Derived limits

    private let physicalMemory: UInt64 = UInt64(ProcessInfo.processInfo.physicalMemory)

    private var budget: UInt64 {
        UInt64(Double(physicalMemory) * budgetFraction)
    }

    // MARK: - Waiter queue

    private struct Waiter {
        let id: Int
        let needed: UInt64
        let continuation: CheckedContinuation<Void, Never>
        let deadline: Date
    }

    private var waiters: [Waiter] = []
    private var nextWaiterId = 0
    private var pollTask: Task<Void, Never>?

    // MARK: - Reservation tracking

    /// Sum of estimated bytes for all currently in-flight ops.
    private var reservedBytes: UInt64 = 0

    // MARK: - Stats

    private var totalWaits: Int = 0
    private var totalWaitTime: TimeInterval = 0

    // MARK: - Configuration

    /// `maxWaitTime` and `forcedAdmissionInterval` are exposed mainly so tests can
    /// drive the timeout path without waiting a minute; leave them nil in production.
    public func configure(budgetFraction: Double,
                          maxWaitTime: TimeInterval? = nil,
                          forcedAdmissionInterval: TimeInterval? = nil) {
        self.budgetFraction = min(max(budgetFraction, 0.1), 0.95)
        if let maxWaitTime { self.maxWaitTime = max(0, maxWaitTime) }
        if let forcedAdmissionInterval {
            self.forcedAdmissionInterval = max(0, forcedAdmissionInterval)
        }
        Log.i("MemoryMonitor configured: budgetFraction=\(self.budgetFraction), " +
              "physical=\(physicalMemory / (1024*1024*1024))GB, " +
              "budget=\(budget / (1024*1024))MB, " +
              "maxWait=\(Int(self.maxWaitTime))s, " +
              "forcedGap=\(Int(self.forcedAdmissionInterval))s")
    }

    // MARK: - Public API

    /// No-op — retained for call-site compatibility.
    /// Reservation accounting in `reserve(bytes:)` already prevents over-commit.
    public func waitForMemory(needed: UInt64) async {}

    /// No-op — retained for call-site compatibility.
    /// Waiters are drained in `release(bytes:)`.
    public func memoryFreed() {}

    /// Reserve `bytes` of budget before starting heavy op work.
    /// Suspends until `reservedBytes + bytes <= budget`.
    /// Call `release(bytes:)` when the op finishes.
    public func reserve(bytes: UInt64) async {
        guard bytes > 0 else { return }

        // A single request bigger than the whole budget can never fit, so queueing it
        // would block until the timeout no matter what else happens.  Admit it now and
        // say so — either the estimate or the budget is wrong, and that is worth
        // knowing.  This is also what makes it safe for the queue below to be patient:
        // every waiter that remains queued *can* eventually fit.
        if bytes > budget {
            reservedBytes += bytes
            postWarning(StarWarning(
              kind: .oversizedReservation,
              severity: .critical,
              message: "A single step of this run needs \(bytes / (1024*1024))MB, which is more " +
                       "than the \(budget / (1024*1024))MB star is allowed to use on this " +
                       "machine, so it is running without a memory limit and could be stopped " +
                       "by the system.",
              suggestion: "Reduce the resolution star works at (--keypoint-divisor 1.5) or " +
                          "raise --max-mat-memory-fraction if this machine has memory to spare."
            ))
            return
        }

        startPressureMonitoringIfNeeded()

        // The ledger says there is room. Check reality agrees before believing it.
        if reservedBytes + bytes <= budget {
            if let blocked = realityBlock() {
                realityHolds += 1
                Log.w("MemoryMonitor: ledger has room for \(bytes / (1024*1024))MB but " +
                      "\(blocked) — waiting instead of admitting")
            } else {
                reservedBytes += bytes
                Log.d("MemoryMonitor: reserved \(bytes / (1024*1024))MB — " +
                      "total=\(reservedBytes / (1024*1024))MB / \(budget / (1024*1024))MB")
                return
            }
        }

        let startTime = Date()
        Log.i("MemoryMonitor: waiting to reserve \(bytes / (1024*1024))MB — " +
              "reserved=\(reservedBytes / (1024*1024))MB, budget=\(budget / (1024*1024))MB")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let id = nextWaiterId
            nextWaiterId += 1
            waiters.append(Waiter(
                id: id,
                needed: bytes,
                continuation: continuation,
                deadline: Date().addingTimeInterval(maxWaitTime)
            ))
            startPollingIfNeeded()
        }

        reservedBytes += bytes

        let elapsed = Date().timeIntervalSince(startTime)
        totalWaits += 1
        totalWaitTime += elapsed
        Log.i("MemoryMonitor: reservation granted after \(String(format: "%.1f", elapsed))s — " +
              "reserved=\(reservedBytes / (1024*1024))MB")
    }

    /// Release a previously granted reservation.  Wakes any ops waiting to reserve.
    public func release(bytes: UInt64) {
        guard bytes > 0 else { return }
        reservedBytes = reservedBytes >= bytes ? reservedBytes - bytes : 0
        Log.d("MemoryMonitor: released \(bytes / (1024*1024))MB — " +
              "total=\(reservedBytes / (1024*1024))MB")
        drainReadyWaiters()
    }

    /// Returns a summary of memory monitor stats for logging.
    public func stats() -> String {
        let footprint = reality.processFootprint()
        // The gap between these two is the whole reason the reality brake exists: what
        // the ledger knows about versus what the process is actually holding.
        let unaccounted = footprint > reservedBytes ? footprint - reservedBytes : 0
        return "MemoryMonitor: \(totalWaits) waits, " +
            "avg \(totalWaits > 0 ? String(format: "%.1f", totalWaitTime / Double(totalWaits)) : "0")s, " +
            "\(waiters.count) queued, " +
            "reserved=\(reservedBytes / (1024*1024))MB / \(budget / (1024*1024))MB, " +
            "footprint=\(footprint / (1024*1024))MB " +
            "(unaccounted \(unaccounted / (1024*1024))MB), " +
            "systemFree=\(reality.systemAvailable() / (1024*1024))MB, " +
            "realityHolds=\(realityHolds)" +
            (underMemoryPressure ? ", UNDER PRESSURE" : "")
    }

    // MARK: - Estimation helpers

    public nonisolated static func estimatedImageBytes(
        width: Int,
        height: Int,
        componentsPerPixel: Int = 3,
        bytesPerComponent: Int = 2
    ) -> UInt64 {
        UInt64(width) * UInt64(height) * UInt64(componentsPerPixel) * UInt64(bytesPerComponent)
    }

    // MARK: - Reality brake

    /// Why a reservation is being held back by actual memory state, or nil if reality
    /// permits it.
    ///
    /// The ledger above is predictive: it knows what an op *intends* to allocate. This
    /// is the opposite — it knows what is actually resident, including everything the
    /// ledger never hears about: per-frame state retained on frames
    /// (`cachedFinalHorizonMask`, `outlierImageData`), the unbounded `KeypointCache`,
    /// any path that allocates without reserving, and allocator slack.
    ///
    /// Deliberately a brake rather than a co-equal gate. It refuses only once reality
    /// has already crossed the line, never on `footprint + needed`, because process
    /// footprint does not drop promptly when memory is freed back to the allocator —
    /// measured on this codebase, an op that allocates and frees 450MB leaves the
    /// footprint at its peak. Gating on `footprint + needed` would therefore starve
    /// admissions permanently after the first heavy frame.
    ///
    /// A held-back reservation becomes a normal waiter, so the forced-admission escape
    /// hatch still applies and the brake cannot deadlock the pipeline.
    private func realityBlock() -> String? {
        if underMemoryPressure {
            return "the OS reports memory pressure"
        }
        let footprint = reality.processFootprint()
        if footprint > 0, footprint >= budget {
            postWarning(StarWarning(
              kind: .footprintOverBudget,
              severity: .warning,
              message: "star is using \(footprint / (1024*1024))MB, which is past the " +
                       "\(budget / (1024*1024))MB it budgeted for this machine. It is pausing " +
                       "work rather than allocating more.",
              suggestion: "The run should still finish, more slowly. If it is stopped by the " +
                          "system, resume it with --keypoint-divisor 1.5."
            ))
            return "process footprint \(footprint / (1024*1024))MB is already at or past " +
                   "the \(budget / (1024*1024))MB budget — the ledger is under-counting " +
                   "by at least \(footprint > reservedBytes ? (footprint - reservedBytes) / (1024*1024) : 0)MB"
        }
        let available = reality.systemAvailable()
        if available > 0, available < systemFloorBytes {
            postWarning(StarWarning(
              kind: .lowSystemMemory,
              severity: .warning,
              message: "This machine has only \(available / (1024*1024))MB of memory free. " +
                       "star is pausing work rather than making it worse.",
              suggestion: "Closing other applications will let the run continue at full speed."
            ))
            return "only \(available / (1024*1024))MB available system-wide, floor is " +
                   "\(systemFloorBytes / (1024*1024))MB"
        }
        return nil
    }

    /// Begin watching the machine, independently of whether anything has reserved yet.
    ///
    /// `reserve()` also calls this, but lazily is not soon enough: until the first
    /// reservation the process is deaf to memory pressure, and the phases before it —
    /// loading a sequence, probing a video, generating previews — are perfectly capable of
    /// filling memory.  Clients call this at startup via `Callbacks.installWarningHandler()`.
    public func startMonitoring() {
        startPressureMonitoringIfNeeded()
    }

    /// Start listening for OS memory-pressure notifications. Idempotent.
    ///
    /// Darwin only, and a no-op elsewhere: memory-pressure sources are part of Dispatch's
    /// Darwin overlay, not of swift-corelibs-libdispatch, so `DispatchSourceMemoryPressure`
    /// and `makeMemoryPressureSource` do not exist on Linux or Windows. Referring to them
    /// unconditionally is what broke the Windows build.
    ///
    /// Losing this costs the third of the reality brake's three signals. The other two —
    /// the process footprint against its reservations, and the system-available floor —
    /// are implemented for every platform in `memory_monitor.c` and still apply, so the
    /// brake degrades rather than disappearing. `underMemoryPressure` simply stays false.
    ///
    /// One source per state rather than one source reading `.data`: the event handler is
    /// a `sending` closure, and capturing the source in order to read `.data` off it
    /// would pull a non-Sendable value into that closure. Splitting by mask means each
    /// handler captures only a `Bool`.
    private func startPressureMonitoringIfNeeded() {
        #if canImport(Darwin)
        guard pressureSources.isEmpty else { return }
        let states: [(DispatchSource.MemoryPressureEvent, Bool)] = [
            ([.warning, .critical], true),
            ([.normal], false),
        ]
        for (mask, pressured) in states {
            let source = DispatchSource.makeMemoryPressureSource(
              eventMask: mask,
              queue: .global(qos: .utility)
            )
            // Capture nothing but the Bool — going through `shared` rather than `self`
            // keeps this closure Sendable, which `setEventHandler` requires.
            source.setEventHandler { @Sendable in
                Task { await MemoryMonitor.shared.pressureChanged(pressured: pressured) }
            }
            source.activate()
            pressureSources.append(source)
        }
        #endif
    }

    private func pressureChanged(pressured: Bool) {
        guard pressured != underMemoryPressure else { return }
        underMemoryPressure = pressured
        if pressured {
            // Detail at info, because the user-facing sentence below is posted as a
            // warning and logs itself — two WARN lines saying the same thing is noise.
            Log.i("MemoryMonitor: OS memory pressure — holding new reservations " +
                  "(reserved \(reservedBytes / (1024*1024))MB, footprint " +
                  "\(reality.processFootprint() / (1024*1024))MB)")
            // The most important warning star can issue.  On Darwin this notification is
            // the last thing the system says before jetsam begins killing processes, and
            // the kill itself arrives as an uncatchable SIGKILL — so this is the only
            // moment at which an out-of-memory death can be announced while it is still
            // in the future.
            postWarning(StarWarning(
              kind: .memoryPressure,
              severity: .critical,
              message: "The system is low on memory and may stop star to reclaim it. " +
                       "star is holding \(reality.processFootprint() / (1024*1024))MB.",
              suggestion: "Closing other applications now may let this run finish. If it is " +
                          "stopped, resume it and add --keypoint-divisor 1.5 to use less memory."
            ))
        } else {
            Log.i("MemoryMonitor: memory pressure cleared, resuming admissions")
            drainReadyWaiters()
        }
    }

    /// Hand a warning to `StarWarnings` without making the caller async.
    ///
    /// `realityBlock()` and `drainReadyWaiters()` are synchronous and are called from the
    /// release path and the poll loop; awaiting another actor from them would put the
    /// admission gate behind the warning system, which is backwards.  `StarWarning` is
    /// `Sendable`, so handing it off costs nothing.  Dedup lives in `StarWarnings`, which
    /// matters here: `realityBlock()` is evaluated on every drain pass.
    private func postWarning(_ warning: StarWarning) {
        Task { await StarWarnings.shared.post(warning) }
    }

    // MARK: - Internal

    private func startPollingIfNeeded() {
        guard pollTask == nil, !waiters.isEmpty else { return }
        pollTask = Task { [weak self] in
            while true {
                guard let self else { break }
                let hasWaiters = await self.hasWaiters()
                guard hasWaiters else { break }
                try? await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000))
                await self.drainReadyWaiters()
            }
            await self?.stopPolling()
        }
    }

    private func hasWaiters() -> Bool { !waiters.isEmpty }

    private func stopPolling() { pollTask = nil }

    private func drainReadyWaiters() {
        let now = Date()
        // Use speculative accounting so a single release() doesn't unblock all
        // waiters simultaneously — each granted waiter reduces available headroom
        // for subsequent ones in the same drain pass.
        var speculativeReserved = reservedBytes
        var released: [Waiter] = []
        var remaining: [Waiter] = []

        // A timed-out waiter may be forced over budget, but at most one per drain and
        // no more often than forcedAdmissionInterval.  Waiters are appended in FIFO
        // order, so the oldest eligible one wins and nothing starves.
        var mayForce = (lastForcedAdmission.map {
            now.timeIntervalSince($0) >= forcedAdmissionInterval
        } ?? true)

        // Evaluated once per drain, not per waiter — it reads the process footprint.
        // Note this does NOT gate the forced path below: forcing is the deadlock escape
        // hatch, and reality being unhappy is exactly when a stuck queue must still
        // eventually make progress.
        let blocked = realityBlock()
        if let blocked, !waiters.isEmpty {
            Log.d("MemoryMonitor: holding \(waiters.count) waiter(s) — \(blocked)")
        }

        for waiter in waiters {
            if blocked == nil, speculativeReserved + waiter.needed <= budget {
                released.append(waiter)
                speculativeReserved += waiter.needed
                continue
            }

            if mayForce, now >= waiter.deadline {
                // Two different reasons a waiter can be sitting here, and the ledger is
                // only one of them: since the reality brake can hold a waiter while the
                // ledger still has room, `projected` may be UNDER budget. Subtracting
                // unconditionally underflows — this trapped as soon as the brake landed.
                let projected = speculativeReserved + waiter.needed
                let why = projected > budget
                    ? "this puts us \((projected - budget) / (1024*1024))MB over the " +
                      "\(budget / (1024*1024))MB budget"
                    : "the ledger has room (\(projected / (1024*1024))MB of " +
                      "\(budget / (1024*1024))MB) but " + (blocked ?? "reality disagreed")
                Log.w("MemoryMonitor: forcing waiter \(waiter.id) " +
                      "(\(waiter.needed / (1024*1024))MB) through — waited " +
                      "\(String(format: "%.0f", now.timeIntervalSince(waiter.deadline) + maxWaitTime))s, " +
                      why + ". Further forced admissions " +
                      "held for \(Int(forcedAdmissionInterval))s so \(waiters.count - 1) " +
                      "other waiter(s) do not pile on.")
                released.append(waiter)
                speculativeReserved += waiter.needed
                lastForcedAdmission = now
                mayForce = false
                continue
            }

            remaining.append(waiter)
        }

        waiters = remaining
        for waiter in released { waiter.continuation.resume() }

        if waiters.isEmpty {
            pollTask?.cancel()
            pollTask = nil
        }
    }
}
