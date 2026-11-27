import XCTest
import Observation
@testable import StarCore

/// The gui's status lines read `FrameObserver.numberOf*Outliers`. If the observer is not
/// `@Observable`, a changed count never invalidates the SwiftUI view that read it.
@MainActor
final class FrameObserverObservationTests: XCTestCase {

    private func fires(_ read: () -> Void, _ change: () -> Void) -> Bool {
        var fired = false
        withObservationTracking { read() } onChange: { fired = true }
        change()
        return fired
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
