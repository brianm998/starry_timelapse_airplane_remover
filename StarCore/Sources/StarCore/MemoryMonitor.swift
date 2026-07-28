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
            Log.e("MemoryMonitor: a single reservation of \(bytes / (1024*1024))MB exceeds " +
                  "the entire \(budget / (1024*1024))MB budget — proceeding ungated. " +
                  "Check the op's memoryMultiplier and maxMatMemoryFraction.")
            return
        }

        if reservedBytes + bytes <= budget {
            reservedBytes += bytes
            Log.d("MemoryMonitor: reserved \(bytes / (1024*1024))MB — " +
                  "total=\(reservedBytes / (1024*1024))MB / \(budget / (1024*1024))MB")
            return
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
        let systemFree = star_available_system_memory()
        return "MemoryMonitor: \(totalWaits) waits, " +
            "avg \(totalWaits > 0 ? String(format: "%.1f", totalWaitTime / Double(totalWaits)) : "0")s, " +
            "\(waiters.count) queued, " +
            "reserved=\(reservedBytes / (1024*1024))MB / \(budget / (1024*1024))MB, " +
            "systemFree=\(systemFree / (1024*1024))MB"
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

        for waiter in waiters {
            if speculativeReserved + waiter.needed <= budget {
                released.append(waiter)
                speculativeReserved += waiter.needed
                continue
            }

            if mayForce, now >= waiter.deadline {
                let over = (speculativeReserved + waiter.needed) - budget
                Log.w("MemoryMonitor: forcing waiter \(waiter.id) " +
                      "(\(waiter.needed / (1024*1024))MB) through — waited " +
                      "\(String(format: "%.0f", now.timeIntervalSince(waiter.deadline) + maxWaitTime))s, " +
                      "this puts us \(over / (1024*1024))MB over the " +
                      "\(budget / (1024*1024))MB budget. Further forced admissions " +
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
