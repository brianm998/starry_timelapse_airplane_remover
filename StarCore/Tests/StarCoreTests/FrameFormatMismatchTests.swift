import XCTest
@testable import StarCore

/// The sequence's format is read from frame 0 and every frame is built with it.  A later frame of
/// another size (a thumbnail, a frame from another camera) used to reach the blob stage and trap
/// in `FullFrameBlobber`, or merge at the wrong size.  It must be a frame error instead.
final class FrameFormatMismatchTests: FrameHarnessTestCase {

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var errors: [String] = []
        func set(_ e: [String]) { lock.lock(); errors = e; lock.unlock() }
        var value: [String] { lock.lock(); defer { lock.unlock() }; return errors }
    }

    /// Runs the real frame graph over a 3 frame sequence whose middle frame is half size and
    /// returns the error list `Processor.process` would return.
    private func run(cleanMethod: CleanMethod, name: String) async throws -> (FrameHarness, [String]) {
        let h = try await FrameHarness.make(frameCount: 3, width: 640, height: 480,
                                            frameSizes: [1: (width: 320, height: 240)],
                                            staticStars: true,
                                            named: name)
        harness = h
        // CLAUDE.md: the GPU median merge crashes this machine
        await h.updateConfig {
            $0.useGPUForMerge = false
            $0.cleanMethod = cleanMethod
        }
        nonisolated(unsafe) let frames = h.frames
        let builder = FrameGraphBuilder()
        await builder.set(configManager: h.configManager)
        let collected = Collected()
        let done = expectation(description: "graph completed")
        await builder.build(frames: frames,
                            closure: { errors in collected.set(errors); done.fulfill() },
                            errorClosure: { _ in })
        await fulfillment(of: [done], timeout: 300)
        return (h, collected.value)
    }

    /// A1
    func testAHalfSizeMiddleFrameIsAFrameErrorAndTheOtherTwoAreWritten() async throws {
        let (h, errors) = try await run(cleanMethod: .automatic(false), name: "formatdefault")

        XCTAssertTrue(errors.contains { $0.hasPrefix("frame 1") },
                      "the half size frame must be a frame error, got \(errors)")
        XCTAssertFalse(errors.contains { $0.hasPrefix("frame 0") || $0.hasPrefix("frame 2") },
                       "the uniform frames must not be errors, got \(errors)")
        XCTAssertTrue(h.imageAccessor.imageExists(frameIndex: 0, ofType: .final, atSize: .original))
        XCTAssertTrue(h.imageAccessor.imageExists(frameIndex: 2, ofType: .final, atSize: .original))
        XCTAssertFalse(h.imageAccessor.imageExists(frameIndex: 1, ofType: .final, atSize: .original))
    }

    /// A2: before the fix the blob stage's fatalError ends the test process.
    func testASelectiveRunWithAHalfSizeMiddleFrameDoesNotTerminateTheProcess() async throws {
        let (_, errors) = try await run(cleanMethod: .selective, name: "formatselective")

        XCTAssertTrue(errors.contains { $0.hasPrefix("frame 1") },
                      "the half size frame must be a frame error, got \(errors)")
    }
}
