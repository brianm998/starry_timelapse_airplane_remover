import XCTest
@testable import StarCore

/// `StarWarnings` is the path from "star noticed the machine is in trouble" to "the user
/// knows".  Before it existed, all three of `MemoryMonitor`'s signals — the OS memory-pressure
/// notification, the process footprint against its budget, and the system-available floor —
/// only ever throttled the admission gate, so a run walked into an out-of-memory kill behind
/// a normal-looking progress display.
///
/// The interesting behaviour is the dedup.  These conditions are sampled repeatedly:
/// `realityBlock()` is evaluated on every drain pass, twice a second for as long as anything
/// is queued.  Deliver every evaluation and the user gets the same sentence hundreds of times
/// — which is not "informed", it is a wall of text they will learn to ignore.  Deliver too
/// few and a worsening run goes quiet at the moment it matters.
final class StarWarningsTests: XCTestCase {

    /// A fresh relay rather than `.shared`, so tests cannot disturb each other or anything
    /// else in the process.
    private func relay(minimumInterval: TimeInterval = 30) async -> StarWarnings {
        let w = StarWarnings()
        await w.setMinimumInterval(minimumInterval)
        return w
    }

    private func warning(_ kind: StarWarning.Kind = .memoryPressure,
                         _ severity: StarWarning.Severity = .warning,
                         at time: Date = Date()) -> StarWarning
    {
        StarWarning(kind: kind, severity: severity, message: "\(kind)", time: time)
    }

    // MARK: - Delivery

    func testAWarningReachesTheInstalledHandler() async {
        let relay = await self.relay()
        let box = Box()
        await relay.set { warning in box.append(warning) }

        await relay.post(warning())

        XCTAssertEqual(box.values.count, 1)
        XCTAssertEqual(box.values.first?.kind, .memoryPressure)
    }

    /// The standalone tools and the tests install no handler.  Posting must still work —
    /// `post` logs unconditionally, and the log is the only consumer in those processes.
    func testPostingWithNoHandlerInstalledIsHarmless() async {
        let relay = await self.relay()
        let delivered = await relay.post(warning())
        XCTAssertTrue(delivered)
    }

    // MARK: - Dedup

    /// The core of it: one condition, sampled repeatedly, is one warning.
    func testTheSameKindIsNotDeliveredTwiceInsideTheInterval() async {
        let relay = await self.relay(minimumInterval: 30)
        let box = Box()
        await relay.set { box.append($0) }

        let start = Date()
        let first = await relay.post(warning(.memoryPressure, .warning, at: start))
        // What a drain loop looks like: the same condition, half a second later.
        let again = await relay.post(
          warning(.memoryPressure, .warning, at: start.addingTimeInterval(0.5)))
        let onceMore = await relay.post(
          warning(.memoryPressure, .warning, at: start.addingTimeInterval(29)))
        XCTAssertTrue(first)
        XCTAssertFalse(again)
        XCTAssertFalse(onceMore)

        XCTAssertEqual(box.values.count, 1)
    }

    func testTheSameKindIsDeliveredAgainAfterTheInterval() async {
        let relay = await self.relay(minimumInterval: 30)
        let box = Box()
        await relay.set { box.append($0) }

        let start = Date()
        await relay.post(warning(.memoryPressure, .warning, at: start))
        let afterInterval = await relay.post(
          warning(.memoryPressure, .warning, at: start.addingTimeInterval(31)))
        XCTAssertTrue(afterInterval)

        XCTAssertEqual(box.values.count, 2)
    }

    /// Dedup is per kind, so a genuinely different condition is never hidden by a recent one.
    func testDifferentKindsDoNotSuppressEachOther() async {
        let relay = await self.relay(minimumInterval: 30)
        let box = Box()
        await relay.set { box.append($0) }

        let start = Date()
        let pressure = await relay.post(warning(.memoryPressure, .warning, at: start))
        let low = await relay.post(warning(.lowSystemMemory, .warning, at: start))
        let overBudget = await relay.post(warning(.footprintOverBudget, .warning, at: start))
        XCTAssertTrue(pressure)
        XCTAssertTrue(low)
        XCTAssertTrue(overBudget)

        XCTAssertEqual(box.values.count, 3)
    }

