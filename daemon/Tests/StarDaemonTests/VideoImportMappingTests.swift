import XCTest
import StarCore
import StarDaemonMessages
@testable import stard

/// How `Session.OpenVideo` says what the frames are written as, and what `Session.ProbeVideo` answers.
final class VideoImportMappingTests: XCTestCase {

    func testAnOpenVideoRequestThatSaysNothingIs16BitTiff() {
        let format = Mapping.frameDecodeFormat(from: Star_V1_OpenVideoRequest())
        XCTAssertEqual(format, .tiff16)
    }

    func testEachWireFormatMapsToItsOwn() {
        var request = Star_V1_OpenVideoRequest()
        request.frameFormat = .tiff8
        XCTAssertEqual(Mapping.frameDecodeFormat(from: request).kind, .tiff8)
        request.frameFormat = .jpeg
        XCTAssertEqual(Mapping.frameDecodeFormat(from: request).kind, .jpeg)
        XCTAssertEqual(Mapping.frameDecodeFormat(from: request).jpegQuality, 80, "an unset quality is the default")
        request.jpegQuality = 35
        XCTAssertEqual(Mapping.frameDecodeFormat(from: request).jpegQuality, 35)
        request.jpegQuality = 4000
        XCTAssertEqual(Mapping.frameDecodeFormat(from: request).jpegQuality, 100, "clamped, not rejected")
    }

    func testProbingAFileThatIsNotAVideoIsNotKnown() {
        let response = Mapping.probeVideoResponse(for: "/nonexistent/video.mp4")
        XCTAssertFalse(response.known)
        XCTAssertEqual(response.frameCount, 0)
    }
}
