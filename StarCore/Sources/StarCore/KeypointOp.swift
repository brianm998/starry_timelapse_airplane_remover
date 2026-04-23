import Foundation
import logging

final class KeypointOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let mode: FrameViewMode
    let errorClosure: (String) -> Void

    init(
      forStars: Bool,
      frame: FrameAirplaneRemover,
      mode: FrameViewMode,
      rawImageBytes: UInt64 = 0,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.mode = mode
        self.errorClosure = errorClosure
        if forStars {
            super.init(for: .starKeypoints, rawImageBytes: rawImageBytes)
            self.name = "star keypoints for frame \(frame.frameIndex)"
        } else {
            super.init(for: .earthKeypoints, rawImageBytes: rawImageBytes)
            self.name = "earth keypoints for frame \(frame.frameIndex)"
        }
    }

    override func asyncExecute() async {
        do {
            Log.d("frame \(frame.frameIndex) start")
            _ = try await frame.loadOrCreateOCVFeatures(of: mode)
            Log.d("frame \(frame.frameIndex) done")
        } catch {
            let str = "frame \(frame.frameIndex) error during keypoint detection: \(error)"
            Log.e(str)
            errorClosure(str)
        }
    }
}
