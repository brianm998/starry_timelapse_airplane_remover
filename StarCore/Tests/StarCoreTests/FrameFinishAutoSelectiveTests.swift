import XCTest
import Foundation
@testable import StarCore

/// L5 of the parity plan: an auto selective frame (`.automatic(true)`) is complete once its final image is written, as a selective one is.
/// `finishAuto(useOutliers: true)` wrote the images and then stopped at the state it had last set (`.creatingRemovalMask`), so a whole run
/// left every frame short of complete: the desktop read 0/N complete and the gui's progress line never read N/N. A real run over six 42 MP
/// frames showed it (`RealSequenceRunTests` in the daemon, off unless `STAR_REAL_SEQUENCE_DIR` is set); this is the quick check.
final class FrameFinishAutoSelectiveTests: FrameHarnessTestCase {

    func testAnAutoSelectiveFrameIsCompleteOnceItsFinalIsWritten() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "finish-auto-selective")
        harness = h
        await h.updateConfig { $0.cleanMethod = .automatic(true) }
        // what the run has made before the merge stage: the automatic image
        let image = FrameHarness.syntheticFrame(width: 128, height: 96, horizonRow: 48)
        try h.plantImage(image, ofType: .autoProcessed)

        try await h.frame.finishAuto(useOutliers: true)

        let state = await h.frame.processingState()
        XCTAssertEqual(state, .complete, "an auto selective frame is finished once its final is written")
        XCTAssertTrue(h.imageAccessor.imageExists(frameIndex: 0, ofType: .final, atSize: .original), "its final is written")
        XCTAssertTrue(h.imageAccessor.imageExists(frameIndex: 0, ofType: .autoSelectiveProcessed, atSize: .original))
    }
}
