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

    func testTheCompressionAndTheWorkerLimitsComeFromTheRequest() {
        var request = Star_V1_OpenVideoRequest()
        XCTAssertEqual(Mapping.frameDecodeFormat(from: request).tiffCompression, .packBits, "what every earlier import wrote")
        request.tiffCompression = .none
        XCTAssertEqual(Mapping.frameDecodeFormat(from: request).tiffCompression, FrameDecodeFormat.TIFFCompression.none)

        XCTAssertEqual(Mapping.extractionSettings(from: request), .default, "0 is StarCore's default")
        request.extractionSettings.maxJumpWorkers = 3
        request.extractionSettings.maxLongGopJumpWorkers = 2
        XCTAssertEqual(Mapping.extractionSettings(from: request).maxJumpWorkers, 3)
        XCTAssertEqual(Mapping.extractionSettings(from: request).maxLongGOPJumpWorkers, 2)
    }

    func testFrameRangesCoalesceAndRoundTrip() {
        var set = IndexSet(0..<5)
        set.insert(integersIn: 9..<12)
        set.insert(20)
        let ranges = Mapping.frameRanges(set)
        XCTAssertEqual(ranges.map { [$0.start, $0.end] }, [[0, 5], [9, 12], [20, 21]])
        XCTAssertEqual(Mapping.indexSet(ranges), set)
    }

    func testTheOldProbeNumbersStayPackBitsAndTheRawOnesAreExact() {
        // an unreadable video says nothing, but the sizes are for readable ones; check the constants through a readable shape
        XCTAssertEqual(FrameDecodeFormat(kind: .tiff16, tiffCompression: .none).estimatedBytesPerPixel, 6.0)
        XCTAssertEqual(FrameDecodeFormat.tiff16.estimatedBytesPerPixel, 6.1)
    }
}
