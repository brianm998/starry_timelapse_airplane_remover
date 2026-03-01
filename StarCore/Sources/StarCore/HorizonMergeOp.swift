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
        self.name = "horizon merge frame \(frame.frameIndex)"
    }

    func addDependencies(from opMap: [Int: Operation]) async {
        for neighborIndex in await frame.getHorizonMergeIndices() {
            if let origHorizonOp = opMap[neighborIndex] {
                self.addDependency(origHorizonOp)
            } else {
                Log.w("frame \(neighborIndex) had no horizon op")
            }
        }
    }
    
    override func execute() {
        task = Task {
            defer {
                Log.d("frame \(frame.frameIndex) end")
                finish()
            }
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
