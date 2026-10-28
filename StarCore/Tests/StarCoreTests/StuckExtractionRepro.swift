import XCTest
@testable import StarCore

/// Opt-in repro on a big real video: STAR_REPRO_VIDEO=<path> (symlinked into a scratch folder; frames go next to the symlink).
final class StuckExtractionRepro: XCTestCase {
    func testRepro() async throws {
        guard let video = ProcessInfo.processInfo.environment["STAR_REPRO_VIDEO"], !video.isEmpty else { throw XCTSkip("opt-in") }
        let tools = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("external_binaries/bin")
        setenv(ToolPaths.directoryOverrideVariable, tools.path, 1)
        let dir = URL(fileURLWithPath: "/private/tmp/claude-5004/repro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("clip.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: video))
        let source = try await VideoFrameSource.make(videoPath: link.path, settings: .default)
        defer { source.stop() }
        func ps() -> String { ((try? shellOut(to: "/bin/ps", arguments: ["-axo", "pid,state,rss,command"])) ?? "").split(separator: "\n").filter { $0.contains("ffmpeg") && $0.contains(dir.path) }.map { String($0.prefix(60)) + "…" + String($0.suffix(110)) }.joined(separator: "\n   ") }
        func log(_ s: String) { print("REPRO \(Date().timeIntervalSince1970.rounded()) extracted=\(source.progress.extracted) head=\(String(describing: source.sweepHead)) \(s)\n   \(ps())") }
        log("start")
        try await Task.sleep(nanoseconds: 4_000_000_000)
        log("after 4s")
        source.prioritize([0], reason: .userViewing)
        source.prioritize(Array(0...24), reason: .userNearby)
        for i in 0..<2 { try await Task.sleep(nanoseconds: 5_000_000_000); log("t+\((i+1)*5)") }
        source.prioritize([300], reason: .userViewing)
        source.prioritize(Array(292...324), reason: .userNearby)
        for i in 0..<8 { try await Task.sleep(nanoseconds: 5_000_000_000); log("late t+\((i+1)*5)") }
        source.stop()
        try await Task.sleep(nanoseconds: 4_000_000_000)
        log("after stop")
        XCTAssertEqual(ps(), "", "ffmpeg survived stop()")
    }
}
