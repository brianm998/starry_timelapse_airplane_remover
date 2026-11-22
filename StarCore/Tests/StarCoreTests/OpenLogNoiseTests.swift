import XCTest
import Foundation
import logging
@testable import StarCore

/// Records every line the logger delivers, so a test can say what a code path printed.
private final class RecordingHandler: LogHandler, @unchecked Sendable {
    let level: Log.Level = .debug
    private let lock = NSLock()
    private var recorded: [(level: Log.Level, message: String)] = []

    func log(message: String, at fileLocation: String, with data: LogData?,
             at logLevel: Log.Level, logTime: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        recorded.append((logLevel, message))
    }

    var lines: [(level: Log.Level, message: String)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Log delivery is asynchronous and in order: once a sentinel arrives, everything logged
    /// before it has too.
    func drain() async {
        let sentinel = "OpenLogNoiseTests-sentinel-\(UUID().uuidString)"
        Log.d(sentinel)
        for _ in 0..<500 {
            if lines.contains(where: { $0.message.contains(sentinel) }) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the log handler never saw the sentinel")
    }
}

final class OpenLogNoiseTests: XCTestCase {
    private var harness: FrameHarness?
    private let handler = RecordingHandler()

    override func setUp() {
        super.setUp()
        Log.add(handler: handler, for: .gui)
    }

    override func tearDown() {
        Log.removeHandler(for: .gui)
        harness?.cleanUp()
        harness = nil
        super.tearDown()
    }

    func testOpenIsQuiet() async throws {
        let count = 20
        let h = try await FrameHarness.make(frameCount: count, named: "opennoise")
        harness = h
        let root = h.root.path

        for i in 0..<count {
            // what opening a static sequence asks of every frame
            _ = await h.frames[i].outlierProcessor.loadOutliersFromFile()
            _ = await h.imageAccessor.loadInt(frameIndex: i, type: .horizon, atSize: .original)
            // the gui's missing-preview loop
            for mode in FrameViewMode.allCases
            where h.imageAccessor.nameForImage(frameIndex: i, ofType: mode, atSize: .original) != nil {
                _ = h.imageAccessor.urlForImage(frameIndex: i, ofType: mode, atSize: .original)
            }
        }
        await handler.drain()

        let ours = handler.lines.filter { $0.message.contains(root) || $0.message.contains("blobs") }
        let loud = ours.filter { $0.level == .warn || $0.level == .info || $0.level == .error }
        XCTAssertTrue(loud.isEmpty, "opening logged: \(loud.map { "\($0.level) \($0.message)" })")
    }

    func testConfigUpdateLogsOncePerChange() async throws {
        let fraction = 0.5123
        LogOnChange.configBlock.reset()
        await MemoryMonitor.shared.configure(budgetFraction: fraction)
        await MemoryMonitor.shared.configure(budgetFraction: fraction)
        await handler.drain()
        func configured() -> Int {
            handler.lines.filter { $0.message.hasPrefix("MemoryMonitor configured") }.count
        }
        XCTAssertEqual(configured(), 1, "an unchanged config logged the block twice")

        await MemoryMonitor.shared.configure(budgetFraction: 0.6123)
        await handler.drain()
        XCTAssertEqual(configured(), 2, "a changed value must still be logged")

        let cache = KeypointCache()
        await cache.configure(maxBytes: 64 * 1024 * 1024)
        await cache.configure(maxBytes: 64 * 1024 * 1024)
        await handler.drain()
        let budgets = handler.lines.filter { $0.message.hasPrefix("KeypointCache budget") }.count
        XCTAssertEqual(budgets, 1)
    }

    func testRealProblemsStillLogged() async throws {
        let h = try await FrameHarness.make(frameCount: 2, named: "realproblems")
        harness = h

        // an original that vanished
        let original = try XCTUnwrap(h.imageAccessor.nameForImage(
                                       frameIndex: 1, ofType: .original, atSize: .original))
        try FileManager.default.removeItem(atPath: original)
        _ = await h.imageAccessor.loadInt(frameIndex: 1, type: .original, atSize: .original)

        // an outliers.bin that is there but is not one
        let outlier = await h.frames[0].outlierProcessor
        let path = await outlier.blobBinaryFilename
        try FileManager.default.createDirectory(
          atPath: (path as NSString).deletingLastPathComponent,
          withIntermediateDirectories: true)
        // present but unreadable: a directory where the file belongs makes the read throw
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = await outlier.loadOutliersFromFile()

        await handler.drain()
        let infos = handler.lines.filter { $0.level == .info }.map { $0.message }
        XCTAssertTrue(infos.contains { $0.contains(original) && $0.contains("does not exist") },
                      "a missing original went unlogged")
        XCTAssertTrue(infos.contains { $0.contains("failed to load outliers") && $0.contains(path) },
                      "an unparsable outliers.bin went unlogged")
    }
}
