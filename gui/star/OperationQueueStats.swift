import Foundation
import Observation

@MainActor
@Observable
final class OperationQueueStats {

    var operationCount: Int = 0
    var maxConcurrentOperationCount: Int = 0
    var isSuspended: Bool = false
    var name: String = ""

    private weak var queue: OperationQueue?
    private var observations: [NSKeyValueObservation] = []

    init(queue: OperationQueue) {
        self.queue = queue

        syncFromQueue(queue)

        observations = [
          queue.observe(\.operationCount, options: [.initial, .new]) { [weak self] q, _ in
              Task { @MainActor in
                  self?.operationCount = q.operationCount
              }
            },
            queue.observe(\.maxConcurrentOperationCount, options: [.initial, .new]) { [weak self] q, _ in
              Task { @MainActor in
                  self?.maxConcurrentOperationCount = q.maxConcurrentOperationCount
              }
            },
            queue.observe(\.isSuspended, options: [.initial, .new]) { [weak self] q, _ in
              Task { @MainActor in
                  self?.isSuspended = q.isSuspended
              }
            },
            queue.observe(\.name, options: [.initial, .new]) { [weak self] q, _ in
              Task { @MainActor in
                  self?.name = q.name ?? ""
              }
            }
        ]
    }

    private func syncFromQueue(_ q: OperationQueue) {
        operationCount = q.operationCount
        maxConcurrentOperationCount = q.maxConcurrentOperationCount
        isSuspended = q.isSuspended
        name = q.name ?? ""
    }
}
