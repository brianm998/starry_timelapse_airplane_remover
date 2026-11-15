import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// `SplitRevealVideoView.videoAspectRatio(of:)`: the Initial screen sizes its video from the first video track's natural size with the
/// preferred transform applied, so a rotated clip reads as portrait.
final class VideoAspectRatioTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("VideoAspectRatioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeVideo(width: Int, height: Int, rotatedQuarterTurn: Bool) async throws -> URL {
        let url = dir.appendingPathComponent(rotatedQuarterTurn ? "rotated.mov" : "plain.mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        if rotatedQuarterTurn { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try XCTUnwrap(buffer)
        for i in 0..<2 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(i), timescale: 10)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
        return url
    }

    func testPlainVideoIsWiderThanTall() async throws {
        let url = try await makeVideo(width: 64, height: 32, rotatedQuarterTurn: false)
        let ratio = await SplitRevealVideoView.videoAspectRatio(of: url)
        let r = try XCTUnwrap(ratio)
        XCTAssertEqual(Double(r), 2.0, accuracy: 0.001)
    }

    func testRotatedVideoIsTallerThanWide() async throws {
        let url = try await makeVideo(width: 64, height: 32, rotatedQuarterTurn: true)
        let ratio = await SplitRevealVideoView.videoAspectRatio(of: url)
        let r = try XCTUnwrap(ratio)
        XCTAssertEqual(Double(r), 0.5, accuracy: 0.001)
    }

    func testNonVideoFileHasNoRatio() async throws {
        let url = dir.appendingPathComponent("not-a-video.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        let ratio = await SplitRevealVideoView.videoAspectRatio(of: url)
        XCTAssertNil(ratio)
        let missing = await SplitRevealVideoView.videoAspectRatio(of: dir.appendingPathComponent("absent.mov"))
        XCTAssertNil(missing)
    }
}
