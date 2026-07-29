import XCTest
@testable import StarCore

/// `ImageAccessor.linkFinal` hard-links an already-processed image to `.final`, falling
/// back to a copy when the link fails.  Both fail with ENOENT when there is nothing to
/// link from, and the throw used to escape `FrameAirplaneRemover.finishAuto` — which
/// asked for `[.original, .preview]` unconditionally — out into `MergeOp`, once per frame:
///
///     ERROR: frame 4 error during merge: ... "LRT_00084.jpg.jpg" couldn't be opened
///     because there is no such file
///
/// Previews are optional output.  A cli run leaves `writeFramePreviewFiles` and
/// `writeFrameProcessedPreviewFiles` false, so nothing had ever written
/// `auto-processed-previews/`, and a resume reported a failure for output it was told not
/// to produce.  The `.original` link — the one that matters — had already succeeded and
/// the run exited 0, so this was a working resume that looked broken.
///
/// The gui reaches the same call with previews wanted, so a preview that *is* on disk
/// still has to be linked, and a missing original still has to be an error.
final class LinkFinalTests: XCTestCase {

    private var tempDir: URL!

    private let baseFileName = "LRT_00084.jpg"
    private let frameIndex = 4

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LinkFinalTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        try super.tearDownWithError()
    }

    /// An accessor over an empty sequence dir in a scratch location.  `writePreviews`
    /// picks between the two configurations that reach `linkFinal`: false is the cli,
    /// true is the gui.
    private func accessor(writePreviews: Bool) throws -> ImageAccessor {
        let sequenceDir = tempDir.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: sequenceDir,
                                                withIntermediateDirectories: true)
        let config = Config(
          outputPath: tempDir.path,
          imageSequenceName: "seq",
          imageSequencePath: tempDir.path,
          writeOutlierGroupFiles: false,
          writeFramePreviewFiles: writePreviews,
          writeFrameProcessedPreviewFiles: writePreviews,
          writeFrameThumbnailFiles: writePreviews
        )
        // ImageAccessor.init makes every directory the config asks for, which is the
        // point: with previews off, the preview dirs are not among them.
        return ImageAccessor(
          config: config,
          imageSequence: try ImageSequence(dirname: sequenceDir.path,
                                           supportedImageFileTypes: [".jpg"]),
          frameIndexToBaseNameMap: [frameIndex: baseFileName]
        )
    }

    /// Puts a file where `accessor` expects to find one, creating the directory if the
    /// config did not.
    private func write(_ accessor: ImageAccessor,
                       type: FrameViewMode,
                       size: ImageDisplaySize,
                       contents: String = "image") throws -> String {
        let path = try XCTUnwrap(accessor.nameForImage(frameIndex: frameIndex,
                                                       ofType: type,
                                                       atSize: size))
        try ensureParentDirectoriesExist(for: path)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func finalPath(_ accessor: ImageAccessor,
                           size: ImageDisplaySize) throws -> String {
        try XCTUnwrap(accessor.nameForImage(frameIndex: frameIndex,
                                            ofType: .final,
                                            atSize: size))
    }

    private func inode(_ path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? UInt64)
    }

    // MARK: - the bug

    /// The reported failure: a resumed cli frame whose auto-processed original is on disk
    /// and whose preview never was.  The original has to be linked and the preview has to
    /// be passed over in silence.
    func testAMissingPreviewIsSkippedRatherThanFailingTheFrame() async throws {
        let accessor = try accessor(writePreviews: false)
        let source = try write(accessor, type: .autoProcessed, size: .original)

        // exactly what finishAuto's already-done shortcut asks for
        try await accessor.linkFinals(frameIndex: frameIndex,
                                      as: .autoProcessed,
                                      atSizes: [.original, .preview])

        let linked = try finalPath(accessor, size: .original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked),
                      "the original final is the output of the run; it must be linked")
        XCTAssertEqual(try inode(linked), try inode(source),
                       "the final should be a hard link to the processed image, not a copy")
        XCTAssertFalse(
          FileManager.default.fileExists(atPath: try finalPath(accessor, size: .preview)),
          "nothing wrote a preview to link from, so none should have appeared")
    }

    /// `.preview` is the only optional size this can reach: `Config.dirForImage` has no
    /// `.final` directory for `.thumbnail`, so a thumbnail link fails on the missing name
    /// before it ever gets as far as a missing file.  No caller asks for one — every
    /// `linkFinals` call site passes `FrameAirplaneRemover.outputSizes`, which is
    /// `[.original]` or `[.original, .preview]` — but a caller that did would want to
    /// know, so this pins the boundary rather than leaving it to be discovered.
    func testAThumbnailHasNoFinalToLinkTo() async throws {
        let accessor = try accessor(writePreviews: true)
        XCTAssertNil(accessor.nameForImage(frameIndex: frameIndex,
                                           ofType: .final,
                                           atSize: .thumbnail))
    }

    // MARK: - what the skip must not break

    /// The gui writes processed previews and wants them linked, so the skip has to be
    /// about the file being absent and nothing else.
    func testAPreviewThatExistsIsStillLinked() async throws {
        let accessor = try accessor(writePreviews: true)
        let original = try write(accessor, type: .autoProcessed, size: .original)
        let preview = try write(accessor, type: .autoProcessed, size: .preview,
                                contents: "preview")

        try await accessor.linkFinals(frameIndex: frameIndex,
                                      as: .autoProcessed,
                                      atSizes: [.original, .preview])

        XCTAssertEqual(try inode(try finalPath(accessor, size: .original)),
                       try inode(original))
        XCTAssertEqual(try inode(try finalPath(accessor, size: .preview)),
                       try inode(preview),
                       "the preview final should still be a hard link to the "
                       + "processed preview")
    }

    /// A missing original is a real failure — the run has no output for the frame — and
    /// has to keep throwing.  Skipping it would turn a broken merge into a silent one.
    func testAMissingOriginalStillThrows() async throws {
        let accessor = try accessor(writePreviews: false)

        do {
            try await accessor.linkFinals(frameIndex: frameIndex,
                                          as: .autoProcessed,
                                          atSizes: [.original, .preview])
            XCTFail("linking a final with no processed image to link from should throw")
        } catch {
            // expected
        }
    }

    /// An existing `.final` from an earlier run is replaced, not left stale or treated as
    /// an error — this is the resume case, where the link is being redone.
    func testAnExistingFinalIsReplaced() async throws {
        let accessor = try accessor(writePreviews: false)
        let source = try write(accessor, type: .autoProcessed, size: .original,
                               contents: "new")
        let stale = try finalPath(accessor, size: .original)
        try ensureParentDirectoriesExist(for: stale)
        try Data("stale".utf8).write(to: URL(fileURLWithPath: stale))

        try await accessor.linkFinals(frameIndex: frameIndex,
                                      as: .autoProcessed,
                                      atSizes: [.original, .preview])

        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: stale),
                                  encoding: .utf8), "new")
        XCTAssertEqual(try inode(stale), try inode(source))
    }
}
