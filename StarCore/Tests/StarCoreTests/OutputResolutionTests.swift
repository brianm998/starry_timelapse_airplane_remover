import XCTest
@testable import StarCore

final class OutputResolutionTests: XCTestCase {
    func testNamesAndBareHeightsParse() {
        XCTAssertEqual(OutputResolution(name: "4k"), .p2160)
        XCTAssertEqual(OutputResolution(name: "2K"), .p1440)
        XCTAssertEqual(OutputResolution(name: "1080p"), .p1080)
        XCTAssertEqual(OutputResolution(name: "720"), .p720)
        XCTAssertEqual(OutputResolution(name: "original"), .original)
        XCTAssertNil(OutputResolution(name: "0"))
        XCTAssertNil(OutputResolution(name: "999p"))
        XCTAssertNil(OutputResolution(name: "banana"))
    }

    func testHeightRoundTrips() {
        for r in OutputResolution.allCases { XCTAssertEqual(OutputResolution(height: r.height), r) }
        XCTAssertEqual(OutputResolution(height: 123), .original)
    }

    func testOnlyScalingResolutionsAddArguments() {
        XCTAssertEqual(OutputResolution.original.ffmpegArguments, [])
        XCTAssertEqual(OutputResolution.p480.ffmpegArguments, ["-vf", "scale=-2:'min(480,ih)'"])
    }
}
