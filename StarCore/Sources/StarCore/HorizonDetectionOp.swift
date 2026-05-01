import Foundation
import logging

final class HorizonDetectionOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let errorClosure: (String) -> Void

    init(
      frame: FrameAirplaneRemover,
      rawImageBytes: UInt64 = 0,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.errorClosure = errorClosure
        super.init(for: .horizon, rawImageBytes: rawImageBytes)
        self.name = "horizon detect frame \(frame.frameIndex)"
    }

    override func asyncExecute() async {
        guard !Task.isCancelled else {
            Log.d("frame \(frame.frameIndex) horizon detection cancelled")
            return
        }
        do {
            Log.d("frame \(frame.frameIndex) starting")
            _ = try await frame.loadOrCreateHorizonMask()
            Log.d("frame \(frame.frameIndex) done")
        } catch is CancellationError {
            Log.d("frame \(frame.frameIndex) horizon detection cancelled")
        } catch {
            let str = "frame \(frame.frameIndex) error during horizon detection: \(error)"
            Log.e(str)
            errorClosure(str)
        }
    }
}
