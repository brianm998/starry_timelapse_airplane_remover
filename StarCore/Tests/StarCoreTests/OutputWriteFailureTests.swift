import XCTest
@testable import StarCore
import StarCppBridge

/// Writing output used to be incapable of reporting failure. `mat_wrapper_write_to` returned
/// void, caught its own exception, logged it in C++, and returned; Swift never heard about it.
/// On a full disk star would work through every frame, write nothing, and exit 0 with an empty
/// output directory.
///
/// Two things had to change: the write has to return a result, and a failed *output* write has
/// to become a run error. This covers both ends — the real C++ write against real paths, and
/// the bookkeeping that turns a failure into a non-zero exit.
final class OutputWriteFailureTests: XCTestCase {

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("write-failure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        await OutputWriteFailures.shared.reset()

        // `record` posts to the shared relay, so without this the dedup window from an
        // earlier test in this class silently suppresses the warning a later one is
        // asserting on — which is what happened, and cost a confusing "expected 1, got 0".
        await StarWarnings.shared.reset()
        await StarWarnings.shared.setMinimumInterval(0)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        await OutputWriteFailures.shared.reset()
        await StarWarnings.shared.set(handler: nil)
        await StarWarnings.shared.reset()
        await StarWarnings.shared.setMinimumInterval(30)
    }

    /// A 16-bit three-channel image, the shape a real output frame has.
    private func image(width: Int = 16, height: Int = 16) throws -> PixelatedImage {
        let count = width * height * 3
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        for index in 0..<count { data[index] = 0x4000 }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                       componentsPerPixel: 3),
                             bytesPerRow: width * 3 * 2,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)
        guard let image = PixelatedImage(mat: mat) else { throw "could not build a test image" }
        return image
    }

    // MARK: - The write result

    /// The baseline: a write that works says so, and the file is really there.
    func testASuccessfulWriteReturnsTrue() throws {
        let path = directory.appendingPathComponent("ok.tif").path
        XCTAssertTrue(try image().writeTIFFEncoding(toFilename: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// The case that used to be silent. A directory that does not exist is the cheapest way to
    /// make the write fail for real, through the same C++ path a full disk takes.
    func testAWriteToAMissingDirectoryReturnsFalse() throws {
        let path = directory.appendingPathComponent("nope/deeper/x.tif").path
        XCTAssertFalse(try image().writeTIFFEncoding(toFilename: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// An extension no encoder handles. OpenCV returns false here rather than throwing, which
    /// is why the C++ checks `imwrite`'s return value as well as catching exceptions.
    func testAWriteWithAnUnusableExtensionReturnsFalse() throws {
        let path = directory.appendingPathComponent("x.wat").path
        XCTAssertFalse(try image().writeTIFFEncoding(toFilename: path))
    }

    /// A failed write must not leave the `.tmp` file behind. It would accumulate, and worse,
    /// a partial temp file next to a missing output looks like a successful write that was
    /// merely renamed badly.
    func testAFailedWriteLeavesNoTempFileBehind() throws {
        _ = try image().writeTIFFEncoding(toFilename:
                                            directory.appendingPathComponent("x.wat").path)
        let leftovers = try FileManager.default
          .contentsOfDirectory(atPath: directory.path)
          .filter { $0.contains(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "left behind: \(leftovers)")
    }

    /// Overwriting has to keep working: star rewrites the same output path when a frame is
    /// reprocessed, and the write goes via a temp file and a rename.
    func testWritingOverAnExistingFileSucceeds() throws {
        let path = directory.appendingPathComponent("twice.tif").path
        XCTAssertTrue(try image().writeTIFFEncoding(toFilename: path))
        XCTAssertTrue(try image(width: 32, height: 32).writeTIFFEncoding(toFilename: path))
    }

    // MARK: - Turning a failure into a run error

    func testAFreshRunHasNoFailures() async {
        let empty = await OutputWriteFailures.shared.isEmpty()
        XCTAssertTrue(empty)
    }

    /// The descriptions become entries in the cli's error list, which is what makes it exit
    /// non-zero, so they have to name the frame and the path.
    func testARecordedFailureNamesTheFrameAndThePath() async {
        await OutputWriteFailures.shared.record(path: "/out/frame7.tif", frameIndex: 7)

        let descriptions = await OutputWriteFailures.shared.descriptions()
        XCTAssertEqual(descriptions.count, 1)
        XCTAssertTrue(descriptions[0].contains("frame 7"))
        XCTAssertTrue(descriptions[0].contains("/out/frame7.tif"))
    }

    /// A full disk fails every remaining frame, so all of them are recorded — the count is
    /// how the user learns the scale of it.
    func testEveryFailureIsRecorded() async {
        for index in 0..<5 {
            await OutputWriteFailures.shared.record(path: "/out/\(index).tif", frameIndex: index)
        }
        let all = await OutputWriteFailures.shared.all()
        XCTAssertEqual(all.count, 5)
    }

    /// ...but only one warning is raised for them. A hundred identical critical alerts is not
    /// a hundred times more informative, and in the gui it would be a hundred modal dialogs.
    /// With the relay's dedup interval set to 0 in `setUp`, the single warning has to come
    /// from `OutputWriteFailures`' own `warned` flag rather than from rate limiting — which is
    /// the point, since rate limiting only suppresses for 30 seconds and a long run would keep
    /// re-raising it.
    func testOnlyOneWarningIsRaisedForManyFailures() async {
        let counter = Counter()
        await StarWarnings.shared.set { _ in counter.increment() }

        for index in 0..<20 {
            await OutputWriteFailures.shared.record(path: "/out/\(index).tif", frameIndex: index)
        }

        XCTAssertEqual(counter.value, 1)
    }

    /// The gui and daemon keep one process across several sequences. Carrying the last run's
    /// failures into the next would fail a run that wrote everything perfectly.
    func testResetClearsFailuresBetweenRuns() async {
        await OutputWriteFailures.shared.record(path: "/out/a.tif", frameIndex: 1)
        await OutputWriteFailures.shared.reset()

        let empty = await OutputWriteFailures.shared.isEmpty()
        XCTAssertTrue(empty)
    }

    /// And reset must re-arm the warning, or the second run's failures would be recorded
    /// silently.
    func testResetReArmsTheWarning() async {
        let counter = Counter()
        await StarWarnings.shared.set { _ in counter.increment() }

        await OutputWriteFailures.shared.record(path: "/out/a.tif", frameIndex: 1)
        await OutputWriteFailures.shared.reset()
        await OutputWriteFailures.shared.record(path: "/out/b.tif", frameIndex: 2)

        XCTAssertEqual(counter.value, 2)
    }
}

/// Counts handler invocations from a `@Sendable` closure that cannot capture the test case.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
