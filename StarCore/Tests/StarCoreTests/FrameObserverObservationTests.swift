#if canImport(Observation)
import XCTest
import Observation
@testable import StarCore

/// The gui's status lines read `FrameObserver.numberOf*Outliers`. If the observer is not
/// `@Observable`, a changed count never invalidates the SwiftUI view that read it.
@MainActor
final class FrameObserverObservationTests: XCTestCase {

    private func fires(_ read: () -> Void, _ change: () -> Void) -> Bool {
        let flag = FiredFlag()
        withObservationTracking { read() } onChange: { flag.set() }
        change()
        return flag.value
    }

    private final class FiredFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func set() { lock.lock(); fired = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    }

    func testEachOutlierCountInvalidatesTrackingRead() {
        let o = FrameObserver()
        XCTAssertTrue(fires({ _ = o.numberOfPositiveOutliers }, { o.set(numberOfPositiveOutliers: 1) }))
        XCTAssertTrue(fires({ _ = o.numberOfNegativeOutliers }, { o.set(numberOfNegativeOutliers: 1) }))
        XCTAssertTrue(fires({ _ = o.numberOfUndecidedOutliers }, { o.set(numberOfUndecidedOutliers: 1) }))
        XCTAssertTrue(fires({ _ = o.numberOfTrashOutliers }, { o.set(numberOfTrashOutliers: 1) }))
    }

    func testBulkSetInvalidatesTrackingRead() {
        let o = FrameObserver()
        XCTAssertTrue(fires({ _ = o.numberOfNegativeOutliers }, {
            o.set(numberOfPositiveOutliers: 1, numberOfNegativeOutliers: 2,
                  numberOfUndecidedOutliers: 3, numberOfTrashOutliers: 4)
        }))
    }

    func testShouldRemoveInvalidatesTrackingRead() {
        let o = OutlierRemovalObserver()
        XCTAssertTrue(fires({ _ = o.shouldRemove }, { o.set(shouldRemove: .userSelected(true)) }))
    }
}
#endif
