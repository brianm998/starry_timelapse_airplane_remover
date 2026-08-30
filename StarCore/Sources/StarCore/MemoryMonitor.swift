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
/// Tracks `reservedBytes` (the sum of estimates for all in-flight ops) and refuses to
/// start a new op when `reservedBytes + needed > effectiveBudget()`.
///
/// There are two budgets, and the difference between them matters:
///
///   - `budget` is structural — `physicalMemory * budgetFraction`. It answers "could this
///     machine ever do this", and is used for sizing advice and for the impossible-request
///     test in `reserve(bytes:)`.
///   - `effectiveBudget()` is the admission limit — what star may hold *right now*, given
///     what the rest of the machine is holding.
///
/// It used to gate on the structural figure alone, and that is a claim about the machine
/// dressed up as a claim about the moment. On a 128GB machine at 0.85 it says star may
/// reserve 111GB, whether star is the only thing running or is sharing the machine with a
/// 42MP Lightroom export. A 32.7MP sequence took it at its word — 14 concurrent keypoint
/// ops, 110GB reserved, 85GB actually resident — and the machine ran out of RAM and took
/// the user's window session down with it. Nothing in the accounting could have noticed,
/// because star's own footprint never came near the 111GB it was measured against.
///
/// Waiters are patient by design. A request that cannot ever fit (bigger than the
/// structural budget) is admitted immediately with an error, so every waiter that stays
/// queued is one that *can* eventually be satisfied. Beyond that, a waiter is only
/// forced over budget as a deadlock escape hatch: at most one outstanding at a time,
/// spaced by `forcedAdmissionInterval`, and never while the OS reports critical pressure.
/// That matters because waiters tend to enqueue together — they become ready at the same
/// barrier — so their deadlines also expire together, and "admit everything past its
/// deadline" would admit everything at once, which is precisely the overload the monitor
/// exists to prevent. See `drainReadyWaiters()` for what happened when the "at most one
/// outstanding" half of that was documented but not implemented.
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

    /// When `drainReadyWaiters()` last reported that it was declining to force anything.
    /// Purely for rate-limiting that log line — see its use.
    private var lastWithholdLog: Date?

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

    /// What star leaves to the rest of the machine: the OS, the window server, and
    /// whatever else the user is running. New admissions are refused once the system has
    /// less than this left, and `effectiveBudget()` subtracts it from what star may grow
    /// into. Below it the OS starts compressing and swapping, and that is the failure mode
    /// being avoided — an op that "fits the ledger" is no help if the machine is thrashing.
    ///
    /// Proportional, not the flat 2GB it used to be. 2GB is a reasonable share of a 16GB
    /// laptop and an absurd one on a 128GB workstation, where 2GB is 1.5% and someone is
    /// very likely running something else — which is precisely the case that killed a run:
    /// star at 85GB alongside a Lightroom export, on a machine whose floor it could not
    /// reach because 2GB free means the machine has been thrashing for a long time already.
    ///
    /// `physical / 16` is 6.25%: 8GB at 128GB, 12GB at 192GB, and clamped up to 2GB at or
    /// below 32GB so small machines keep the old behaviour.
    private var systemFloorBytes: UInt64 =
      max(2 * 1024 * 1024 * 1024, UInt64(ProcessInfo.processInfo.physicalMemory) / 16)

    /// How loudly the OS is complaining about memory.
    ///
    /// A level rather than a Bool because Darwin's two non-normal levels mean very
    /// different things.  `warn` is the system asking every application to give memory
    /// back, which a machine working through a large sequence reaches routinely and comes
    /// out of on its own; `critical` is the last notice before jetsam starts killing
    /// processes.  Collapsing the two into one flag is what put a modal "the system may
    /// stop star" alert in front of a run that then finished normally.
    enum PressureLevel: String, Sendable {
        case normal
        case warning
        case critical
    }

    /// Set by the OS memory-pressure sources.  Stays `.normal` where there are no such
    /// sources to set it — see `startPressureMonitoringIfNeeded`.
    private var pressureLevel: PressureLevel = .normal

    /// Whether the admission brake holds.  Both non-normal levels hold it: declining to
    /// start new heavy work while the system is asking for memory back costs some
    /// throughput and undoes itself, which is exactly what interrupting the user does not.
    private var underMemoryPressure: Bool { pressureLevel != .normal }
    #if canImport(Darwin)
    private var pressureSources: [DispatchSourceMemoryPressure] = []
    #endif

    /// Count of admissions the reality brake has held back, for `stats()`.
    private var realityHolds: Int = 0

    public func setRealityProbe(_ probe: RealityProbe) { self.reality = probe }

    public func setSystemFloor(bytes: UInt64) { self.systemFloorBytes = bytes }

    // MARK: - Derived limits

    private let physicalMemory: UInt64 = UInt64(ProcessInfo.processInfo.physicalMemory)

    /// The structural ceiling: a fraction of the machine's RAM, and nothing else.
    ///
    /// Use this only for questions about what this machine could *ever* do — sizing
    /// advice, and the "this request can never fit" test in `reserve(bytes:)`. It is not
    /// the admission limit; `effectiveBudget()` is. Deciding admissions on this figure is
    /// what let a run reserve 111GB of a 128GB machine while Lightroom was exporting, with
    /// nothing in the accounting that could notice.
    private var budget: UInt64 {
        UInt64(Double(physicalMemory) * budgetFraction)
    }

    /// What star may hold right now: what it already holds, plus what the machine can
    /// spare above `systemFloorBytes`, never more than the structural `budget`.
    ///
    /// The static budget answers "how much of this machine is star allowed to use", which
    /// is the wrong question, because it is the same answer whether star is the only thing
    /// running or is sharing the machine with a 42MP Lightroom export. A 128GB machine at
    /// `maxMatMemoryFraction` 0.85 yields 111GB, and `Config.keypointConcurrency` will
    /// happily fill essentially all of it with keypoint ops alone — 14 x 7868MB = 110GB at
    /// 32.7MP. That was admitted, in full, on a machine that could not hold it.
    ///
    /// `footprint + available` is the right shape because it is stable as star grows: every
    /// page star faults in moves from `available` into `footprint` and the sum barely
    /// moves. It only shrinks when *something else* takes memory — which is exactly the
    /// signal the static budget was missing. So this is, in effect, "physical memory minus
    /// what everyone else is using".
    ///
    /// Anchoring on `footprint` rather than on `available` alone is what keeps it from
    /// starving the pipeline. When the machine has nothing to spare this collapses to
    /// `footprint`, meaning "keep what you have, finish what you are doing, start nothing
    /// new" — never to zero, so a run already underway is throttled rather than stopped.
    /// It also means the sticky footprint noted on `realityBlock()` is harmless here: those
    /// pages are charged to star either way, and a footprint that has not yet fallen back
    /// only makes this figure larger, not smaller.
    ///
    /// Comparing a predictive ledger against a measured footprint is deliberate. A
    /// reservation is an upper bound on what an op will allocate, so `reservedBytes` runs
    /// ahead of `footprint` — mixing them errs toward admitting less, which is the side to
    /// err on.
    ///
    /// Falls back to the static budget when either probe reads 0: that means the platform
    /// could not answer (see `memory_monitor.c`), not that the machine is empty.
    private func effectiveBudget() -> UInt64 {
        let ceiling = budget
        let footprint = reality.processFootprint()
        let available = reality.systemAvailable()
        guard footprint > 0, available > 0 else { return ceiling }
        // Early out on its own line so the sum below cannot overflow: past this point both
        // terms are under `physicalMemory`, where a real probe would keep them anyway. A
        // test is free to inject a footprint near `UInt64.max`, and wrapping it would
        // produce a tiny budget rather than the intended enormous one.
        guard footprint < ceiling else { return ceiling }
        let spare = available > systemFloorBytes ? available - systemFloorBytes : 0
        return min(ceiling, footprint + spare)
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
              "admitting up to \(effectiveBudget() / (1024*1024))MB right now " +
              "(system floor \(systemFloorBytes / (1024*1024))MB, " +
              "\(reality.systemAvailable() / (1024*1024))MB available), " +
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
    /// Suspends until `reservedBytes + bytes <= effectiveBudget()`.
    /// Call `release(bytes:)` when the op finishes.
    public func reserve(bytes: UInt64) async {
        guard bytes > 0 else { return }

        // A single request bigger than the whole budget can never fit, so queueing it
        // would block until the timeout no matter what else happens.  Admit it now and
        // say so — either the estimate or the budget is wrong, and that is worth
        // knowing.  This is also what makes it safe for the queue below to be patient:
        // every waiter that remains queued *can* eventually fit.
        //
        // Deliberately the structural `budget` and not `effectiveBudget()`.  This branch
        // admits IMMEDIATELY and ungated, so testing it against a figure that shrinks when
        // the machine is busy would invert the whole gate: a 7.8GB keypoint op would be
        // declared impossible and waved straight through at exactly the moment there is no
        // room for it.  The question here is only whether the request could ever fit on
        // this machine at all.
        if bytes > budget {
            reservedBytes += bytes
            postWarning(StarWarning(
              kind: .oversizedReservation,
              severity: .critical,
              message: localized("warning.oversized_reservation.message",
                                 bytes.humanReadableBytes,
                                 budget.humanReadableBytes),
              suggestion: localized("warning.oversized_reservation.suggestion")
            ))
            return
        }

        startPressureMonitoringIfNeeded()

        // The ledger says there is room. Check reality agrees before believing it.
        let admissionBudget = effectiveBudget()
        if reservedBytes + bytes <= admissionBudget {
            if let blocked = realityBlock() {
                realityHolds += 1
                Log.w("MemoryMonitor: ledger has room for \(bytes / (1024*1024))MB but " +
                      "\(blocked) — waiting instead of admitting")
            } else {
                reservedBytes += bytes
                Log.d("MemoryMonitor: reserved \(bytes / (1024*1024))MB — " +
                      "total=\(reservedBytes / (1024*1024))MB / \(admissionBudget / (1024*1024))MB")
                return
            }
        }

        // Say so when it is the *machine* refusing rather than star's own accounting: this
        // request would have fitted the structural budget and was held only because
        // something else is holding the memory. Without this the user sees an unexplained
        // slowdown — the run simply gets slower, with no warning until the machine drops
        // below the floor, which it may never do. Reusing `lowSystemMemory` rather than
        // adding a kind because its two sentences already say exactly the right thing —
        // memory is tight, so this reservation waits while everything already running
        // carries on — and `StarWarnings` dedups by kind so a throttled run posts it once
        // rather than per waiter.
        if reservedBytes + bytes > admissionBudget, reservedBytes + bytes <= budget {
            postWarning(StarWarning(
              kind: .lowSystemMemory,
              severity: .warning,
              message: localized("warning.low_system_memory.message",
                                 reality.systemAvailable().humanReadableBytes),
              suggestion: localized("warning.low_system_memory.suggestion")
            ))
        }

        let startTime = Date()
        Log.i("MemoryMonitor: waiting to reserve \(bytes / (1024*1024))MB — " +
              "reserved=\(reservedBytes / (1024*1024))MB, budget=\(admissionBudget / (1024*1024))MB" +
              (admissionBudget < budget
                 ? " (narrowed from \(budget / (1024*1024))MB — the rest of the machine is " +
                   "holding memory star cannot have)"
                 : ""))

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
        let effective = effectiveBudget()
        return "MemoryMonitor: \(totalWaits) waits, " +
            "avg \(totalWaits > 0 ? String(format: "%.1f", totalWaitTime / Double(totalWaits)) : "0")s, " +
            "\(waiters.count) queued, " +
            "reserved=\(reservedBytes / (1024*1024))MB / \(effective / (1024*1024))MB" +
            // Both figures, because which one is binding is the question a stalled run
            // raises: a gap between them means something else on the machine is holding
            // memory star would otherwise have been allowed to use.
            (effective < budget ? " (of \(budget / (1024*1024))MB physical)" : "") + ", " +
            "footprint=\(footprint / (1024*1024))MB " +
            "(unaccounted \(unaccounted / (1024*1024))MB), " +
            "systemFree=\(reality.systemAvailable() / (1024*1024))MB, " +
            "floor=\(systemFloorBytes / (1024*1024))MB, " +
            "realityHolds=\(realityHolds)" +
            (underMemoryPressure ? ", UNDER PRESSURE (\(pressureLevel.rawValue))" : "")
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
    ///
    /// `effectiveBudget()` now covers the same ground continuously rather than as a
    /// threshold, and it is the part that does the work: the two tests below are worst-case
    /// backstops that only fire once things are already bad. Neither of them fired at all
    /// during the run that motivated this. The footprint test could not — star peaked at
    /// 85.6GB against a 111.4GB budget, comfortably under, while the machine died — and the
    /// available-memory test could not either, because `star_available_system_memory()` was
    /// counting dirty anonymous pages as available. Both are fixed, and both are still the
    /// wrong shape for the job on their own, which is why the budget moved instead.
    private func realityBlock() -> String? {
        if underMemoryPressure {
            return "the OS reports \(pressureLevel.rawValue)-level memory pressure"
        }
        let footprint = reality.processFootprint()
        if footprint > 0, footprint >= budget {
            postWarning(StarWarning(
              kind: .footprintOverBudget,
              severity: .warning,
              message: localized("warning.footprint_over_budget.message",
                                 footprint.humanReadableBytes,
                                 budget.humanReadableBytes),
              suggestion: localized("warning.footprint_over_budget.suggestion")
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
              message: localized("warning.low_system_memory.message", available.humanReadableBytes),
              suggestion: localized("warning.low_system_memory.suggestion")
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
    /// brake degrades rather than disappearing. The level simply stays `.normal`.
    ///
    /// One source per level rather than one source reading `.data`: the event handler is
    /// a `sending` closure, and capturing the source in order to read `.data` off it
    /// would pull a non-Sendable value into that closure. Splitting by mask means each
    /// handler captures only a `PressureLevel`.
    private func startPressureMonitoringIfNeeded() {
        #if canImport(Darwin)
        guard pressureSources.isEmpty else { return }
        let states: [(DispatchSource.MemoryPressureEvent, PressureLevel)] = [
            ([.critical], .critical),
            ([.warning], .warning),
            ([.normal], .normal),
        ]
        for (mask, level) in states {
            let source = DispatchSource.makeMemoryPressureSource(
              eventMask: mask,
              queue: .global(qos: .utility)
            )
            // Capture nothing but the level — going through `shared` rather than `self`
            // keeps this closure Sendable, which `setEventHandler` requires.
            source.setEventHandler { @Sendable in
                Task { await MemoryMonitor.shared.pressureChanged(level: level) }
            }
            source.activate()
            pressureSources.append(source)
        }
        #endif
    }

    /// Internal rather than private because it is the only way in: the events themselves
    /// come from the OS, and no test can make a machine run out of memory on cue.
    func pressureChanged(level: PressureLevel) {
        guard level != pressureLevel else { return }
        let previous = pressureLevel
        pressureLevel = level

        // Detail at info, because the user-facing sentences below are posted as warnings
        // and log themselves — two lines saying the same thing is noise.
        if level != .normal {
            Log.i("MemoryMonitor: OS memory pressure \(previous.rawValue) → " +
                  "\(level.rawValue) — holding new reservations " +
                  "(reserved \(reservedBytes / (1024*1024))MB, footprint " +
                  "\(reality.processFootprint() / (1024*1024))MB)")
        }

        switch level {
        case .normal:
            Log.i("MemoryMonitor: memory pressure cleared, resuming admissions")
            drainReadyWaiters()

        case .warning:
            // Deliberately not critical.  At this level the system is asking for memory
            // back, not about to take it: a machine working through a large sequence
            // crosses into warn and back out of it on its own, and a run that gets this
            // far usually finishes.  Clients that interrupt the user for `critical` do not
            // interrupt for this, so it reaches the log, the cli's warning line, the Kotlin
            // client's banner and the run marker's breadcrumb — which is what keeps a run
            // killed after nothing worse than warn level diagnosable — without stopping
            // anybody's work.
            postWarning(StarWarning(
              kind: .memoryPressure,
              severity: .warning,
              message: localized("warning.memory_pressure_mild.message",
                                 reality.processFootprint().humanReadableBytes),
              suggestion: localized("warning.memory_pressure_mild.suggestion")
            ))

        case .critical:
            // The most important warning star can issue.  On Darwin this notification is
            // the last thing the system says before jetsam begins killing processes, and
            // the kill itself arrives as an uncatchable SIGKILL — so this is the only
            // moment at which an out-of-memory death can be announced while it is still
            // in the future.
            postWarning(StarWarning(
              kind: .memoryPressure,
              severity: .critical,
              message: localized("warning.memory_pressure.message",
                                 reality.processFootprint().humanReadableBytes),
              suggestion: localized("warning.memory_pressure.suggestion")
            ))
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

        // A timed-out waiter may be forced over budget, but at most one per drain, no more
        // often than forcedAdmissionInterval, and only while the two conditions below
        // hold.  Waiters are appended in FIFO order, so the oldest eligible one wins and
        // nothing starves.
        //
        // Both conditions are load-bearing, and their absence is what turned a stalled
        // run into a dead machine.  Forcing was unconditional: one op per minute, forever,
        // with no ceiling.  On a 32.7MP sequence that ratcheted the ledger from 111GB to
        // 151GB — five 7.8GB admissions in five minutes — and two of the five went through
        // *after* the OS reported memory pressure, one of them after `critical`.  The
        // machine took the window server down with it.
        //
        //   - `atOrUnderBudget`: only force when the ledger is not ALREADY over the
        //     structural budget.  Since nothing but forcing can put it over, this is
        //     exactly "at most one forced admission outstanding at a time", which bounds
        //     the ledger at `budget` plus one reservation.  That is what the comment here
        //     always claimed ("keeps the overshoot to a single operation") and what the
        //     code did not do.  Deliberately the structural `budget` and not
        //     `effectiveBudget()`: when the machine is full the effective figure sits below
        //     the ledger more or less permanently, and gating the escape hatch on it would
        //     be no escape hatch at all.
        //   - not `.critical`: at this level jetsam is the next thing to happen, and the
        //     kill arrives as an uncatchable SIGKILL.  Starting more heavy work is how a
        //     run gets killed rather than merely delayed; a stall is recoverable and a
        //     SIGKILL is not.  Warn level still forces, because a long sequence crosses
        //     into warn and back out of it routinely and stalling there would be its own
        //     bug.
        //
        // The residual risk is a chain of nested reservations two deep — an op holding one
        // reservation while waiting for a second, twice over.  One level deep still
        // resolves: the single forced admission completes, releases both, and the ledger
        // falls back under budget for the next one.
        let atOrUnderBudget = reservedBytes <= budget
        var mayForce = (lastForcedAdmission.map {
            now.timeIntervalSince($0) >= forcedAdmissionInterval
        } ?? true) && atOrUnderBudget && pressureLevel != .critical

        // Evaluated once per drain, not per waiter — it reads the process footprint.
        // Note this does NOT gate the forced path below: forcing is the deadlock escape
        // hatch, and reality being unhappy is exactly when a stuck queue must still
        // eventually make progress — subject to the two limits above, which is where
        // reality now gets its say.
        let blocked = realityBlock()
        if let blocked, !waiters.isEmpty {
            Log.d("MemoryMonitor: holding \(waiters.count) waiter(s) — \(blocked)")
        }

        // Recomputed per drain rather than per waiter: it reads both probes.
        let admissionBudget = effectiveBudget()

        // Rate-limited because this is the steady state of a throttled run, and
        // `drainReadyWaiters()` runs twice a second while anyone is parked: unthrottled it
        // would be the loudest thing in the diagnostic log of exactly the run someone needs
        // to read. Once a minute is enough to show how long the stall lasted.
        if !waiters.isEmpty, !mayForce, !atOrUnderBudget || pressureLevel == .critical,
           lastWithholdLog.map({ now.timeIntervalSince($0) >= 60 }) ?? true
        {
            lastWithholdLog = now
            Log.i("MemoryMonitor: \(waiters.count) waiter(s) held with forced admission " +
                  "withheld — " +
                  (atOrUnderBudget
                     ? "the OS reports critical memory pressure"
                     : "the ledger is already \((reservedBytes - budget) / (1024*1024))MB " +
                       "over the \(budget / (1024*1024))MB budget from an earlier forced " +
                       "admission") +
                  ". Waiting for in-flight work to finish rather than adding to it.")
        }

        for waiter in waiters {
            if blocked == nil, speculativeReserved + waiter.needed <= admissionBudget {
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
                let why = projected > admissionBudget
                    ? "this puts us \((projected - admissionBudget) / (1024*1024))MB over the " +
                      "\(admissionBudget / (1024*1024))MB budget"
                    : "the ledger has room (\(projected / (1024*1024))MB of " +
                      "\(admissionBudget / (1024*1024))MB) but " + (blocked ?? "reality disagreed")
                Log.w("MemoryMonitor: forcing waiter \(waiter.id) " +
                      "(\(waiter.needed / (1024*1024))MB) through — waited " +
                      "\(String(format: "%.0f", now.timeIntervalSince(waiter.deadline) + maxWaitTime))s, " +
                      why + ". Further forced admissions " +
                      "held for \(Int(forcedAdmissionInterval))s, and none at all until " +
                      "this one is released, so \(waiters.count - 1) " +
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
