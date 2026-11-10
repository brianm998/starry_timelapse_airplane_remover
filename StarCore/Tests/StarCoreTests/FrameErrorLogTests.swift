import XCTest
@testable import StarCore

final class FrameErrorLogTests: XCTestCase {

    /// Many threads appending at once: every error is there the moment the appends
    /// return, with no waiting for anything to settle.
    func testConcurrentAppendsAreAllReadBack() {
        let log = FrameErrorLog()
        let threads = 32
        let perThread = 500
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            for i in 0..<perThread {
                log.append("t\(t) e\(i)")
            }
        }
        let elements = log.elements()
        XCTAssertEqual(elements.count, threads * perThread)
        XCTAssertEqual(Set(elements).count, threads * perThread)
    }
}
