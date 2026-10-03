import XCTest
import StarCppBridge
@testable import StarCore

/// A merge op decodes each distinct neighbour once, however many builds inside it ask.
final class DecodedFrameStoreTests: XCTestCase {

    private func tinyMat() -> MatWrapper {
        let width = 4, height = 4
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: width * height * 3)
        data.initialize(repeating: 7, count: width * height * 3)
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 3),
                          bytesPerRow: width * 3 * MemoryLayout<UInt16>.size,
                          data: UnsafeMutableRawPointer(data),
                          takeOwnership: true)
    }

    private func store() -> (DecodedFrameStore, Counter) {
        let counter = Counter()
        let store = DecodedFrameStore()
        let mat = tinyMat()
        store.decoder = { _ in counter.bump(); return mat }
        return (store, counter)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
    }

    func testPinnedPathDecodesOnceAcrossBuilds() {
        let (store, counter) = store()
        let pin = store.pin(["a", "b"])
        for _ in 0..<2 { // the star build, then the earth build
            XCTAssertNotNil(store.load("a"))
            XCTAssertNotNil(store.load("b"))
        }
        XCTAssertEqual(counter.value, 2, "one decode per distinct file")
        pin.release()
        XCTAssertEqual(store.pinnedPathCount, 0, "nothing is held once the pin is gone")
        _ = store.load("a")
        XCTAssertEqual(counter.value, 3, "an unpinned path decodes uncached")
    }

    func testOverlappingPinsShareAndLastReleaseFrees() {
        let (store, counter) = store()
        let first = store.pin(["a"])
        _ = store.load("a")
        let second = store.pin(["a"])
        _ = store.load("a")
        XCTAssertEqual(counter.value, 1, "the second op shares the first's decode")
        first.release()
        _ = store.load("a")
        XCTAssertEqual(counter.value, 1, "still held by the second pin")
        second.release()
        second.release() // idempotent
        XCTAssertEqual(store.pinnedPathCount, 0)
    }

    func testConcurrentAskersWaitForOneDecode() async {
        let (store, counter) = store()
        let pin = store.pin(["a"])
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { _ = store.load("a") }
            }
        }
        XCTAssertEqual(counter.value, 1)
        pin.release()
    }
}
