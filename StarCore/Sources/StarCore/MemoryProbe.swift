import Foundation
import StarCoreC
import logging

/// Samples the process footprint while one operation runs and logs its actual peak
/// against what it reserved.
///
/// The point is to make the per-op multipliers in `Config` derivable from measurement.
/// `keypointMemoryMultiplier` was 35 against a measured 41.1x; `mergeMemoryMultiplier`
/// and `outlierMemoryMultiplier` were picked by eye. Rather than guess again, enable
/// `logOperationMemory`, run with `--num-concurrent-renders 1` so only one heavy op is
/// in flight, and read the ratios out of the log.
///
/// Read the output with these caveats in mind — they are not hypothetical, they were
/// all observed while deriving the current multipliers:
///
///   - **The delta under-reports repeat ops.** `phys_footprint` only grows when the
///     process needs pages it does not already hold. Once the allocator has them, an op
///     that allocates and frees the same amount shows a delta near zero. In a real run
///     the first horizon op measured +453MB and the next fourteen measured 0–21MB —
///     same work every time. So a small delta does NOT mean a cheap op.
///   - **The delta over-reports the first op of a kind**, for the same reason in
///     reverse: it is charged for warm-up that later ops inherit for free.
///   - Consequently this is a good detector of *under*-reservation (the
///     "OVER RESERVATION" marker below is a real signal) but a poor way to size a
///     reservation downward. For that, measure one op in a fresh process.
///   - The footprint is process-wide. With concurrency 1 the delta is mostly
///     attributable to the sampled op, but preview ops run on a separate queue and can
///     overlap.
///   - **`--num-concurrent-renders 1` does not currently get you that**: a run with it
///     completes horizon detection, runs exactly one star keypoint op and then sits
///     idle, so the advice above cannot be followed as written. At concurrency 2 the
///     deltas come in pairs — both ops of a pair are charged the same process growth —
///     so a pair figure has to be read against two reservations, not one. The
///     multipliers in `Config` were derived that way, and cross-checked against
///     single-op runs of a standalone harness.
///   - `phys_footprint` is what the OS charges the process, so it includes allocator
///     fragmentation the op is not really "using". That is the right conservative
///     choice for sizing a reservation.
actor MemoryProbe {
    private let type: OperationType
    private let label: String
    private let reserved: UInt64
    private let start: UInt64
    private var peak: UInt64
    private var sampler: Task<Void, Never>?

    /// Poll interval. Cheap — one `task_info` call — but frequent enough to catch a
    /// short-lived full-frame allocation.
    private static let interval: Duration = .milliseconds(20)

    init(type: OperationType, name: String?, reserved: UInt64) {
        self.type = type
        self.label = name ?? "\(type)"
        self.reserved = reserved
        let now = star_process_footprint()
        self.start = now
        self.peak = now
        Task { await self.startSampling() }
    }

    private func startSampling() {
        guard sampler == nil else { return }
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: MemoryProbe.interval)
                guard let self else { return }
                await self.sample()
            }
        }
    }

    private func sample() {
        let now = star_process_footprint()
        if now > peak { peak = now }
    }

    /// Stop sampling and report.
    func finish() {
        sampler?.cancel()
        sampler = nil
        sample()

        let mb = { (b: UInt64) in b / (1024 * 1024) }
        let delta = peak > start ? peak - start : 0

        var line = "op memory [\(label)]: peak +\(mb(delta))MB " +
                   "(footprint \(mb(start))MB → \(mb(peak))MB)"
        if reserved > 0 {
            let pct = Double(delta) / Double(reserved) * 100
            line += ", reserved \(mb(reserved))MB — used \(String(format: "%.0f", pct))% of it"
            if delta > reserved {
                line += " ** OVER RESERVATION by \(mb(delta - reserved))MB **"
            }
        } else {
            line += ", reserved nothing"
        }
        Log.i(line)
    }
}
