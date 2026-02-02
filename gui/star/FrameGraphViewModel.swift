import Observation
import StarCore

@MainActor
@Observable
final class FrameGraphViewModel {

    var horizonStats: OperationQueueStats? 
    var keypointStats: OperationQueueStats? 
    var homographyStats: OperationQueueStats?
    var mergeStats: OperationQueueStats?

    init() {
        self.horizonStats = nil
        self.keypointStats = nil
        self.homographyStats = nil
        self.mergeStats = nil

        Task {
            let queues = await frameGraphBuilder.queues()

            self.horizonStats = OperationQueueStats(queue: queues.horizon)
            self.keypointStats = OperationQueueStats(queue: queues.keypoint)
            self.homographyStats = OperationQueueStats(queue: queues.homography)
            self.mergeStats = OperationQueueStats(queue: queues.merge)
        }
    }
}