    /// A condition getting worse is new information, and it is the case that matters most: a
    /// run that has been pausing on memory for a while and then gets a critical
    /// memory-pressure notification is seconds from being killed.  Suppressing that because
    /// something similar was said 20 seconds ago would defeat the point.
    func testAnEscalationToCriticalIsDeliveredInsideTheInterval() async {
        let relay = await self.relay(minimumInterval: 30)
        let box = Box()
        await relay.set { box.append($0) }

        let start = Date()
        let asWarning = await relay.post(warning(.memoryPressure, .warning, at: start))
        let escalated = await relay.post(
          warning(.memoryPressure, .critical, at: start.addingTimeInterval(1)))
        XCTAssertTrue(asWarning)
        XCTAssertTrue(escalated)

        XCTAssertEqual(box.values.map(\.severity), [.warning, .critical])
    }

    /// De-escalation is not news, so it stays suppressed — otherwise a condition oscillating
    /// around a threshold would alternate messages forever.
    func testDroppingBackToWarningInsideTheIntervalIsSuppressed() async {
        let relay = await self.relay(minimumInterval: 30)
        let box = Box()
        await relay.set { box.append($0) }

        let start = Date()
        await relay.post(warning(.memoryPressure, .critical, at: start))
        let deEscalated = await relay.post(
          warning(.memoryPressure, .warning, at: start.addingTimeInterval(1)))
        XCTAssertFalse(deEscalated)

        XCTAssertEqual(box.values.count, 1)
    }

    // MARK: - The last warning

    /// `RunMarker` records this so a killed run's report can say what star last noticed.  It
    /// is the difference between "the run stopped" and "the run stopped while the system was
    /// reporting memory pressure".
    func testTheMostRecentWarningIsRetained() async {
        let relay = await self.relay(minimumInterval: 0)
        await relay.post(warning(.memoryPressure))
        await relay.post(warning(.lowSystemMemory))

        let latest = await relay.latest()
        XCTAssertEqual(latest?.kind, .lowSystemMemory)
    }

    /// A suppressed warning is not the most recent thing star *told* anybody, so it must not
    /// overwrite what it did — otherwise the marker's evidence gets diluted by whichever
    /// duplicate happened to land last.
    func testASuppressedWarningDoesNotBecomeTheMostRecent() async {
        let relay = await self.relay(minimumInterval: 30)
        let start = Date()

        await relay.post(warning(.memoryPressure, .critical, at: start))
        await relay.post(warning(.memoryPressure, .warning, at: start.addingTimeInterval(1)))

        let latest = await relay.latest()
        XCTAssertEqual(latest?.severity, .critical)
    }

    func testResetForgetsEverything() async {
        let relay = await self.relay(minimumInterval: 30)
        let start = Date()
        await relay.post(warning(.memoryPressure, .warning, at: start))
        await relay.reset()

        let afterReset = await relay.latest()
        XCTAssertNil(afterReset)
        let deliveredAgain = await relay.post(
          warning(.memoryPressure, .warning, at: start.addingTimeInterval(1)))
        XCTAssertTrue(deliveredAgain,
                      "reset should clear the dedup window as well as the last warning")
    }

    // MARK: - Severity ordering

    /// `Severity` is `Comparable` specifically so the dedup above can ask "is this worse than
    /// what we already said". Getting the order backwards would invert escalation handling.
    func testCriticalIsMoreSevereThanWarning() {
        XCTAssertTrue(StarWarning.Severity.warning < StarWarning.Severity.critical)
        XCTAssertFalse(StarWarning.Severity.critical < StarWarning.Severity.warning)
    }

