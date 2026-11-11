#if canImport(CoreGraphics)
import XCTest
import CoreGraphics
import StarCppBridge
@testable import StarCore

/// The mac gui keeps one image per outlier group for as long as the group lives, and paints it as
/// a template (alpha only) in the decision colour.  So the image is a mask: one byte per pixel of
/// the group's bounding box, 0xFF where the group has a pixel.
final class OutlierGroupTestImageTests: XCTestCase {

    func testTestImageIsEightBitMaskWithTheGroupsPixelsSet() async throws {
        // a bounding box that does not start at the origin, so the offset arithmetic is exercised
        let coords = [(10, 20), (11, 21), (12, 22), (13, 20), (14, 23)]
        let set = Set(coords.map { SortablePixel(x: $0.0, y: $0.1, value: .sixteenBit(1000)) })
        let bounds = BoundingBox(min: Coord(x: 10, y: 20), max: Coord(x: 14, y: 23))
        let group = OutlierGroup(id: 1, size: UInt(coords.count), brightness: 1000,
                                 bounds: bounds, frameIndex: 0,
                                 imageWidth: 100, imageHeight: 100, pixels: [],
                                 pixelSet: set)

        let maybeImage = await group.testImage()
        let image = try XCTUnwrap(maybeImage)

        XCTAssertEqual(image.width, bounds.width)
        XCTAssertEqual(image.height, bounds.height)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bitsPerPixel, 8, "one byte per pixel, not eight")
        XCTAssertEqual(image.bytesPerRow, bounds.width)
        XCTAssertTrue(image.isMask, "an alpha-only image: the view paints it as a template, so only coverage counts")

        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        XCTAssertEqual(data.count, bounds.width * bounds.height)
        var expected = [UInt8](repeating: 0, count: bounds.width * bounds.height)
        for (x, y) in coords { expected[(y - 20) * bounds.width + (x - 10)] = 0xFF }
        XCTAssertEqual([UInt8](data), expected)

        // asking again returns the cached image
        let maybeAgain = await group.testImage()
        let again = try XCTUnwrap(maybeAgain)
        XCTAssertTrue(again === image)
    }

    /// A pixel outside the group's bounds must be ignored rather than written past the buffer.
    func testPixelOutsideTheBoundsIsIgnored() async throws {
        let inside = SortablePixel(x: 5, y: 5, value: .sixteenBit(1000))
        let outside = [SortablePixel(x: 4, y: 5, value: .sixteenBit(1000)),
                       SortablePixel(x: 7, y: 5, value: .sixteenBit(1000)),
                       SortablePixel(x: 5, y: 9, value: .sixteenBit(1000))]
        let bounds = BoundingBox(min: Coord(x: 5, y: 5), max: Coord(x: 6, y: 6))
        let group = OutlierGroup(id: 2, size: 4, brightness: 1000,
                                 bounds: bounds, frameIndex: 0,
                                 imageWidth: 100, imageHeight: 100, pixels: [],
                                 pixelSet: Set([inside] + outside))
        let maybeImage = await group.testImage()
        let image = try XCTUnwrap(maybeImage)
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        XCTAssertEqual([UInt8](data), [0xFF, 0, 0, 0])
    }
}
#endif
