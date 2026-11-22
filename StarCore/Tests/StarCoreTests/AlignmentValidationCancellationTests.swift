import XCTest
@testable import StarCore

/// A Stop cancels the queue's operations in no particular order, so validation can run
/// after a cancelled homography op with nothing stored.  That is not an alignment failure.
final class AlignmentValidationCancellationTests: XCTestCase {

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _errors = 0, _aborts = 0
        func error() { lock.lock(); _errors += 1; lock.unlock() }
        func abort() { lock.lock(); _aborts += 1; lock.unlock() }
        var errors: Int { lock.lock(); defer { lock.unlock() }; return _errors }
        var aborts: Int { lock.lock(); defer { lock.unlock() }; return _aborts }
    }

    private func run(cancelDependency: Bool) async throws -> Counter {
        let harness = try await FrameHarness.make(frameCount: 3, named: "validation-cancel")
        defer { harness.cleanUp() }
        await harness.updateConfig { $0.useGPUForMerge = false }
        let counter = Counter()
        let op = AlignmentValidationOp(
          frames: harness.frames,
          configManager: harness.configManager,
          errorClosure: { _ in counter.error() },
          abortClosure: { _ in counter.abort() })
        let dependency = BlockOperation {}
        if cancelDependency { dependency.cancel() }
        op.addDependency(dependency)
        await op.asyncExecute()
        return counter
    }

    func testCancelledDependencyIsNotAnError() async throws {
        let counter = try await run(cancelDependency: true)
        XCTAssertEqual(counter.errors, 0)
        XCTAssertEqual(counter.aborts, 0)
    }

    func testRealFailureStillReported() async throws {
        let counter = try await run(cancelDependency: false)
        XCTAssertEqual(counter.errors + counter.aborts, 1)
        XCTAssertEqual(counter.aborts, 1)
    }
}
