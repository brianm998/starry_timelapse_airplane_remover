import Foundation

final class GraphCompletionOp: Operation, @unchecked Sendable {
    private let completion: () async -> Void

    init(completion: @escaping () async -> Void) {
        self.completion = completion
        super.init()
        self.name = "Completion" 
    }

    override func main() {
        Task { @MainActor in
            await completion()
        }
    }
}
