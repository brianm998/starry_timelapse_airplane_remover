import XCTest
@testable import StarCore

/// `createHardLinkReplacingDestination` and `copyReplacingDestination` put one file's
/// contents at another file's path, replacing whatever was there.
///
/// On a static-tripod sequence every frame that has to build the merged horizon links its
/// result over *every other frame's* merged horizon, at original and preview size, so the
/// files being replaced are files that other frames are reading, linking from and copying
/// from at that moment.  The helpers used to remove the destination and then create the
/// link, which leaves a gap in which the path does not exist.  A frame that reached its
/// own path in that gap found nothing to link from, the link failed, the copy that
/// follows it failed the same way, and the frame's merge ended with
///
///     ERROR: frame 17 error during merge: ... "LRT_00097.jpg.jpg" couldn't be opened
///     because there is no such file     (NSFilePath = .../mergedHorizon-previews/...)
///
/// — on some runs of the daemon's integration test and not others, depending on how the
/// frames happened to interleave, and as a `cannot hard link ..., trying copy` warning on
/// the runs where the copy got there after the link was back.
///
/// (The doubled extension in that path is not the bug: a preview is named
/// `<base file name>.jpg`, and the base file name is the frame's file name with its own
/// extension, in the cli, the gui and the daemon alike.)
///
/// The replacement has to be one step, so that a path that exists keeps existing.
final class ReplacingDestinationTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReplacingDestinationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        try super.tearDownWithError()
    }

    private func path(_ name: String) -> String { dir.appendingPathComponent(name).path }

    @discardableResult
    private func write(_ name: String, _ contents: String) throws -> String {
        let path = path(name)
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func contents(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    }

    private func inode(_ path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? UInt64)
    }

    private func entries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    // MARK: - what they do

    func testALinkReplacesAnExistingDestination() throws {
        let source = try write("source.jpg", "new")
        let destination = try write("destination.jpg", "old")

        try createHardLinkReplacingDestination(from: source, to: destination)

        XCTAssertEqual(try contents(destination), "new")
        XCTAssertEqual(try inode(destination), try inode(source),
                       "a link shares the source's file; it is not a copy")
        XCTAssertEqual(try entries(), ["destination.jpg", "source.jpg"],
                       "nothing but the two names should be left in the directory")
    }

    func testALinkCreatesADestinationThatIsNotThereYet() throws {
        let source = try write("source.jpg", "new")

        try createHardLinkReplacingDestination(from: source, to: path("destination.jpg"))

        XCTAssertEqual(try contents(path("destination.jpg")), "new")
        XCTAssertEqual(try inode(path("destination.jpg")), try inode(source))
    }

    /// A resume links `.final` to a processed image it is already linked to.  `rename(2)`
    /// does nothing, successfully, when both names are the same file, so a link built at a
    /// temporary name first would be left there if it were not cleaned up afterwards.
    func testLinkingADestinationThatIsAlreadyTheSameFileLeavesNothingBehind() throws {
        let source = try write("source.jpg", "same")
        let destination = path("destination.jpg")
        try createHardLinkReplacingDestination(from: source, to: destination)

        try createHardLinkReplacingDestination(from: source, to: destination)

        XCTAssertEqual(try inode(destination), try inode(source))
        XCTAssertEqual(try entries(), ["destination.jpg", "source.jpg"])
    }

    func testACopyReplacesAnExistingDestination() throws {
        let source = try write("source.jpg", "new")
        let destination = try write("destination.jpg", "old")

        try copyReplacingDestination(from: source, to: destination)

        XCTAssertEqual(try contents(destination), "new")
        XCTAssertNotEqual(try inode(destination), try inode(source),
                          "a copy is a file of its own")
        XCTAssertEqual(try entries(), ["destination.jpg", "source.jpg"])
    }

    func testACopyCreatesADestinationThatIsNotThereYet() throws {
        let source = try write("source.jpg", "new")

        try copyReplacingDestination(from: source, to: path("destination.jpg"))

        XCTAssertEqual(try contents(path("destination.jpg")), "new")
    }

    // MARK: - what they must not do

    /// The destination used to be removed before the source was looked at, so asking for a
    /// link from a file that was not there cost the destination as well.
    func testALinkFromAMissingSourceLeavesTheDestinationAlone() throws {
        let destination = try write("destination.jpg", "precious")

        XCTAssertThrowsError(
          try createHardLinkReplacingDestination(from: path("missing.jpg"), to: destination))

        XCTAssertEqual(try contents(destination), "precious")
        XCTAssertEqual(try entries(), ["destination.jpg"],
                       "a failed link must not leave its temporary name behind")
    }

    func testACopyFromAMissingSourceLeavesTheDestinationAlone() throws {
        let destination = try write("destination.jpg", "precious")

        XCTAssertThrowsError(
          try copyReplacingDestination(from: path("missing.jpg"), to: destination))

        XCTAssertEqual(try contents(destination), "precious")
        XCTAssertEqual(try entries(), ["destination.jpg"])
    }

    // MARK: - the bug

    /// What the threads below tell each other, under a lock.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _failures: [String] = []
        private var _missing: Set<String> = []
        private var _finished = false

        func fail(_ message: String) { lock.lock(); _failures.append(message); lock.unlock() }
        func sawMissing(_ path: String) { lock.lock(); _missing.insert(path); lock.unlock() }
        func finish() { lock.lock(); _finished = true; lock.unlock() }

        var failures: [String] { lock.lock(); defer { lock.unlock() }; return _failures }
        var missing: Set<String> { lock.lock(); defer { lock.unlock() }; return _missing }
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
    }

    /// What one frame does when it has built a static sequence's merged horizon, with every
    /// frame doing it at once: write its own file, then put it at every other frame's path —
    /// a hard link, or a copy if the link fails, as `FrameHorizonProcessor` does.
    ///
    /// Every frame's file always exists from the moment it is first written, so there is
    /// no reason for any of this to fail, and no instant at which any of the files may be
    /// seen missing.  A thread that does nothing but look for them checks the second part.
    func testFramesLinkingOverEachOthersFilesNeverFailAndNeverMakeOneDisappear() throws {
        let frameCount = 12
        let rounds = 40
        let names = (0..<frameCount).map { "LRT_\(String(format: "%05d", 80 + $0)).jpg.jpg" }
        for (index, name) in names.enumerated() {
            try write(name, "merged horizon \(index)")
        }
        let paths = names.map { path($0) }
        let recorder = Recorder()

        let watcher = Thread {
            while !recorder.finished {
                for path in paths where !FileManager.default.fileExists(atPath: path) {
                    recorder.sawMissing(path)
                }
            }
        }
        watcher.start()

        DispatchQueue.concurrentPerform(iterations: frameCount) { frame in
            for _ in 0..<rounds {
                for other in 0..<frameCount where other != frame {
                    do {
                        try createHardLinkReplacingDestination(from: paths[frame],
                                                               to: paths[other])
                    } catch {
                        do {
                            try copyReplacingDestination(from: paths[frame],
                                                         to: paths[other])
                        } catch {
                            recorder.fail("\(names[frame]) -> \(names[other]): \(error)")
                        }
                    }
                }
            }
        }

        recorder.finish()
        while !watcher.isFinished { usleep(1000) }

        XCTAssertEqual(recorder.failures, [], "a frame could not put its file over another's")
        XCTAssertEqual(recorder.missing, [], "a file that had been written was seen missing")
        // all the temporary names are gone too
        XCTAssertEqual(try entries(), names.sorted())
    }
}