    // MARK: - Presentation

    /// Every kind needs a title and a non-empty one-liner, because the gui puts the title in
    /// a box heading and the cli prints the one-liner.  A kind added without them would
    /// surface as a blank alert.
    func testEveryKindHasATitleAndAOneLineDescription() {
        for kind in StarWarning.Kind.allCases {
            let w = StarWarning(kind: kind, severity: .warning,
                                message: "something", suggestion: "do something")
            XCTAssertFalse(w.title.isEmpty, "\(kind) has no title")
            // `localized` returns the key itself when nothing in the catalogue has it, so a
            // title that still reads as a key is a kind whose string was never written.
            // Without this the check above passes on a `warning.title.*` typo.
            XCTAssertFalse(w.title.hasPrefix("warning.title."),
                           "\(kind) has no warning.title.* string in the catalogue")
            XCTAssertTrue(w.oneLineDescription.contains("something"), "\(kind)")
            XCTAssertTrue(w.oneLineDescription.contains("do something"), "\(kind)")
        }
    }

    /// A warning with no suggestion must not render a dangling separator or the word "nil".
    func testAWarningWithNoSuggestionIsJustItsMessage() {
        let w = StarWarning(kind: .memoryPressure, severity: .warning, message: "just this")
        XCTAssertEqual(w.oneLineDescription, "just this")
    }
}

/// Collects warnings from the `@Sendable` handler closure, which cannot capture a
/// non-`Sendable` `XCTestCase`.  A class with a lock rather than an actor so assertions can
/// read it without `await` interleaving further posts.
/// Which warnings a banner may take down on its own, and which it must not.
final class PassingConditionTests: XCTestCase {

    private func warning(_ kind: StarWarning.Kind) -> StarWarning {
        StarWarning(kind: kind, severity: .warning, message: "\(kind)")
    }

    /// The machine-state signals: `MemoryMonitor` samples these while it gates admissions, and
    /// they stop being true on their own — a banner still asserting one after it cleared is
    /// worse than no banner.
    func testTheMachineStateConditionsPass() {
        for kind in [StarWarning.Kind.memoryPressure, .lowSystemMemory, .footprintOverBudget] {
            XCTAssertTrue(warning(kind).describesAPassingCondition, "\(kind)")
        }
    }

    /// Everything else is posted once, about something that happened, and stays as true as it
    /// was — so it stays up until the user takes it down.  `outputWriteFailed` is the one that
    /// matters most: it is about the user's product going missing.
    func testTheFactsAboutARunDoNot() {
        for kind in [StarWarning.Kind.outputWriteFailed, .lowDiskSpace, .previousRunDied,
                     .oversizedReservation, .memoryGatingDisabled, .artifactsInvalidated,
                     .groundAlignmentFailed] {
            XCTAssertFalse(warning(kind).describesAPassingCondition, "\(kind)")
        }
    }

    /// The two lists above have to cover every kind: a case added to `Kind` and left out of
    /// them would be classified by whichever branch happened to catch it.
    func testEveryKindIsInOneOfTheTwoLists() {
        let passing: Set<StarWarning.Kind> = [.memoryPressure, .lowSystemMemory,
                                             .footprintOverBudget]
        let staying: Set<StarWarning.Kind> = [.outputWriteFailed, .lowDiskSpace, .previousRunDied,
                                             .oversizedReservation, .memoryGatingDisabled,
                                             .artifactsInvalidated, .groundAlignmentFailed]
        XCTAssertTrue(passing.isDisjoint(with: staying))
        XCTAssertEqual(passing.count + staying.count, StarWarning.Kind.allCases.count,
                       "a new StarWarning.Kind needs classifying in describesAPassingCondition")
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [StarWarning] = []

    func append(_ warning: StarWarning) {
        lock.lock(); defer { lock.unlock() }
        storage.append(warning)
    }

    var values: [StarWarning] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
