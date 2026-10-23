import XCTest
@testable import StarCore

/// The frame's removal alpha is stored as indices into the remove mask's own values; it has to
/// behave exactly like the `[Double]` per pixel it replaced.
final class RemovalAlphaLevelsTests: XCTestCase {

    /// The old convolution, verbatim: a Double per pixel, maskX outermost.
    private func oldAlpha(points: [(Int, Int)], mask: RemoveMask, width: Int, height: Int) -> ([Double], [UInt8]) {
        var alpha = [Double](repeating: 0, count: width * height)
        var yAxis = [UInt8](repeating: 0, count: height)
        let radius = Int(mask.radius)
        for (px, py) in points {
            let startX = px - radius, startY = py - radius
            for maskX in 0..<mask.size {
                for maskY in 0..<mask.size {
                    let fx = maskX + startX, fy = maskY + startY
                    if fx >= 0, fx < width, fy >= 0, fy < height {
                        let i = fy * width + fx
                        let m = mask.pixels[maskY * mask.size + maskX]
                        if m > alpha[i] { alpha[i] = m; yAxis[fy] = 0xFF }
                    }
                }
            }
        }
        return (alpha, yAxis)
    }

    private func newAlpha(points: [(Int, Int)], mask: RemoveMask, width: Int, height: Int) -> (RemovalAlphaLevels, [UInt8]) {
        var levels = RemovalAlphaLevels(mask: mask, pixelCount: width * height)
        let maskLevels = mask.pixels.map { levels.level(of: $0) }
        var yAxis = [UInt8](repeating: 0, count: height)
        let radius = Int(mask.radius)
        for (px, py) in points {
            let startX = px - radius, startY = py - radius
            for maskY in 0..<mask.size {
                let fy = maskY + startY
                if fy < 0 || fy >= height { continue }
                for maskX in 0..<mask.size {
                    let fx = maskX + startX
                    if fx >= 0, fx < width {
                        if levels.raise(fy * width + fx, to: maskLevels[maskY * mask.size + maskX]) { yAxis[fy] = 0xFF }
                    }
                }
            }
        }
        return (levels, yAxis)
    }

    func testTheIndexedAlphaEqualsTheDoubleAlphaPixelForPixel() {
        var state: UInt64 = 99
        func next(_ n: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int(state >> 33) % n }
        for (inner, radius) in [(2.0, 5.0), (0.0, 3.0), (4.0, 4.0), (1.5, 9.0)] {
            let mask = RemoveMask(innerWallSize: inner, radius: radius)
            let w = 70, h = 50
            // clustered points so masks overlap, plus ones hanging off every edge
            var points = (0..<80).map { _ in (next(w), next(h)) }
            points += [(-3, 10), (w + 2, 20), (30, -4), (40, h + 3), (0, 0), (w - 1, h - 1)]
            let (old, oldAxis) = oldAlpha(points: points, mask: mask, width: w, height: h)
            let (new, newAxis) = newAlpha(points: points, mask: mask, width: w, height: h)
            XCTAssertEqual(oldAxis, newAxis, "inner \(inner) radius \(radius)")
            for i in 0..<(w * h) {
                XCTAssertEqual(new[i], old[i], "pixel \(i) inner \(inner) radius \(radius)")
            }
            if radius > inner { XCTAssertTrue(old.contains { $0 > 0 && $0 < 1 }, "the fade was never exercised") }
        }
    }

    func testAnEmptyLevelsHasNothingAndZeroIsIndexZero() {
        let empty = RemovalAlphaLevels()
        XCTAssertTrue(empty.isEmpty)
        let mask = RemoveMask(innerWallSize: 2, radius: 4)
        let levels = RemovalAlphaLevels(mask: mask, pixelCount: 4)
        XCTAssertEqual(levels.level(of: 0), 0)
        XCTAssertEqual(levels[3], 0)
        XCTAssertEqual(levels.table, levels.table.sorted())
    }
}
