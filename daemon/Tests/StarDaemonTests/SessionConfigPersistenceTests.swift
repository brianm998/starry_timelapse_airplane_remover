import XCTest
import Foundation
import StarCore
import StarDaemonMessages
import SwiftProtobuf

/// What a session's config.json holds, and where it is.
///
/// Both halves are what makes a session resumable, and both used to have a hole in them.
/// The record of a hand-painted horizon selection the user did not finish has to survive the
/// session ending — losing it means a re-opened sequence goes straight to processing, running
/// the frames the user never reached with the automatic horizon detection they had just
/// declined.  And a client has to be told *which* file to resume from, because a session
/// opened from a config keeps writing to the caller's own, not to one in the scratch dir.
///
/// Driven through the real daemon rather than through `Mapping` alone, because what can
/// actually break is neither end of the mapping but the middle: `Sequence.UpdateConfig` has
/// to reach a file on disk, and `Session.OpenConfig` has to read it back.
final class SessionConfigPersistenceTests: XCTestCase {

    func testAnUnfinishedSelectionSurvivesUpdateConfigAndOpenConfig() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let sequenceDir = try makeSequence(in: scratch, frames: 3)

        let daemon = try launchDaemon(scratchDir: scratch)
        defer { daemon.terminate() }
        try await hello(daemon)

        var openReq = Star_V1_OpenSequenceRequest()
        openReq.sequenceDir = sequenceDir
        let info: Star_V1_SessionInfo =
          try await daemon.call(method: "Session.OpenSequence", request: openReq)
        XCTAssertEqual(info.frameCount, 3,
                       "the fixture has to have really opened, or the rest of this is vacuous")
        XCTAssertTrue(info.config.startupHorizonFrameIndices.isEmpty,
                      "a sequence just opened has nothing unfinished")

        // What the painter records after the user finishes the first of three horizons.
        var cfg = info.config
        cfg.startupHorizonFrameIndices = [0, 1, 2]
        cfg.startupHorizonFramePosition = 1
        var update = Star_V1_UpdateConfigRequest()
        update.sessionID = info.sessionID
        update.config = cfg
        let updated: Star_V1_Config =
          try await daemon.call(method: "Sequence.UpdateConfig", request: update)
        XCTAssertEqual(updated.startupHorizonFrameIndices, [0, 1, 2])
        XCTAssertEqual(updated.startupHorizonFramePosition, 1)

        // On disk, which is the part a killed session depends on: nothing gets to run any
        // cleanup, so whatever is in config.json at that moment is the whole record.
        // Decoded rather than grepped for the key, which the open-time write already put
        // there at its default and would answer for regardless of whether the update landed.
        let configPath = "\(info.scratchSessionDir)/config.json"
        let onDisk = try JSONDecoder()
          .decode(Config.self, from: try Data(contentsOf: URL(fileURLWithPath: configPath)))
        XCTAssertEqual(onDisk.startupHorizonFrameIndices, [0, 1, 2],
                       "the update has to be persisted, not just held in the session")
        XCTAssertEqual(onDisk.startupHorizonFramePosition, 1)

