import XCTest
import StarCore
import StarCppBridge
import StarDaemonMessages
@testable import stard

/// `SessionManager` is the daemon's whole notion of open work: every handler beyond
/// `Daemon.Hello` looks its session up here by id, and a lost or cross-wired entry means a
/// request lands on the wrong sequence.  It is small enough that all of it is worth pinning.
final class SessionManagerTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SessionManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - building a real Session

    /// `Session` needs an `ImageSequence`, which needs a directory holding files with a supported
    /// extension, and an `ImageInfo`, which is read off the first of them.  So the fixture writes
    /// a genuine (tiny) tiff rather than faking either.
    private func makeSession(id: String) async throws -> Session {
        let dir = scratch.appendingPathComponent("seq-\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let width = 4, height = 4
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for i in 0..<(width * height) { data[i] = UInt8(i * 7 % 256) }
        let mat = MatWrapper(width: width, height: height,
                            cvType: MatWrapper.cvType(forBitsPerComponent: 8,
                                                      componentsPerPixel: 1),
                            bytesPerRow: width,
                            data: UnsafeMutableRawPointer(data),
                            takeOwnership: true)
        mat.write(to: dir.appendingPathComponent("frame0.tif").path)

        let sequence = try ImageSequence(dirname: dir.path,
                                         supportedImageFileTypes: [".tif", ".tiff"])
        let info = try await sequence.getImageInfo()
        let configManager = await MainActor.run { ConfigManager() }

        let sessionDir = scratch.appendingPathComponent(id).path
        return Session(sessionID: id,
                       scratchSessionDir: sessionDir,
                       configJsonPath: "\(sessionDir)/config.json",
                       configManager: configManager,
                       imageSequence: sequence,
                       imageInfo: info)
    }

    private func manager() -> SessionManager {
        SessionManager(scratchRoot: scratch.path)
    }

    // MARK: - the registry

    func testAFreshManagerHoldsNothing() async {
        let sessions = manager()
        let all = await sessions.all
        XCTAssertTrue(all.isEmpty)
    }

    func testAnAddedSessionCanBeFetchedByItsOwnId() async throws {
        let sessions = manager()
        let session = try await makeSession(id: "abc")
        await sessions.add(session: session)

        let fetched = await sessions.get(id: "abc")
        XCTAssertNotNil(fetched)
        let fetchedID = await fetched?.sessionID
        XCTAssertEqual(fetchedID, "abc")
    }

    /// The lookup miss is the one every handler guards on, so it has to be a clean nil rather
    /// than anything else.
    func testAnUnknownIdIsNil() async throws {
        let sessions = manager()
        await sessions.add(session: try await makeSession(id: "abc"))

        let missing = await sessions.get(id: "not-a-session")
        XCTAssertNil(missing)
        let empty = await sessions.get(id: "")
        XCTAssertNil(empty)
    }

    /// Ids are opaque strings, so nothing may normalise or trim them — a client that sends a
    /// near-miss must get a miss, not somebody else's sequence.
    func testLookupIsExact() async throws {
        let sessions = manager()
        await sessions.add(session: try await makeSession(id: "abc"))

        for nearMiss in ["ABC", "abc ", " abc", "ab", "abcd"] {
            let found = await sessions.get(id: nearMiss)
            XCTAssertNil(found, "\(nearMiss) should not have matched abc")
        }
    }

    func testSeveralSessionsAreKeptApart() async throws {
        let sessions = manager()
        for id in ["one", "two", "three"] {
            await sessions.add(session: try await makeSession(id: id))
        }

        let all = await sessions.all
        XCTAssertEqual(all.count, 3)

        for id in ["one", "two", "three"] {
            let fetched = await sessions.get(id: id)
            let fetchedID = await fetched?.sessionID
            XCTAssertEqual(fetchedID, id, "\(id) came back as \(fetchedID ?? "nil")")
        }
    }

    func testAllReportsEverySessionExactlyOnce() async throws {
        let sessions = manager()
        for id in ["a", "b", "c", "d"] {
            await sessions.add(session: try await makeSession(id: id))
        }

        let all = await sessions.all
        var ids: [String] = []
        for session in all { ids.append(await session.sessionID) }
        XCTAssertEqual(ids.sorted(), ["a", "b", "c", "d"])
    }

    /// The registry is keyed by id, so re-opening the same id replaces rather than accumulating.
    /// Two entries under one key would leave whichever `all` returned first serving requests.
    func testAddingTheSameIdTwiceReplacesRatherThanDuplicating() async throws {
        let sessions = manager()
        await sessions.add(session: try await makeSession(id: "same"))
        await sessions.add(session: try await makeSession(id: "same"))

        let all = await sessions.all
        XCTAssertEqual(all.count, 1, "the id should hold one session, not two")
    }

    func testRemovingASessionTakesItOutOfBothLookupAndAll() async throws {
        let sessions = manager()
        await sessions.add(session: try await makeSession(id: "keep"))
        await sessions.add(session: try await makeSession(id: "drop"))

        await sessions.remove(id: "drop")

        let dropped = await sessions.get(id: "drop")
        XCTAssertNil(dropped)
        let kept = await sessions.get(id: "keep")
        XCTAssertNotNil(kept, "removing one session must not disturb the other")
        let all = await sessions.all
        XCTAssertEqual(all.count, 1)
    }

    /// `Session.Close` can arrive twice, or for an id the daemon never had.  Neither may trap.
    func testRemovingAnUnknownIdIsHarmless() async throws {
        let sessions = manager()
        await sessions.add(session: try await makeSession(id: "abc"))

        await sessions.remove(id: "never-existed")
        await sessions.remove(id: "abc")
        await sessions.remove(id: "abc")        // twice

        let all = await sessions.all
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - generated ids

    /// A repeated id would silently evict a live session, so uniqueness is the whole requirement.
    func testGeneratedIdsAreUnique() async {
        let sessions = manager()
        var seen: Set<String> = []
        for _ in 0..<500 {
            let id = await sessions.newSessionID()
            XCTAssertFalse(seen.contains(id), "newSessionID handed out \(id) twice")
            seen.insert(id)
        }
        XCTAssertEqual(seen.count, 500)
    }

    func testGeneratedIdsAreNonEmptyAndUsableInAPath() async {
        let sessions = manager()
        for _ in 0..<20 {
            let id = await sessions.newSessionID()
            XCTAssertFalse(id.isEmpty)
            XCTAssertFalse(id.contains("/"), "an id with a slash would escape the scratch dir")
            XCTAssertFalse(id.contains(".."), "an id with .. would escape the scratch dir")
        }
    }

    // MARK: - scratch directories

    func testTheScratchRootIsWhatItWasGiven() async {
        let sessions = manager()
        let root = await sessions.scratchRoot
        XCTAssertEqual(root, scratch.path)
    }

    func testEachSessionGetsItsOwnScratchDirectoryUnderTheRoot() async {
        let sessions = manager()
        let a = await sessions.scratchDir(for: "aaa")
        let b = await sessions.scratchDir(for: "bbb")

        XCTAssertEqual(a, "\(scratch.path)/aaa")
        XCTAssertNotEqual(a, b, "two sessions must not share a scratch directory")
        XCTAssertTrue(a.hasPrefix(scratch.path), "the scratch dir must sit under the root")
        XCTAssertTrue(b.hasPrefix(scratch.path))
    }

    func testTheScratchDirIsStableForOneId() async {
        let sessions = manager()
        let first = await sessions.scratchDir(for: "abc")
        let second = await sessions.scratchDir(for: "abc")
        XCTAssertEqual(first, second)
    }
}
