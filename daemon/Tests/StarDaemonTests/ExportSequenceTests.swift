import XCTest
import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf

/// A video exported from a session opened on a folder of images, not on a video.
///
/// An export read `<folder>/image_%04d.tiff`, the names that `decodeVideo` gives the frames of a
/// video it takes apart, so a sequence, whose frames keep the names they had, could not be
/// exported at all.  Reading what a render left under whatever names it has is `FrameList`, and
/// this runs it against the real `stard` and the ffmpeg star ships, which is the only judge of
/// whether ffmpeg reads the list the way it was written.
///
/// Each frame is one flat colour, brighter than the one before in the order the sequence sorts
/// its frames into, so that the brightness of a frame in the video says which frame it was and
/// where it came out.
final class ExportSequenceTests: ExportEndToEndTestCase {

    // MARK: - fixtures

    private var sequenceDirectory: String { "\(scratch)/seq" }

    private func brightness(ofFrame index: Int) -> Int { 20 + index * 18 }

    /// What the sequence sorts a frame by: its name without the extension, spelt as a file URL
    /// spells it (so a space is `%20`).  The same as `ImageSequence` uses.
    private func sortKey(_ name: String) -> String {
        let url = NSURL(fileURLWithPath: name, isDirectory: false) as URL
        return url.deletingPathExtension().absoluteString.components(separatedBy: "/").last ?? name
    }

    /// A folder with a frame for each of `names`, which have to be in the order the sequence will
    /// sort them into.  They are written in a scrambled order, so that nothing depends on the order
    /// a folder happens to list its files in.
    private func makeSequence(_ names: [String]) throws {
        XCTAssertEqual(names, names.sorted { sortKey($0) < sortKey($1) },
                       "the fixture's names are not in the order the sequence sorts them into")
        try FileManager.default.createDirectory(atPath: sequenceDirectory, withIntermediateDirectories: true)

        let odd = names.indices.filter { $0 % 2 == 1 }
        let even = names.indices.filter { $0 % 2 == 0 }
        let scrambled = Array(odd.reversed()) + even
        for index in scrambled {
            let gray = brightness(ofFrame: index)
            let colour = String(format: "0x%02x%02x%02x", gray, gray, gray)
            // -update 1: the name is a name, not a pattern, which matters to the one with a % in it
            try run("ffmpeg", ["-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                               "-f", "lavfi", "-i", "color=c=\(colour):size=160x90:rate=1",
                               "-frames:v", "1", "-pix_fmt", "rgb24", "-update", "1",
                               "\(sequenceDirectory)/\(names[index])"])
        }
    }

    /// What a render leaves: each frame's image in the folder the config names, under the name the
    /// frame had.  The frames at the `skipping` places are not rendered.
    private func renderFrames(of info: Star_V1_SessionInfo, names: [String], skipping: Set<Int> = []) throws {
        let rendered = try config(of: info).outputSequenceDirname
        try FileManager.default.createDirectory(atPath: rendered, withIntermediateDirectories: true)
        for (index, name) in names.enumerated() where !skipping.contains(index) {
            try FileManager.default.copyItem(atPath: "\(sequenceDirectory)/\(name)", toPath: "\(rendered)/\(name)")
        }
    }

    private func export(_ daemon: DaemonProcess, _ info: Star_V1_SessionInfo, to path: String,
                        frameRate: Double = 24) async throws
    {
        let chosen = h264InMp4
        var chosenSettings = settings(codec: chosen.codec, encoder: chosen.encoder,
                                      pixelFormat: chosen.pixelFormat, muxer: chosen.muxer)
        chosenSettings.frameRate = frameRate
        try await export(daemon, session: info, to: path, with: chosenSettings)
    }

