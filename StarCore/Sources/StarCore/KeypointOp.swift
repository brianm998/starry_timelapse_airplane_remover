import Foundation
import logging

final class KeypointOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    let mode: FrameViewMode
    let errorClosure: (String) -> Void
    private let limiter: KeypointLimiter

    init(
      frame: FrameAirplaneRemover,
      mode: FrameViewMode,
      limiter: KeypointLimiter,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.mode = mode
        self.limiter = limiter
        self.errorClosure = errorClosure
    }

    override func execute() {
        task = Task {
            defer {
                Log.d("frame \(frame.frameIndex) end")
                finish()
            }
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

    override public func start() {
        if isCancelled {
            isFinished = true
            return
        }

        Task {
            // DO NOT set isExecuting yet.
            await limiter.acquire { [weak self] in
                guard let self else { return }

                Task {
                    if self.isCancelled {
                        await self.limiter.release()
                        self.isFinished = true
                        return
                    }

                    self.isExecuting = true
                    self.execute()
                }
            }
        }
    }
}
