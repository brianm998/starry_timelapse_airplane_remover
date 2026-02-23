import Foundation
import logging

final class HorizonMergeOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let errorClosure: (String) -> Void
    
    init(
      frame: FrameAirplaneRemover,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.errorClosure = errorClosure
        super.init(for: .mergedHorizon)
    }

    override func execute() {
        task = Task {
            defer { finish() }
            do {
                Log.d("frame \(frame.frameIndex) starting")
                _ = try await frame.loadOrCreateFinalHorizonMask()
                Log.d("frame \(frame.frameIndex) done")
            } catch {
                let str = "frame \(frame.frameIndex) error during horizon merge: \(error)"
                Log.e(str)
                errorClosure(str)
            }
        }
    }
}