        // And back out the way a resume reads it.
        var reopen = Star_V1_OpenConfigRequest()
        reopen.configJsonPath = configPath
        let reopened: Star_V1_SessionInfo =
          try await daemon.call(method: "Session.OpenConfig", request: reopen)
        XCTAssertEqual(reopened.config.startupHorizonFrameIndices, [0, 1, 2])
        XCTAssertEqual(reopened.config.startupHorizonFramePosition, 1,
                       "without this the client cannot tell the selection was unfinished, "
                       + "and processes the frames it never painted")
    }

    /// Finishing or cancelling clears it, and the cleared state has to persist too — a record
    /// that could not be erased would re-open the painter forever.
    func testAFinishedSelectionClearsAndStaysCleared() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let sequenceDir = try makeSequence(in: scratch, frames: 3)

        let daemon = try launchDaemon(scratchDir: scratch)
        defer { daemon.terminate() }
        try await hello(daemon)

        var openReq = Star_V1_OpenSequenceRequest()
        openReq.sequenceDir = sequenceDir
        let info: Star_V1_SessionInfo =
          try await daemon.call(method: "Session.OpenSequence", request: openReq)
        XCTAssertEqual(info.frameCount, 3)

        var cfg = info.config
        cfg.startupHorizonFrameIndices = [0, 1, 2]
        cfg.startupHorizonFramePosition = 1
        var update = Star_V1_UpdateConfigRequest()
        update.sessionID = info.sessionID
        update.config = cfg
        _ = try await daemon.call(method: "Sequence.UpdateConfig", request: update)
          as Star_V1_Config

        // The client reports "finished" as an empty list with the position still present —
        // presence is what the daemon gates the pair on.
        cfg.startupHorizonFrameIndices = []
        cfg.startupHorizonFramePosition = 0
        update.config = cfg
        let cleared: Star_V1_Config =
          try await daemon.call(method: "Sequence.UpdateConfig", request: update)
        XCTAssertTrue(cleared.startupHorizonFrameIndices.isEmpty)

        var reopen = Star_V1_OpenConfigRequest()
        reopen.configJsonPath = "\(info.scratchSessionDir)/config.json"
        let reopened: Star_V1_SessionInfo =
          try await daemon.call(method: "Session.OpenConfig", request: reopen)
        XCTAssertTrue(reopened.config.startupHorizonFrameIndices.isEmpty,
                      "a finished selection must not come back on the next open")
    }

    // MARK: - where the session's config.json is

    /// A session opened from a sequence keeps its config in the scratch dir, and says so.
    func testASequenceSessionReportsItsScratchConfig() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let sequenceDir = try makeSequence(in: scratch, frames: 3)

        let daemon = try launchDaemon(scratchDir: scratch)
        defer { daemon.terminate() }
        try await hello(daemon)

        var openReq = Star_V1_OpenSequenceRequest()
        openReq.sequenceDir = sequenceDir
        let info: Star_V1_SessionInfo =
          try await daemon.call(method: "Session.OpenSequence", request: openReq)

        XCTAssertEqual(info.configJsonPath, "\(info.scratchSessionDir)/config.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: info.configJsonPath),
                      "the path a client would resume from has to exist by the time it is "
                      + "handed one")
    }

    /// A session opened from a config keeps writing to the caller's own file, which is *not*
    /// in the scratch dir.  Building the scratch path instead — which is what clients did
    /// before this field existed — names a file nothing ever writes, so crash recovery gave
    /// up on a session that was perfectly resumable.
    func testAConfigSessionReportsTheCallersOwnFile() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let sequenceDir = try makeSequence(in: scratch, frames: 3)

        let daemon = try launchDaemon(scratchDir: scratch)
        defer { daemon.terminate() }
        try await hello(daemon)

        var openReq = Star_V1_OpenSequenceRequest()
        openReq.sequenceDir = sequenceDir
        let first: Star_V1_SessionInfo =
          try await daemon.call(method: "Session.OpenSequence", request: openReq)

        // Re-open that config from somewhere the scratch dir does not reach.
        let elsewhere = "\(scratch)/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        let callersConfig = "\(elsewhere)/config.json"
        try FileManager.default.copyItem(atPath: first.configJsonPath, toPath: callersConfig)

        var reopen = Star_V1_OpenConfigRequest()
        reopen.configJsonPath = callersConfig
        let info: Star_V1_SessionInfo =
          try await daemon.call(method: "Session.OpenConfig", request: reopen)

        XCTAssertEqual(info.configJsonPath, callersConfig)
        XCTAssertNotEqual(info.configJsonPath, "\(info.scratchSessionDir)/config.json")
        XCTAssertFalse(
          FileManager.default.fileExists(atPath: "\(info.scratchSessionDir)/config.json"),
          "nothing writes a config into a resumed session's scratch dir, which is exactly "
          + "why the client cannot build the path itself")
    }

    /// And what it reports is the file the daemon actually saves to, not just a name.
    func testAConfigSessionSavesToTheFileItReported() async throws {
        let scratch = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let sequenceDir = try makeSequence(in: scratch, frames: 3)

        let daemon = try launchDaemon(scratchDir: scratch)
        defer { daemon.terminate() }
        try await hello(daemon)

        var openReq = Star_V1_OpenSequenceRequest()
        openReq.sequenceDir = sequenceDir
        let first: Star_V1_SessionInfo =
          try await daemon.call(method: "Session.OpenSequence", request: openReq)

        let elsewhere = "\(scratch)/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        let callersConfig = "\(elsewhere)/config.json"
        try FileManager.default.copyItem(atPath: first.configJsonPath, toPath: callersConfig)

        var reopen = Star_V1_OpenConfigRequest()
        reopen.configJsonPath = callersConfig
        let info: Star_V1_SessionInfo =
          try await daemon.call(method: "Session.OpenConfig", request: reopen)

        var cfg = info.config
        cfg.startupHorizonFrameIndices = [0, 2]
        cfg.startupHorizonFramePosition = 1
        var update = Star_V1_UpdateConfigRequest()
        update.sessionID = info.sessionID
        update.config = cfg
        _ = try await daemon.call(method: "Sequence.UpdateConfig", request: update)
          as Star_V1_Config

        let onDisk = try JSONDecoder().decode(
          Config.self, from: try Data(contentsOf: URL(fileURLWithPath: info.configJsonPath)))
        XCTAssertEqual(onDisk.startupHorizonFrameIndices, [0, 2],
                       "configJsonPath has to be where the session's writes land, or "
                       + "resuming from it loses everything done since it was opened")
    }

    // MARK: - harness

    private static var stardPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // StarDaemonTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // daemon/
            .appendingPathComponent(".build/debug/stard").path
    }

    private func launchDaemon(scratchDir: String) throws -> DaemonProcess {
        guard FileManager.default.fileExists(atPath: Self.stardPath) else {
            throw XCTSkip("stard binary not found at \(Self.stardPath) — run `swift build` first")
        }
        return try DaemonProcess(binaryPath: Self.stardPath, scratchDir: scratchDir)
    }

    private func hello(_ daemon: DaemonProcess) async throws {
        var req = Star_V1_HelloRequest()
        req.clientVersion = "startup-horizon-resume-tests"
        let _: Star_V1_HelloResponse = try await daemon.call(method: "Daemon.Hello", request: req)
    }

    private func makeScratchDir() throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("stard-resume-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        return tmp
    }

    /// A real, tiny image sequence.  Written rather than checked in so the test carries its
    /// own input: `Session.OpenSequence` reads every frame's header, so a stub will not do.
    ///
    /// Binary PPM (`P6`), which is in `Config.supportedImageFileTypes` and is the one format
    /// that needs no encoder — a text header and big-endian samples.  Writing a TIFF here
    /// would mean giving the test target a dependency on the OpenCV bridge for a fixture.
    /// 16 bits per component, which is the shape a real frame has.
    private func makeSequence(in root: String, frames: Int) throws -> String {
        let dir = "\(root)/seq"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let width = 32, height = 24
        for index in 0..<frames {
            var bytes = Data("P6\n\(width) \(height)\n65535\n".utf8)
            let sample = UInt16(1000 + index * 100)
            for _ in 0..<(width * height * 3) {
                bytes.append(UInt8(sample >> 8))
                bytes.append(UInt8(sample & 0xFF))
            }
            let name = "frame_" + String(format: "%03d", index) + ".ppm"
            try bytes.write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        }
        return dir
    }
}
