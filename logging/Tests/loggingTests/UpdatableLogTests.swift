import XCTest
@testable import logging

final class UpdatableLogTests: XCTestCase {

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var chunks: [String] = []
        func write(_ s: String) { lock.lock(); chunks.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return chunks }
        var joined: String { all.joined() }
    }

    private func makeLog(_ sink: Sink, interval: TimeInterval = 0.25, maxEvents: Int = 20) -> UpdatableLog {
        UpdatableLog(redrawInterval: interval, maxEventRows: maxEvents, output: { sink.write($0) })
    }

    func testARedrawIsOneWrite() async {
        let sink = Sink()
        let log = makeLog(sink, interval: 100)   // after the first draw, later updates only mark it dirty
        await log.log(name: "a", message: "first row", value: 1)
        await log.log(name: "b", message: "second row", value: 2)
        await log.log(name: "c", message: "third row", value: 3)
        let before = sink.all.count
        await log.flush()
        XCTAssertEqual(sink.all.count, before + 1, "a redraw of three rows was more than one write")
        XCTAssertTrue(sink.all.last!.contains("first row") && sink.all.last!.contains("third row"))
    }

    func testABatchIsDrawnOnce() async {
        let sink = Sink()
        let log = makeLog(sink, interval: 0)
        await log.beginBatch()
        for i in 0..<30 { await log.log(name: "row \(i)", message: "message \(i)", value: Double(i)) }
        let drawsDuring = await log.drawCount
        XCTAssertEqual(drawsDuring, 0, "something was drawn in the middle of a batch")
        await log.endBatch()
        let drawsAfter = await log.drawCount
        XCTAssertEqual(drawsAfter, 1)
        XCTAssertTrue(sink.joined.contains("message 29"))
    }

    func testABurstOfUpdatesIsThrottledButTheLastStateIsStillShown() async throws {
        let sink = Sink()
        let log = makeLog(sink, interval: 0.2)
        for i in 0..<200 { await log.log(name: "progress", message: "step \(i)", value: 1) }
        let early = await log.drawCount
        XCTAssertLessThanOrEqual(early, 2, "200 updates in a burst drew \(early) times")
        try await Task.sleep(nanoseconds: 500_000_000)    // the trailing draw
        let final = await log.drawCount
        XCTAssertLessThanOrEqual(final, 3)
        XCTAssertTrue(sink.joined.contains("step 199"), "the final state was never drawn")
    }

    func testOnlyTheMostRecentEventRowsAreKept() async {
        let sink = Sink()
        let log = makeLog(sink, interval: 0, maxEvents: 5)
        await log.log(name: "progress", message: "a progress row", value: 0)
        for i in 0..<40 { await log.logEvent(name: "event \(i)", message: "error number \(i)", value: Double(i + 1)) }
        let rows = await log.rowCount
        XCTAssertEqual(rows, 6, "five events and the progress row")
        await log.flush()
        let drawn = sink.all.last!
        XCTAssertTrue(drawn.contains("error number 39"))
        XCTAssertFalse(drawn.contains("error number 0 "), "an old event was still on screen")
        XCTAssertTrue(drawn.contains("a progress row"), "the progress row was trimmed")
    }

    func testUpdatingARowInPlaceDoesNotAddRows() async {
        let sink = Sink()
        let log = makeLog(sink, interval: 0)
        for i in 0..<10 { await log.log(name: "same", message: "value \(i)", value: 1) }
        let rows = await log.rowCount
        XCTAssertEqual(rows, 1)
    }
}
