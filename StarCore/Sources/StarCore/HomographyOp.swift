import Foundation
import logging

final class HomographyOp: AsyncOperation, @unchecked Sendable {
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
            super.init(for: .starHomography, rawImageBytes: rawImageBytes)
            self.name = "star homography for frame \(frame.frameIndex)"
        } else {
            super.init(for: .earthHomography, rawImageBytes: rawImageBytes)
            self.name = "earth homography for frame \(frame.frameIndex)"
        }
    }

    override func asyncExecute() async {
        do {
            Log.d("frame \(frame.frameIndex) start")
            let _ = try await frame.loadOrCreateHomography(of: mode)
            Log.d("frame \(frame.frameIndex) done")
        } catch {
            let str = "frame \(frame.frameIndex) error during homography calculation: \(error)"
            Log.e(str)
            errorClosure(str)
        }
    }
}
