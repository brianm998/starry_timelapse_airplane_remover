import XCTest
import Foundation
import StarCpp
@testable import StarCppBridge

/// Replays single frames through the cloud-aware merge from a finished run's saved state,
/// instead of through the pipeline: seconds per frame, on the exact input that produced
/// the artefact being chased.  Skipped unless `STAR_CLOUD_REPLAY=1`, because it needs a
/// real sequence on disk.
///
/// For each requested frame it takes the star homographies a finished run stored in
/// `homography.db`, merges the original frames with them the way
/// `FrameAlignmentProcessor` does, and writes full-frame 16-bit TIFFs to the output
/// directory, one per mode: `LRT_<n>-off.tif` (the plain star aligned merge, which must
/// be byte-identical to a finished run's `aligned/` frame — if it is not, this harness
/// is not reproducing production and nothing else it says can be trusted) and
/// `LRT_<n>-on.tif`, with `cloud-debug/` beside them holding the stage's own blend weight
/// and velocity grid.
///
/// Configuration is by environment, all paths absolute:
///
///   STAR_CLOUD_REPLAY=1
///   STAR_CLOUD_REPLAY_FRAMES   comma separated 1-based file indices, e.g. "28,30,700"
///   STAR_CLOUD_REPLAY_DB       a COPY of homography.db.  Never the original: the reader
///                              StarCore uses opens read-write and runs WAL statements,
///                              which would write into a run's temp dir.  Make the copy
///                              with `sqlite3 <src> ".backup <dst>"`, which is consistent
///                              even while the source is being written to.
///   STAR_CLOUD_REPLAY_SOURCE   the directory of original frames, LRT_%05d.tif
///   STAR_CLOUD_REPLAY_PATTERN  optional printf pattern for the frame (and mask) file names,
///                              default "LRT_%05d.tif"; e.g. "image_%04d.tiff"
///   STAR_CLOUD_REPLAY_MASKS    optional: the directory of sky masks, same names (a run's
///                              `mergedHorizon/`, which is what the merge is given for a
///                              static sequence).  Without it the whole frame is sky.
///   STAR_CLOUD_REPLAY_OUT      where to write
///   STAR_CLOUD_REPLAY_WRITE    "0" to skip writing the TIFFs and keep only the stage's own
///                              debug output (outcome and timing per frame)
///   STAR_CLOUD_REPLAY_MODES    optional, default "off,on".  Also "on-full" (the stage
///                              without its region restriction), "on-stream" (with the
///                              streaming merge paths forced), and "off-gpu" / "on-gpu"
///                              (the star merge made by the Metal kernel, which is a
///                              different merge from the CPU one at near ties).
///
/// Build in release for any timing or any real number of frames: a debug build runs the
/// C++ unoptimised, and a 12MP frame takes minutes.  `swift test -c release
/// -Xswiftc -enable-testing --filter CloudAwareMergeReplayTests` from `StarCpp/`.
/// Strong, thread safe cache of decoded frames, for the replay's loader.
private final class DecodeCache: @unchecked Sendable {
    private var frames: [String: MatWrapper] = [:]
    private let lock = NSLock()
    func load(_ name: String) -> MatWrapper? {
        lock.lock()
        if let hit = frames[name] { lock.unlock(); return hit }
        lock.unlock()
        guard let mat = MatWrapper.load(fromFilename: name) else { return nil }
        lock.lock(); frames[name] = mat; lock.unlock()
        return mat
    }
    func drop() { lock.lock(); frames.removeAll(); lock.unlock() }
    /// Drops every decode but `names`, for a run over consecutive frames.
    func keep(only names: Set<String>) {
        lock.lock(); frames = frames.filter { names.contains($0.key) }; lock.unlock()
    }
}

final class CloudAwareMergeReplayTests: XCTestCase {

    private struct StoredNeighbour: Decodable {
        let frameIndex: Int
        let homography: [Double]?      // nil where the alignment failed
    }
    private struct StoredRow: Decodable {
        let neighborHomography: [StoredNeighbour]
    }

    private func env(_ key: String) -> String? {
        let v = ProcessInfo.processInfo.environment[key]
        return (v?.isEmpty ?? true) ? nil : v
    }

