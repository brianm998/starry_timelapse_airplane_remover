import Foundation
import logging

final class HorizonDetectionOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let errorClosure: (String) -> Void

    init(
      frame: FrameAirplaneRemover,
      rawImageBytes: UInt64 = 0,
      memoryMultiplier: UInt64? = nil,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.errorClosure = errorClosure
        super.init(for: .horizon, rawImageBytes: rawImageBytes,
                   memoryMultiplier: memoryMultiplier)
        self.name = "horizon detect frame \(frame.frameIndex)"
    }

    override func asyncExecute() async {
        guard !Task.isCancelled else {
            Log.d("frame \(frame.frameIndex) horizon detection cancelled")
            return
        }
        do {
            Log.d("frame \(frame.frameIndex) starting")
            let mask = try await frame.loadOrCreateHorizonMask()
            await frame.accumulateDetectedHorizon(mask)
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
