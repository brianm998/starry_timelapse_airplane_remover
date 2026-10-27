import XCTest
@testable import StarCore

final class FrameDecodeFormatTests: XCTestCase {

    func testDefaultsAre16BitTiffAndJPEGAt80() {
        XCTAssertEqual(FrameDecodeFormat().kind, .tiff16)
        XCTAssertEqual(FrameDecodeFormat.jpeg.jpegQuality, 80)
        XCTAssertEqual(FrameDecodeFormat.tiff16.fileExtension, "tiff")
        XCTAssertEqual(FrameDecodeFormat.tiff8.fileExtension, "tiff")
        XCTAssertEqual(FrameDecodeFormat.jpeg.fileExtension, "jpg")
    }

    func testTheFFmpegArgumentsOfEachFormat() {
        XCTAssertEqual(FrameDecodeFormat.tiff16.ffmpegOutputArguments(in: "/d"),
                       ["-pix_fmt", "rgb48le", "-compression_algo", "packbits", "/d/image_%04d.tiff"])
        XCTAssertEqual(FrameDecodeFormat.tiff8.ffmpegOutputArguments(in: "/d"),
                       ["-pix_fmt", "rgb24", "-compression_algo", "packbits", "/d/image_%04d.tiff"])
        XCTAssertEqual(FrameDecodeFormat.jpeg.ffmpegOutputArguments(in: "/d"),
                       ["-pix_fmt", "yuvj444p", "-q:v", "8", "/d/image_%04d.jpg"])
    }

    func testQualityMapsOntoFFmpegsScaleAndIsClamped() {
        XCTAssertEqual(FrameDecodeFormat(kind: .jpeg, jpegQuality: 100).ffmpegQualityScale, 2)
        XCTAssertEqual(FrameDecodeFormat(kind: .jpeg, jpegQuality: 1).ffmpegQualityScale, 31)
        XCTAssertEqual(FrameDecodeFormat(kind: .jpeg, jpegQuality: 500).jpegQuality, 100)
        XCTAssertEqual(FrameDecodeFormat(kind: .jpeg, jpegQuality: -3).jpegQuality, 1)
    }

    func testDiskEstimateGrowsWithQualityAndOrdersTheFormats() throws {
        func bytes(_ f: FrameDecodeFormat) throws -> Int64 {
            try XCTUnwrap(f.estimatedBytes(width: 4000, height: 3000, frameCount: 100))
        }
        XCTAssertLessThan(try bytes(.tiff8), try bytes(.tiff16))
        XCTAssertLessThan(try bytes(.jpeg), try bytes(.tiff8))
        var last: Int64 = 0
        for q in 1...100 {
            let b = try bytes(FrameDecodeFormat(kind: .jpeg, jpegQuality: q))
            XCTAssertGreaterThanOrEqual(b, last)
            last = b
        }
        XCTAssertNil(FrameDecodeFormat.tiff16.estimatedBytes(width: 4000, height: 3000, frameCount: 0))
    }

    func testProbeParsing() {
        let p = VideoProbe.parse(ffprobeOutput: "width=1920\nheight=1080\nr_frame_rate=24/1\nduration=2.000000\nnb_frames=48\n")
        XCTAssertEqual(p, VideoProbe(width: 1920, height: 1080, frameCount: 48, frameCountIsExact: true))
        // no frame count: worked out from duration and rate
        let q = VideoProbe.parse(ffprobeOutput: "width=640\nheight=360\nr_frame_rate=30000/1001\nduration=10.0\nnb_frames=N/A\n")
        XCTAssertEqual(q?.frameCount, 300)
        XCTAssertEqual(q?.frameCountIsExact, false)
        // nothing to go on for the count
        XCTAssertNil(VideoProbe.parse(ffprobeOutput: "width=640\nheight=360\nnb_frames=N/A\n")?.frameCount)
        XCTAssertNil(VideoProbe.parse(ffprobeOutput: "garbage"))
    }

    func testTIFFCompressionIsPackBitsByDefaultAndShowsInTheArguments() {
        XCTAssertEqual(FrameDecodeFormat().tiffCompression, .packBits)
        let raw = FrameDecodeFormat(kind: .tiff16, tiffCompression: .none)
        XCTAssertEqual(raw.ffmpegOutputArguments(in: "/d"), ["-pix_fmt", "rgb48le", "-compression_algo", "raw", "/d/image_%04d.tiff"])
        XCTAssertEqual(FrameDecodeFormat(kind: .tiff8, tiffCompression: .none).ffmpegOutputArguments(in: "/d", digits: 5),
                       ["-pix_fmt", "rgb24", "-compression_algo", "raw", "/d/image_%05d.tiff"])
        // jpeg ignores it
        XCTAssertEqual(FrameDecodeFormat(kind: .jpeg, tiffCompression: .none).ffmpegOutputArguments(in: "/d"),
                       FrameDecodeFormat.jpeg.ffmpegOutputArguments(in: "/d"))
    }

    func testAFormatStoredBeforeTheCompressionWasAChoiceKeepsItsMeaning() throws {
        let old = Data(#"{"kind":"tiff16","jpegQuality":80}"#.utf8)
        let decoded = try JSONDecoder().decode(FrameDecodeFormat.self, from: old)
        XCTAssertEqual(decoded.tiffCompression, .packBits)
        XCTAssertEqual(decoded, .tiff16)
        let round = try JSONDecoder().decode(FrameDecodeFormat.self,
                                             from: JSONEncoder().encode(FrameDecodeFormat(kind: .tiff8, tiffCompression: .none)))
        XCTAssertEqual(round.tiffCompression, TIFFCompressionAlias.none)
    }

    func testTheDiskEstimateFollowsTheCompression() throws {
        let packed = try XCTUnwrap(FrameDecodeFormat.tiff16.estimatedBytes(width: 1000, height: 1000, frameCount: 10))
        let raw = try XCTUnwrap(FrameDecodeFormat(kind: .tiff16, tiffCompression: .none).estimatedBytes(width: 1000, height: 1000, frameCount: 10))
        XCTAssertEqual(raw, 60_000_000)
        XCTAssertLessThan(raw, packed)
    }

    func testCompressionArgumentParsing() {
        XCTAssertEqual(FrameDecodeFormat.tiffCompression(argument: "none"), TIFFCompressionAlias.none)
        XCTAssertEqual(FrameDecodeFormat.tiffCompression(argument: "PackBits"), .packBits)
        XCTAssertNil(FrameDecodeFormat.tiffCompression(argument: "lzw"))
    }
}

private typealias TIFFCompressionAlias = FrameDecodeFormat.TIFFCompression
