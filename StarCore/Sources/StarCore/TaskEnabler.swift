import Foundation
import logging
import Semaphore

// uses a semaphore to enable a task to wait for the right time to run
public class TaskEnabler {
    public let priority: TaskPriority
    private let semaphore = AsyncSemaphore(value: 0)
    
    public init(priority: TaskPriority) {
        self.priority = priority
    }

    public func wait() async { await semaphore.wait() }
    
    public func enable() { semaphore.signal() }

}
