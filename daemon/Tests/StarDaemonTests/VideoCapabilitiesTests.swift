import XCTest
import StarCore
import StarDaemonMessages
@testable import stard

/// What the Render Video dialog is told about each choice it offers, beside the names it already had: the descriptions macOS's sheet shows under
/// the pickers.
final class VideoCapabilitiesTests: XCTestCase {

    private let caps = ExportHandlers.videoCapabilities()

    func testEveryFrameRateSaysWhatItIsFor() {
        XCTAssertEqual(caps.frameRateCaps.dropLast().map(\.value), caps.frameRates, "the same rates, in the same order")
        for rate in caps.frameRateCaps { XCTAssertFalse(rate.description_p.isEmpty, "\(rate.value) has no description") }
        XCTAssertEqual(caps.frameRateCaps.first { $0.value == 29.97 }?.description_p, FrameRate.fps_29_97.description)
    }

    /// Custom is a choice of its own, last, and not one of the standard rates a client would list.
    func testCustomIsAChoiceOfItsOwnAndNotAStandardRate() throws {
        let last = try XCTUnwrap(caps.frameRateCaps.last)
        XCTAssertTrue(last.custom)
        XCTAssertEqual(caps.frameRateCaps.filter(\.custom).count, 1)
        XCTAssertEqual(caps.frameRateCaps.count, caps.frameRates.count + 1, "the standard rates, and Custom besides")
        XCTAssertGreaterThan(last.value, 0, "the field starts at a rate the daemon would accept")
    }

    func testEveryCodecAndEncoderHasADescription() throws {
        XCTAssertFalse(caps.codecs.isEmpty, "this machine's ffmpeg offers some codec")
        for codec in caps.codecs {
            XCTAssertFalse(codec.description_p.isEmpty, "\(codec.codec)")
            for encoder in codec.encoders { XCTAssertFalse(encoder.description_p.isEmpty, "\(codec.codec)/\(encoder.encoder)") }
        }
    }

    /// The names and the descriptions go together, entry for entry: a client may look one up by position as well as by name.
    func testThePixelFormatAndMuxerDetailsAreInTheOrderOfTheirNames() {
        for codec in caps.codecs {
            for encoder in codec.encoders {
                XCTAssertEqual(encoder.pixelFormatCaps.map(\.name), encoder.pixelFormats, "\(encoder.encoder)")
                XCTAssertEqual(encoder.muxerCaps.map(\.name), encoder.muxers, "\(encoder.encoder)")
            }
        }
    }

    func testAPixelFormatSaysWhatItIsMadeOf() throws {
        let format = try XCTUnwrap(caps.codecs.flatMap(\.encoders).flatMap(\.pixelFormatCaps).first)
        let known = try XCTUnwrap(FFmpegPixelFormat(rawValue: format.name))
        XCTAssertEqual(Int(format.components), known.numberOfComponents)
        XCTAssertEqual(Int(format.bitsPerPixel), known.bitsPerPixel)
        XCTAssertEqual(format.bitDepths, known.bitDepths)
    }

    /// A container's files are called what the container's own extension says, not its muxer name: Matroska's muxer is `matroska` and a file called
    /// that opens in nothing.
    func testAContainerNamesItsFileExtension() {
        let muxers = caps.codecs.flatMap(\.encoders).flatMap(\.muxerCaps)
        XCTAssertFalse(muxers.isEmpty)
        for muxer in muxers {
            XCTAssertFalse(muxer.fileExtension.isEmpty, muxer.name)
            XCTAssertFalse(muxer.fileExtension.hasPrefix("."), "without the dot: \(muxer.fileExtension)")
            XCTAssertFalse(muxer.description_p.isEmpty, muxer.name)
        }
        if let matroska = muxers.first(where: { $0.name == "matroska" }) {
            XCTAssertEqual(matroska.fileExtension, "mkv")
        }
    }
}
