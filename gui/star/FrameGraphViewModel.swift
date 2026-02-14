import Observation
import StarCore

@MainActor
@Observable
final class FrameGraphViewModel {

    var operationQueueStats: OperationQueueStats? 

    init() {
        self.operationQueueStats = nil

        Task {
            let queues = await frameGraphBuilder.queues()

            self.operationQueueStats = OperationQueueStats(queue: queues.queue)
        }
    }
}

