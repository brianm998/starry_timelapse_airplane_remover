import Foundation
import logging

final class HorizonDetectionOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let errorClosure: (String) -> Void
    
    init(frame: FrameAirplaneRemover, errorClosure: @escaping (String) -> Void) {
        self.frame = frame
        self.errorClosure = errorClosure
    }

    override func execute() {
        task = Task {
            defer { finish() }
            do {
                Log.d("frame \(frame.frameIndex) starting")
                _ = try await frame.loadOrCreateHorizonMask()
                Log.d("frame \(frame.frameIndex) done")
            } catch {
                let str = "frame \(frame.frameIndex) error during horizon detection: \(error)"
                Log.e(str)
                errorClosure(str)
            }
        }
    }
}