    /// CPU seconds this process has used so far, user plus system.
    private func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }

    /// One frame's stored star row, read with the sqlite3 command line tool so this file
    /// needs no sqlite binding of its own.
    private func storedRow(db: String, frameIndex: Int) throws -> StoredRow {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db, "select data from homographies where frame_index=\(frameIndex) and type='star'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let trimmed = data.last == 0x0A ? data.dropLast() : data[...]
        return try JSONDecoder().decode(StoredRow.self, from: Data(trimmed))
    }

    func testReplay() throws {
        try XCTSkipUnless(env("STAR_CLOUD_REPLAY") == "1", "set STAR_CLOUD_REPLAY=1 to replay real frames")
        let frames = try XCTUnwrap(env("STAR_CLOUD_REPLAY_FRAMES"), "STAR_CLOUD_REPLAY_FRAMES")
            .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let db = try XCTUnwrap(env("STAR_CLOUD_REPLAY_DB"), "STAR_CLOUD_REPLAY_DB")
        let source = try XCTUnwrap(env("STAR_CLOUD_REPLAY_SOURCE"), "STAR_CLOUD_REPLAY_SOURCE")
        let out = try XCTUnwrap(env("STAR_CLOUD_REPLAY_OUT"), "STAR_CLOUD_REPLAY_OUT")
        let masks = env("STAR_CLOUD_REPLAY_MASKS")
        let modes = (env("STAR_CLOUD_REPLAY_MODES") ?? "off,on").split(separator: ",").map(String.init)
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

        // Without this every filename source loads as nothing and the merge silently runs
        // on the base frame alone.  What it loads is kept for the rest of the run, as a
        // pipeline keeps the decodes it has pinned for a merge op: a merge reads each
        // neighbour more than once, and timing the second decode of a 12MP TIFF instead of
        // the merge would be measuring the wrong thing.
        let decoded = DecodeCache()
        ImageCache.setLoader { decoded.load($0) }
        // The "-gpu" modes need the Metal handlers, which StarCore registers at startup.
        if modes.contains(where: { $0.hasSuffix("-gpu") }) {
            XCTAssertTrue(GPUOps.registerIfAvailable(), "no GPU to run the -gpu modes on")
        }

        let pattern = env("STAR_CLOUD_REPLAY_PATTERN") ?? "LRT_%05d.tif"
        func name(_ fileIndex: Int) -> String { String(format: pattern, fileIndex) }

        for fileIndex in frames {
            // File names are 1-based; the stored rows are keyed by the 0-based frame index.
            let baseIndex = fileIndex - 1
            let row = try storedRow(db: db, frameIndex: baseIndex)
            decoded.keep(only: Set([fileIndex] + row.neighborHomography.map { $0.frameIndex + 1 })
                                .reduce(into: Set<String>()) { $0.insert("\(source)/\(name($1))") })

            var infos: [AlignmentNeighborInfo] = []
            var homography: [Int: MatWrapper] = [:]
            for n in row.neighborHomography {
                guard let values = n.homography else { continue }
                infos.append(AlignmentNeighborInfo(filename: "\(source)/\(name(n.frameIndex + 1))",
                                                   maskFilename: nil, keypoints: nil,
                                                   frameIndex: Int32(n.frameIndex)))
                homography[n.frameIndex - baseIndex] = MatWrapper(homographyValues: values)
            }
            let base = try XCTUnwrap(MatWrapper.load(fromFilename: "\(source)/\(name(fileIndex))"),
                                     "cannot load frame \(fileIndex)")
            let sky = masks.flatMap { MatWrapper.load(fromFilename: "\($0)/\(name(fileIndex))") }
            if masks != nil { XCTAssertNotNil(sky, "no mask for frame \(fileIndex)") }

            // decode everything this frame needs before any mode is timed
            _ = decoded.load("\(source)/\(name(fileIndex))")
            for info in infos { _ = decoded.load(info.filename) }

            for mode in modes {
                let cloudAware = mode.hasPrefix("on")
                let stream = mode == "on-stream"
                let useGPU = mode.hasSuffix("-gpu")
                ia_debug_set_cloud_region_restriction(mode != "on-full")
                defer { ia_debug_set_cloud_region_restriction(true) }

                let wall = Date()
                let cpu = cpuSeconds()
                let result = try XCTUnwrap(ImageAligner.alignAndMedianMerge(
                  baseImage: base, baseFrameIndex: Int32(baseIndex),
                  neighbors: infos, homography: homography,
                  outlierThreshold: 1.2, includeAll: false,
                  scratchDir: "\(out)/scratch",
                  streamingThresholdBytes: stream ? 1 : 0,
                  loadConcurrency: 1,
                  useGPU: useGPU,
                  cloudAware: cloudAware,
                  skyMask: sky,
                  cloudDebugDir: cloudAware ? "\(out)/cloud-debug-\(mode)" : nil))
                let seconds = Date().timeIntervalSince(wall)
                let cpuUsed = cpuSeconds() - cpu

                let stem = (name(fileIndex) as NSString).deletingPathExtension
                let path = "\(out)/\(stem)-\(mode).tif"
                if env("STAR_CLOUD_REPLAY_WRITE") != "0" {
                    XCTAssertTrue(result.merged.write(to: path), "could not write \(path)")
                }
                print("replay frame \(fileIndex) \(mode): \(result.warpCount) neighbours, " +
                      String(format: "%.2fs wall, %.2fs cpu", seconds, cpuUsed) + " -> \(path)")
            }
        }
    }
}
