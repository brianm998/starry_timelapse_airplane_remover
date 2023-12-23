import Foundation

// keeps track of random Tasks

public class TaskWaiter {
    private static var tasks: [Task<Void,Never>] = []
    
    public static func task(priority: TaskPriority = .medium, closure: @escaping () async -> Void) {
        let task = Task(priority: priority) {
            await closure()
        }
        tasks.append(task)
    }

    public static func finish() async {
        while tasks.count > 0 {
            let next = tasks.removeFirst()
            _ = await next.value
        }
    }
}


