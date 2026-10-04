import XCTest
@testable import stard

/// The list an export hands ffmpeg its frames in.
///
/// What ffmpeg makes of the script is checked against the real thing, with the awkward names
/// below among others, in `ExportSequenceTests`.  These are the parts that need no ffmpeg: what is
/// written, in what order, and which frames are listed at all.
final class FrameListTests: XCTestCase {

    // MARK: - the script

    func testTheScriptListsEveryFrameInTheOrderGiven() throws {
        let script = try FrameList.script(for: ["/out/b.tif", "/out/a.tif", "/out/c.tif"])

        XCTAssertEqual(script, "ffconcat version 1.0\nfile '/out/b.tif'\nfile '/out/a.tif'\nfile '/out/c.tif'\n",
                       "the order is the sequence's, not the names'")
    }

    func testAnEmptyListIsJustTheHeader() throws {
        XCTAssertEqual(try FrameList.script(for: []), "ffconcat version 1.0\n")
    }

    /// The one character that cannot be inside single quotes is written outside them, escaped.
    func testASingleQuoteInANameIsEscapedOutsideTheQuotes() throws {
        let script = try FrameList.script(for: ["/out/it's here.tif", "/out/'a'.tif"])

        XCTAssertTrue(script.contains("file '/out/it'\\''s here.tif'\n"), script)
        XCTAssertTrue(script.contains("file '/out/'\\''a'\\''.tif'\n"), script)
    }

    /// Inside quotes ffmpeg takes everything literally, so nothing else needs touching, and
    /// touching it would change which file is meant.
    func testEverythingElseInANameIsLeftAlone() throws {
        let names = ["a plain name.tif", "100% done.tif", "hash#tag.tif", "semi;colon.tif",
                     "[brackets] {braces}.tif", "quote\"d.png", "ünïcode ☃.tif", "$HOME `ls`.tif",
                     "back\\slash.tif", "  leading and trailing  .tif"]
        for name in names {
            let script = try FrameList.script(for: ["/out/\(name)"])
            XCTAssertTrue(script.contains("file '/out/\(name)'\n"), "\(name) was changed in\n\(script)")
        }
    }

    /// A Windows path is all backslashes, and every one is literal inside the quotes.
    func testBackslashesOfAWindowsPathSurvive() throws {
        let script = try FrameList.script(for: ["C:\\Users\\me\\night sky\\IMG_0001.tif"])

        XCTAssertTrue(script.contains("C:\\Users\\me\\night sky\\IMG_0001.tif'\n"), script)
    }

    /// ffmpeg reads a relative path in the list as relative to the list file, which is in the
    /// temporary folder and nowhere near the frames.
    func testARelativePathIsWrittenAbsolute() throws {
        let script = try FrameList.script(for: ["frames/IMG_0001.tif"])

        let expected = "file '\(FileManager.default.currentDirectoryPath)/frames/IMG_0001.tif'\n"
        XCTAssertTrue(script.contains(expected), script)
    }

    /// The script is a line to a frame, so a name with a line break in it cannot be written, and
    /// is refused rather than written as two lines that mean something else.
    func testANameWithALineBreakIsRefused() {
        for name in ["/out/two\nlines.tif", "/out/carriage\rreturn.tif"] {
            XCTAssertThrowsError(try FrameList.script(for: ["/out/fine.tif", name])) { error in
                XCTAssertTrue("\(error)".contains("line break"), "\(error)")
            }
        }
    }

    // MARK: - the options

    /// `-r` and the rest have to come before the `-i` they apply to.
    func testTheInputOptionsPrecedeTheListAndAllowAbsolutePaths() throws {
        let arguments = FrameList.inputArguments(listPath: "/tmp/frames.ffconcat", frameRate: "29.97")

        XCTAssertEqual(arguments, ["-r", "29.97", "-f", "concat", "-safe", "0", "-i", "/tmp/frames.ffconcat"])
    }

    // MARK: - which frames

    /// A render leaves each frame's finished image under the name the input had.
    func testARenderedFrameKeepsTheNameOfItsInput() {
        XCTAssertEqual(FrameList.renderedPath(of: "/in/seq/IMG_0412.tif", in: "/out/seq-star"),
                       "/out/seq-star/IMG_0412.tif")
        XCTAssertEqual(FrameList.renderedPath(of: "/in/night sky/it's 12.png", in: "/out/x"),
                       "/out/x/it's 12.png")
    }

    func testTheRenderedFramesAreInTheOrderOfTheInputs() {
        let inputs = ["/in/c.tif", "/in/a.tif", "/in/b.tif"]

        let frames = FrameList.renderedFrames(of: inputs, in: "/out", exists: { _ in true })

        XCTAssertEqual(frames, ["/out/c.tif", "/out/a.tif", "/out/b.tif"])
    }

    /// A frame that has not been rendered is left out, and the others are still in order.
    func testAFrameThatHasNotBeenRenderedIsLeftOut() {
        let inputs = ["/in/1.tif", "/in/2.tif", "/in/3.tif", "/in/4.tif"]
        let rendered: Set<String> = ["/out/1.tif", "/out/3.tif", "/out/4.tif"]

        let frames = FrameList.renderedFrames(of: inputs, in: "/out", exists: { rendered.contains($0) })

        XCTAssertEqual(frames, ["/out/1.tif", "/out/3.tif", "/out/4.tif"])
    }

    func testNothingRenderedIsNoFrames() {
        XCTAssertEqual(FrameList.renderedFrames(of: ["/in/1.tif", "/in/2.tif"], in: "/out",
                                                exists: { _ in false }),
                       [])
    }

    /// The check is against the disk, by default.
    func testTheDefaultCheckLooksAtTheDisk() throws {
        let folder = FileManager.default.temporaryDirectory
          .appendingPathComponent("FrameListTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data([1]).write(to: folder.appendingPathComponent("here.tif"))

        let frames = FrameList.renderedFrames(of: ["/in/here.tif", "/in/gone.tif"], in: folder.path)

        XCTAssertEqual(frames, ["\(folder.path)/here.tif"])
    }
}
