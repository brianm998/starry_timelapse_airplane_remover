import XCTest
@testable import StarCore

final class FrameSourceTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FrameSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    func testADirectorySourceHasEveryFrameAtOnceInTheOrderImageSequenceUsed() async throws {
        for name in ["image_0002.tiff", "image_0001.tiff", "image_0003.tiff", "notes.txt"] {
            FileManager.default.createFile(atPath: scratch.appendingPathComponent(name).path, contents: Data([0]))
        }
        let source = try DirectoryFrameSource(dirname: scratch.path, supportedImageFileTypes: [".tiff"])
        XCTAssertEqual(source.frameCount, 3)
        XCTAssertEqual(source.path(forFrame: 0), "\(scratch.path)/image_0001.tiff")
        XCTAssertTrue((0..<3).allSatisfy(source.isAvailable))
        XCTAssertFalse(source.isAvailable(3))
        XCTAssertEqual(source.availableFrames, IndexSet(0..<3))
        XCTAssertTrue(source.progress.isComplete)
        XCTAssertEqual(source.estimatedSecondsUntilAvailable(1), 0)

        let sequence = try ImageSequence(dirname: scratch.path, supportedImageFileTypes: [".tiff"])
        let names = await sequence.filenames
        XCTAssertEqual(names, (0..<3).map { source.path(forFrame: $0) })
    }

    func testADirectorySourceWaitReturnsAtOnceAndAnOutOfRangeFrameFails() async throws {
        FileManager.default.createFile(atPath: scratch.appendingPathComponent("image_0001.tiff").path, contents: Data([0]))
        let source = try DirectoryFrameSource(dirname: scratch.path, supportedImageFileTypes: [".tiff"])
        try await source.waitUntilAvailable(0)
        try source.waitUntilAvailableBlocking(0)
        do { try await source.waitUntilAvailable(5); XCTFail("should have thrown") } catch {}
        var first: FrameSourceEvent?
        for await event in source.events() { first = event; break }
        if case .snapshot(let available, let count, _)? = first {
            XCTAssertEqual(count, 1)
            XCTAssertEqual(available, IndexSet(integer: 0))
        } else {
            XCTFail("the first event is a snapshot")
        }
    }

    func testFrameNamesFollowTheCountAndKeepFourDigitsForShortVideos() {
        XCTAssertEqual(FrameNaming.digits(forFrameCount: 24), 4)
        XCTAssertEqual(FrameNaming.digits(forFrameCount: 9999), 4)
        XCTAssertEqual(FrameNaming.digits(forFrameCount: 10_000), 5)
        XCTAssertEqual(FrameNaming.digits(forFrameCount: 123_456), 6)
        XCTAssertEqual(FrameNaming.baseName(forFrame: 0, digits: 4), "image_0001")
        XCTAssertEqual(FrameNaming.baseName(forFrame: 9999, digits: 5), "image_10000")
        XCTAssertEqual(FrameNaming.fileName(forFrame: 41, digits: 4, fileExtension: "jpg"), "image_0042.jpg")
        XCTAssertEqual(FrameNaming.pattern(digits: 5, fileExtension: "tiff"), "image_%05d.tiff")
        // frame 10000 sorts after 2000 by index, which is what the source relies on instead of sorting names
        XCTAssertGreaterThan(FrameNaming.baseName(forFrame: 9999, digits: 5), FrameNaming.baseName(forFrame: 1999, digits: 5))
    }

    func testABookResumesItsWaitersAsFramesArriveAndFailsThemWhenTheCountSettles() throws {
        let book = FrameAvailabilityBook(frameCount: 10)
        let arrived = LockedBox<[Int]>([])
        let failed = LockedBox<[Int]>([])
        for index in [2, 8] {
            book.addWaiter(index) { result in
                if case .success = result { arrived.withValue { $0.append(index) } } else { failed.withValue { $0.append(index) } }
            }
        }
        book.markAvailable(IndexSet(0...3), progress: FrameExtractionProgress(extracted: 4, total: 10, isComplete: false))
        XCTAssertEqual(arrived.get(), [2])
        XCTAssertTrue(book.isAvailable(3))
        XCTAssertFalse(book.isAvailable(4))
        book.settleCount(6)
        XCTAssertEqual(failed.get(), [8])
        XCTAssertEqual(book.frameCount, 6)
    }

    func testCancellingAWaiterRemovesItAndCallsBackWithCancellation() {
        let book = FrameAvailabilityBook(frameCount: 10)
        let outcome = LockedBox<String>("")
        let token = book.addWaiter(5) { result in
            if case .failure(let error) = result, error is CancellationError { outcome.set("cancelled") } else { outcome.set("other") }
        }
        token.cancel()
        XCTAssertEqual(outcome.get(), "cancelled")
        XCTAssertTrue(book.waitingFrames.isEmpty)
        book.markAvailable(IndexSet(integer: 5), progress: FrameExtractionProgress(extracted: 1, total: 10, isComplete: false))
        XCTAssertEqual(outcome.get(), "cancelled", "a cancelled waiter is not called a second time")
    }

    func testAFailedBookFailsEveryWaiterAndEveryLaterOne() {
        let book = FrameAvailabilityBook(frameCount: 10)
        let failures = LockedBox(0)
        book.addWaiter(4) { if case .failure = $0 { failures.withValue { $0 += 1 } } }
        book.failEverything("ffmpeg died")
        XCTAssertEqual(failures.get(), 1)
        book.addWaiter(6) { if case .failure = $0 { failures.withValue { $0 += 1 } } }
        XCTAssertEqual(failures.get(), 2)
        XCTAssertEqual(book.availability(6), .failed("ffmpeg died"))
    }

    func testTheAsyncWaitIsCancellableAndDoesNotLeaveAWaiterBehind() async {
        let book = FrameAvailabilityBook(frameCount: 10)
        let source = BookOnlySource(book: book)
        let task = Task { try await source.waitUntilAvailable(7) }
        while book.waitingFrames.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }
        task.cancel()
        do { try await task.value; XCTFail("should have thrown") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(book.waitingFrames.isEmpty)
    }
}

/// The part of a source the async wait needs, over a bare book.
private final class BookOnlySource: FrameSource, @unchecked Sendable {
    let book: FrameAvailabilityBook
    init(book: FrameAvailabilityBook) { self.book = book }
    var frameCount: Int { book.frameCount }
    func path(forFrame index: Int) -> String { "/x/\(index)" }
    func isAvailable(_ index: Int) -> Bool { book.isAvailable(index) }
    func availability(_ index: Int) -> FrameAvailability { book.availability(index) }
    var availableFrames: IndexSet { book.availableSet }
    func whenAvailable(_ index: Int, _ callback: @escaping @Sendable (Result<Void, Error>) -> Void) -> FrameWaitToken {
        book.addWaiter(index, callback)
    }
    func prioritize(_ indices: [Int], reason: FramePriorityReason) {}
    func events() -> AsyncStream<FrameSourceEvent> { AsyncStream { $0.finish() } }
    var progress: FrameExtractionProgress { FrameExtractionProgress(extracted: 0, total: 0, isComplete: false) }
    func estimatedSecondsUntilAvailable(_ index: Int) -> Double? { nil }
    var sweepHead: Int? { nil }
    func stop() {}
}
