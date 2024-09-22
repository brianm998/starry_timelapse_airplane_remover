import Foundation

// keeps track of random Tasks

@globalActor public actor TaskWaiter {

    public static let shared = TaskWaiter()
    
    private var tasks: [Task<Void,Never>] = []
    
    public func task(priority: TaskPriority = .medium, closure: @escaping @Sendable () async -> Void) {
        let task = Task(priority: priority) {
            await closure()
        }
        self.add(task: task)
    }

    private func add(task: Task<Void,Never>) {
        tasks.append(task)
    }
    
    public func finish() async {
        while tasks.count > 0 {
            let next = tasks.removeFirst()
            _ = await next.value
        }
    }
}


