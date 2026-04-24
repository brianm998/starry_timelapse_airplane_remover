import Foundation
import logging

public final class OutlierOp: AsyncOperation, @unchecked Sendable {
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
        super.init(for: .outliers, rawImageBytes: rawImageBytes, memoryMultiplier: memoryMultiplier)
        self.name = "outliers for frame \(frame.frameIndex)"
    }

    public override func asyncExecute() async {
        do {
            Log.d("frame \(frame.frameIndex) start")
            if await frame.usesOutliers {
                Log.d("frame \(frame.frameIndex) loading outliers")
                try await frame.loadOutliers()
            }
            Log.d("frame \(frame.frameIndex) done")
        } catch {
            let str = "frame \(frame.frameIndex) error with outliers: \(error)"
            Log.e(str)
            errorClosure(str)
        }
    }
}
