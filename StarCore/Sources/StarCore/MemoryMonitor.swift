import Foundation
import KHTSwift
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Monitors memory usage and gates large allocations to prevent the system
/// from running out of memory and either crashing or grinding to a halt.
///
/// Uses `os_proc_available_memory()` for real-time available memory and
/// `MatWrapper.totalBytes` for tracking OpenCV mat allocations.
///
/// Callers use `waitForMemory(needed:)` before large allocations.
/// If memory is tight, the call suspends until enough memory is freed
/// (by other frames completing and releasing their images).
public actor MemoryMonitor {

    // MARK: - Singleton

    public static let shared = MemoryMonitor()

    // MARK: - Configuration

    /// Fraction of physical memory that star is allowed to use (0.0–1.0).
    /// Default 0.75 = 75%.
    private var maxMemoryFraction: Double = 0.75

    /// Absolute floor: don't let available system memory drop below this.
    /// Default 1 GB.
    private var minAvailableMemoryBytes: UInt64 = 1_073_741_824  // 1 GB

    /// How often to poll when waiters are queued (seconds).
    private let pollInterval: TimeInterval = 0.5

    /// Maximum time a waiter will wait before proceeding anyway (seconds).
    private let maxWaitTime: TimeInterval = 60.0

    // MARK: - Derived limits

    private let physicalMemory: UInt64 = UInt64(ProcessInfo.processInfo.physicalMemory)

    /// Computed budget ceiling based on fraction of physical memory.
    private var matBudgetBytes: UInt64 {
        UInt64(Double(physicalMemory) * maxMemoryFraction)
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

    // MARK: - Stats

    private var totalWaits: Int = 0
    private var totalWaitTime: TimeInterval = 0

    // MARK: - Configuration

    /// Update memory limits from Config.  Call this when config changes.
    public func configure(maxMemoryFraction: Double, minAvailableMemoryBytes: UInt64) {
        self.maxMemoryFraction = min(max(maxMemoryFraction, 0.1), 0.95)
        self.minAvailableMemoryBytes = minAvailableMemoryBytes
        Log.i("MemoryMonitor configured: maxFraction=\(self.maxMemoryFraction), " +
              "minAvailable=\(self.minAvailableMemoryBytes / (1024*1024))MB, " +
              "physical=\(physicalMemory / (1024*1024*1024))GB, " +
              "budget=\(matBudgetBytes / (1024*1024))MB")
    }

    // MARK: - Memory queries

    /// Returns the number of bytes currently tracked by MatWrapper.
    public nonisolated var currentMatBytes: UInt64 {
        MatWrapper.totalBytes
    }

    /// Returns the available system memory.
    ///
    /// On macOS, `os_proc_available_memory()` is not available, so we estimate
    /// available memory as physical memory minus current task resident memory.
    public nonisolated var availableSystemMemory: UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let residentBytes = UInt64(info.resident_size)
            let physical = UInt64(ProcessInfo.processInfo.physicalMemory)
            return residentBytes < physical ? physical - residentBytes : 0
        }
        // Fallback: assume half of physical memory is available
        return UInt64(ProcessInfo.processInfo.physicalMemory) / 2
    }

    /// Returns true if allocating `needed` bytes would exceed our budget
    /// or push available system memory below the floor.
    private func isMemoryTight(for needed: UInt64) -> Bool {
        let matBytes = currentMatBytes
        let available = availableSystemMemory

        // Check 1: Would total mat allocations exceed our budget?
        if matBytes + needed > matBudgetBytes {
            return true
        }

        // Check 2: Would available system memory drop below the floor?
        if available < minAvailableMemoryBytes + needed {
            return true
        }

        return false
    }

    // MARK: - Public API

    /// Call before a large allocation. Returns immediately if memory is
    /// available; otherwise suspends until memory is freed or timeout expires.
    ///
    /// - Parameter needed: Estimated bytes about to be allocated.
    public func waitForMemory(needed: UInt64) async {
        guard needed > 0 else { return }

        // Fast path: memory is available
        if !isMemoryTight(for: needed) {
            return
        }

        let startTime = Date()

        Log.i("MemoryMonitor: waiting for \(needed / (1024*1024))MB — " +
              "matBytes=\(currentMatBytes / (1024*1024))MB, " +
              "available=\(availableSystemMemory / (1024*1024))MB, " +
              "budget=\(matBudgetBytes / (1024*1024))MB")

        // Slow path: enqueue and wait
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let id = nextWaiterId
            nextWaiterId += 1
            let waiter = Waiter(
                id: id,
                needed: needed,
                continuation: continuation,
                deadline: Date().addingTimeInterval(maxWaitTime)
            )
            waiters.append(waiter)
            startPollingIfNeeded()
        }

        let elapsed = Date().timeIntervalSince(startTime)
        totalWaits += 1
        totalWaitTime += elapsed

        Log.i("MemoryMonitor: wait complete after \(String(format: "%.1f", elapsed))s — " +
              "matBytes=\(currentMatBytes / (1024*1024))MB, " +
              "available=\(availableSystemMemory / (1024*1024))MB")
    }

    /// Notify the monitor that memory has been freed (e.g. after a frame completes).
    /// This triggers an immediate check of waiting tasks.
    public func memoryFreed() {
        drainReadyWaiters()
    }

    /// Returns a summary of memory monitor stats for logging.
    public func stats() -> String {
        "MemoryMonitor: \(totalWaits) waits, " +
        "avg \(totalWaits > 0 ? String(format: "%.1f", totalWaitTime / Double(totalWaits)) : "0")s, " +
        "\(waiters.count) queued, " +
        "matBytes=\(currentMatBytes / (1024*1024))MB, " +
        "available=\(availableSystemMemory / (1024*1024))MB"
    }

    // MARK: - Estimation helpers

    /// Estimate the memory needed for one full-resolution image.
    ///
    /// - Parameters:
    ///   - width: Image width in pixels
    ///   - height: Image height in pixels
    ///   - componentsPerPixel: Number of channels (typically 3 or 4)
    ///   - bytesPerComponent: Bytes per channel value (1 for 8-bit, 2 for 16-bit)
    /// - Returns: Estimated bytes
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

    private func hasWaiters() -> Bool {
        !waiters.isEmpty
    }

    private func stopPolling() {
        pollTask = nil
    }

    private func drainReadyWaiters() {
        let now = Date()
        var released: [Waiter] = []
        var remaining: [Waiter] = []

        for waiter in waiters {
            // Release if memory available OR deadline exceeded
            if !isMemoryTight(for: waiter.needed) || now >= waiter.deadline {
                if now >= waiter.deadline {
                    Log.w("MemoryMonitor: waiter \(waiter.id) timed out after \(maxWaitTime)s, proceeding anyway")
                }
                released.append(waiter)
            } else {
                remaining.append(waiter)
            }
        }

        waiters = remaining

        // Resume waiters outside the loop (FIFO order preserved)
        for waiter in released {
            waiter.continuation.resume()
        }

        if remaining.isEmpty {
            pollTask?.cancel()
            pollTask = nil
        }
    }
}
