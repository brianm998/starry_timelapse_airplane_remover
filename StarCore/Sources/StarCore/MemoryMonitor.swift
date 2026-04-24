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

    /// Maximum time a waiter will wait before proceeding anyway (seconds).
    private let maxWaitTime: TimeInterval = 60.0

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

    public func configure(budgetFraction: Double) {
        self.budgetFraction = min(max(budgetFraction, 0.1), 0.95)
        Log.i("MemoryMonitor configured: budgetFraction=\(self.budgetFraction), " +
              "physical=\(physicalMemory / (1024*1024*1024))GB, " +
              "budget=\(budget / (1024*1024))MB")
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
        for waiter in waiters {
            let fits = speculativeReserved + waiter.needed <= budget
            if fits || now >= waiter.deadline {
                if now >= waiter.deadline {
                    Log.w("MemoryMonitor: waiter \(waiter.id) timed out after \(maxWaitTime)s, proceeding anyway")
                }
                released.append(waiter)
                speculativeReserved += waiter.needed
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
        for waiter in released { waiter.continuation.resume() }

        if waiters.isEmpty {
            pollTask?.cancel()
            pollTask = nil
        }
    }
}
