import Foundation
import logging

public final class MergeOp: AsyncOperation, @unchecked Sendable {
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
        super.init(for: .merge, rawImageBytes: rawImageBytes, memoryMultiplier: memoryMultiplier)
        self.name = "merge frame \(frame.frameIndex)"
    }

    public override func asyncExecute() async {
        do {
            Log.d("frame \(frame.frameIndex) start")

            if await frame.processingState() == .complete {
                Log.i("frame \(frame.frameIndex) already complete, skipping merge")
                return
            }

            switch await frame.cleanMethod {
            case .automatic(let usesOutliers):
                if usesOutliers {
                    await frame.set(state: .secondClassification)
                    await frame.applyDecisionTreeToAllOutliers()
                }
                try await frame.finishAuto(useOutliers: usesOutliers)
            case .selective:
                await frame.set(state: .secondClassification)
                await frame.applyDecisionTreeToAllOutliers()
                try await frame.finishSelective()
            }
            Log.d("frame \(frame.frameIndex) done")
        } catch {
            let str = "frame \(frame.frameIndex) error during merge: \(error)"
            Log.e(str)
            errorClosure(str)
        }
    }
}
