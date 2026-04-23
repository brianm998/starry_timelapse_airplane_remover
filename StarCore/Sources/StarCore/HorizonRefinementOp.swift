import Foundation
import logging

/// Runs after the star homography has been validated, using
/// `HomographyHorizonDetector` to produce a refined horizon mask that
/// exploits the alignment-error signal between warped neighbours and the
/// current frame.
final class HorizonRefinementOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let errorClosure: (String) -> Void

    init(
      frame: FrameAirplaneRemover,
      rawImageBytes: UInt64 = 0,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.errorClosure = errorClosure
        super.init(for: .refinedHorizon, rawImageBytes: rawImageBytes)
        self.name = "horizon refinement frame \(frame.frameIndex)"
    }

    override func asyncExecute() async {
        do {
            Log.d("frame \(frame.frameIndex) HorizonRefinementOp starting")
            _ = try await frame.loadOrCreateRefinedHorizonMask()
            Log.d("frame \(frame.frameIndex) HorizonRefinementOp done")
        } catch {
            let str = "frame \(frame.frameIndex) error during horizon refinement: \(error)"
            Log.e(str)
            errorClosure(str)
        }
    }
}
