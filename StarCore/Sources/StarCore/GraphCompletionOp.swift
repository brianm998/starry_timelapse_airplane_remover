import Foundation

final class GraphCompletionOp: Operation, @unchecked Sendable {
    private let completion: () -> Void

    init(completion: @escaping () -> Void) {
        self.completion = completion
    }

    override func main() {
        Task { @MainActor in
            completion()
        }
    }
}
