import Foundation
import logging

// the TaskMaster tasks of different priorities to be run at the right time
public actor TaskMaster {

    private var highPrioTasks: [TaskEnabler] = []
    private var mediumPrioTasks: [TaskEnabler] = []
    private var lowPrioTasks: [TaskEnabler] = []

    public var numberRunning = NumberRunning()
    private let maxConcurrentTasks: UInt
    
    public init(maxConcurrentTasks: UInt) {
        self.maxConcurrentTasks = maxConcurrentTasks
        Task { await self.numberRunning.set(taskMaster: self) }
    }
    
    public func register(_ enabler: TaskEnabler) async {
        if await numberRunning.startOnIncrement(to: maxConcurrentTasks) {
            // let it run right now
            enabler.enable()
        } else {
            // register to run it later
            switch enabler.priority {
            case .userInitiated:
                highPrioTasks.append(enabler)
            case .utility:
                lowPrioTasks.append(enabler)
            case .background:
                lowPrioTasks.append(enabler)
            case .high:
                highPrioTasks.append(enabler)
            case .medium:
                mediumPrioTasks.append(enabler)
            case .low:
                lowPrioTasks.append(enabler)
            default:
                lowPrioTasks.append(enabler)
            }
        }
    }

    private func pendingTaskCount() -> Int {
        highPrioTasks.count + 
        mediumPrioTasks.count + 
        lowPrioTasks.count
    }
    
    public func enableTask() async {
        while self.pendingTaskCount() > 0,
              await self.numberRunning.startOnIncrement(to: maxConcurrentTasks)
        {
            // we can start another task, look for one
            if highPrioTasks.count > 0 {
                highPrioTasks.removeFirst().enable()
            } else if mediumPrioTasks.count > 0 {
                mediumPrioTasks.removeFirst().enable()
            } else if lowPrioTasks.count > 0 {
                lowPrioTasks.removeFirst().enable()
            } else {
                // no tasks found to run,
                // decrement number running after increment above
                await numberRunning.decrement()
            }
        }
    }
}