    /// The video has exactly the frames at the places `expected` names, in that order, at `rate`.
    private func assertVideo(_ path: String, showsFramesAt expected: [Int], rate: String = "24/1",
                             file: StaticString = #filePath, line: UInt = #line) throws
    {
        let facts = try videoFacts(of: path)
        XCTAssertEqual(facts.frames, expected.count, "the video has the wrong number of frames",
                       file: file, line: line)
        XCTAssertEqual(facts.frameRate, rate, file: file, line: line)

        let levels = try brightnessOfEachFrame(of: path)
        let wanted = expected.map { brightness(ofFrame: $0) }
        XCTAssertEqual(levels.count, wanted.count, "\(levels)", file: file, line: line)
        for (place, pair) in zip(levels, wanted).enumerated() {
            XCTAssertEqual(Double(pair.0), Double(pair.1), accuracy: 6,
                           "frame \(place) of the video is not the frame it should be; they came out as \(levels), wanted about \(wanted)",
                           file: file, line: line)
        }
    }

    // MARK: - names a camera gives

    /// The common case: a camera's counting names, which the export never could take.
    func testASequenceOfCameraNamedFramesExportsEveryFrameInOrder() async throws {
        let names = (123..<135).map { String(format: "IMG_%04d.tif", $0) }
        try makeSequence(names)
        let daemon = try launchDaemon()
        let info = try await openSequence(daemon, sequenceDirectory)
        XCTAssertEqual(Int(info.frameCount), names.count,
                       "the fixture has to have opened as a sequence of its frames, or the rest is vacuous")
        try renderFrames(of: info, names: names)

        let output = "\(scratch)/out.mp4"
        try await export(daemon, info, to: output)

        try assertVideo(output, showsFramesAt: Array(names.indices))
    }

    /// A number missing used to end the video there, without an error, so a sequence with a
    /// frame deleted out of the middle exported as the part before it.
    func testASequenceWithGapsInItsNumbersExportsEveryFrame() async throws {
        let numbers = [100, 101, 103, 107, 108, 120, 121, 150, 151, 152, 400, 9999]
        let names = numbers.map { String(format: "IMG_%04d.tif", $0) }
        try makeSequence(names)
        let daemon = try launchDaemon()
        let info = try await openSequence(daemon, sequenceDirectory)
        try renderFrames(of: info, names: names)

        let output = "\(scratch)/out.mp4"
        try await export(daemon, info, to: output)

        try assertVideo(output, showsFramesAt: Array(names.indices))
    }

    /// Spaces, quotes, a percent sign, a hash, brackets, accents, a snowman: every one of them is
    /// a character somebody's folder has had, and each is a way for a list or a pattern to
    /// mean a different file.
    func testFramesWithAwkwardNamesExportInOrder() async throws {
        let names = ["A 01 plain name.tif",
                     "B 02 it's.tif",
                     "C 03 100% done.tif",
                     "D 04 hash#tag.tif",
                     "E 05 semi;colon.tif",
                     "F 06 [brackets] {braces}.tif",
                     "G 07 quote\"d.tif",
                     "H 08 ünïcode ☃.tif",
                     "I 09 $HOME `ls`.tif",
                     "J 10 back\\slash.tif",
                     "K 11 two  spaces .tif"]
        try makeSequence(names)
        let daemon = try launchDaemon()
        let info = try await openSequence(daemon, sequenceDirectory)
        XCTAssertEqual(Int(info.frameCount), names.count)
        try renderFrames(of: info, names: names)

        let output = "\(scratch)/out.mp4"
        try await export(daemon, info, to: output)

        try assertVideo(output, showsFramesAt: Array(names.indices))
    }

    /// The rates the dialog offers are not all whole numbers, and the list has to make the same
    /// speed of video that a numbered pattern did.
    func testAnExportAtNtscRateKeepsTheRateAndEveryFrame() async throws {
        let names = (1...10).map { String(format: "frame_%02d.tif", $0) }
        try makeSequence(names)
        let daemon = try launchDaemon()
        let info = try await openSequence(daemon, sequenceDirectory)
        try renderFrames(of: info, names: names)

        let output = "\(scratch)/out.mp4"
        try await export(daemon, info, to: output, frameRate: 29.97)

        try assertVideo(output, showsFramesAt: Array(names.indices), rate: "2997/100")
    }

    // MARK: - frames that are not all there

    /// An export asked for before the render has finished is of the frames there are.  The Mac app
    /// does the same, and a numbered pattern stopped at the first missing one.
    func testAPartlyRenderedSequenceExportsTheFramesThatAreThere() async throws {
        let names = (1...10).map { String(format: "shot_%02d.tif", $0) }
        try makeSequence(names)
        let daemon = try launchDaemon()
        let info = try await openSequence(daemon, sequenceDirectory)
        try renderFrames(of: info, names: names, skipping: [3, 6])

        let output = "\(scratch)/out.mp4"
        try await export(daemon, info, to: output)

        try assertVideo(output, showsFramesAt: [0, 1, 2, 4, 5, 7, 8, 9])
    }

    func testASequenceWithNothingRenderedSaysSo() async throws {
        let names = (1...4).map { String(format: "shot_%02d.tif", $0) }
        try makeSequence(names)
        let daemon = try launchDaemon()
        let info = try await openSequence(daemon, sequenceDirectory)

        let output = "\(scratch)/out.mp4"
        let chosen = h264InMp4
        let result = try await export(daemon, session: info, to: output,
                                      with: settings(codec: chosen.codec, encoder: chosen.encoder,
                                                     pixelFormat: chosen.pixelFormat, muxer: chosen.muxer),
                                      expectingFailure: true)

        let message = try XCTUnwrap(result.failure?.message, "an export of nothing is not a success")
        XCTAssertTrue(message.contains("nothing to export"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
    }

    // MARK: - what the real pipeline leaves

    /// Everything above puts the rendered frames in place by hand.  This lets the daemon process a
    /// sequence itself, which is where the claim that a frame is rendered under the name it had comes
    /// from, and exports what it made, with no output path, as the desktop does.
    func testASequenceTheDaemonProcessedItselfExports() async throws {
        let count = 12
        try FileManager.default.createDirectory(atPath: sequenceDirectory, withIntermediateDirectories: true)
        try run("ffmpeg", ["-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                           "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24", "-frames:v", "\(count)",
                           "-pix_fmt", "rgb48le", "-start_number", "123", "\(sequenceDirectory)/IMG_%04d.tif"])
        let inputNames = try FileManager.default.contentsOfDirectory(atPath: sequenceDirectory).sorted()
        XCTAssertEqual(inputNames.first, "IMG_0123.tif")
        XCTAssertEqual(inputNames.count, count)

        let daemon = try launchDaemon()
        let info = try await openSequence(daemon, sequenceDirectory)
        let config = try config(of: info)

        var start = Star_V1_StartProcessingRequest()
        start.sessionID = info.sessionID
        let _: Star_V1_StartProcessingResponse = try await daemon.call(method: "Processing.Start", request: start)

        // wait for every frame's image to be there, and to have stopped growing
        var rendered: [String] = []
        var sizes: [String: Int] = [:]
        let deadline = Date().addingTimeInterval(90)
        var settled = false
        while Date() < deadline, !settled {
            rendered = ((try? FileManager.default.contentsOfDirectory(atPath: config.outputSequenceDirname)) ?? []).sorted()
            var now: [String: Int] = [:]
            for name in rendered {
                let attributes = try? FileManager.default.attributesOfItem(atPath: "\(config.outputSequenceDirname)/\(name)")
                now[name] = (attributes?[.size] as? Int) ?? 0
            }
            settled = rendered.count == count && now == sizes && !now.values.contains(0)
            sizes = now
            if !settled { try await Task.sleep(nanoseconds: 300_000_000) }
        }
        XCTAssertEqual(rendered, inputNames,
                       "a frame is rendered under the name it had, in the output sequence folder")

        let expected = "\(config.outputPath)/\(config.basename).mp4"
        let chosen = h264InMp4
        try await export(daemon, session: info, to: "",
                         with: settings(codec: chosen.codec, encoder: chosen.encoder,
                                        pixelFormat: chosen.pixelFormat, muxer: chosen.muxer))

        XCTAssertTrue(FileManager.default.fileExists(atPath: expected), "expected the video at \(expected)")
        let facts = try videoFacts(of: expected)
        XCTAssertEqual(facts.frames, count)
        XCTAssertEqual(facts.frameRate, "24/1")
    }
}
