import XCTest
@testable import StarCore
import StarCppBridge

/// The numbers behind `ui.tiff_compression_help`: how much bigger an uncompressed 16 bit tiff frame is than a PackBits one, and how much
/// faster star reads it.  Opt-in (it makes and reads a few hundred megabytes): `STAR_MEASURE_TIFF=<a night frame, any image ffmpeg reads>`.
///
///     STAR_MEASURE_TIFF=test_data/test_a7sii_10/LRT_00080.jpg swift test --package-path StarCore --filter TiffCompressionMeasurement
///
/// Reads are timed through star's own loader (`MatWrapper.load`), warm, as the minimum of several, because that is what a run sees (the
/// frame was written moments before, and the page cache has it).  The minimum, not the mean: a single slow read says something about the
/// machine, not about the format.
final class TiffCompressionMeasurement: XCTestCase {

    func testRawAgainstPackBits() throws {
        guard let source = ProcessInfo.processInfo.environment["STAR_MEASURE_TIFF"], !source.isEmpty else {
            throw XCTSkip("set STAR_MEASURE_TIFF to a night frame to run this")
        }
        let tools = URL(fileURLWithPath: #filePath)
          .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
          .appendingPathComponent("external_binaries/bin")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: tools.appendingPathComponent("ffmpeg").path))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TiffCompression-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var rows: [String] = []
        // "4K, ground black": the lower half of the frame pure black, as a sequence whose ground is dark (a9 exports) has it: runs of zeros
        // are what PackBits is good at.
        for (label, scale) in [("full", nil), ("4K", "3840:-1"), ("6K", "6000:-1"),
                               ("4K, ground black", "3840:-1,drawbox=x=0:y=ih/2:w=iw:h=ih/2:color=black:t=fill")] as [(String, String?)] {
            var sizes: [String: Int] = [:]
            var times: [String: Double] = [:]
            for algo in ["raw", "packbits"] {
                let path = scratch.appendingPathComponent("\(label)-\(algo).tiff").path
                var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"]
                // For a video: `STAR_MEASURE_SEEK=<seconds>` to land on a frame that has stars in it rather than the first one.
                if let seek = ProcessInfo.processInfo.environment["STAR_MEASURE_SEEK"], !seek.isEmpty { arguments += ["-ss", seek] }
                arguments += ["-i", source, "-frames:v", "1"]
                if let scale { arguments += ["-vf", scale.contains("drawbox") ? "scale=\(scale)" : "scale=\(scale):flags=lanczos"] }
                arguments += ["-pix_fmt", "rgb48le", "-compression_algo", algo, "-update", "1", path]
                let process = Process()
                process.executableURL = tools.appendingPathComponent("ffmpeg")
                process.arguments = arguments
                try process.run()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                sizes[algo] = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                _ = MatWrapper.load(fromFilename: path)   // warm
                var best = Double.infinity
                for _ in 0..<7 {
                    let start = Date()
                    let mat = MatWrapper.load(fromFilename: path)
                    best = min(best, Date().timeIntervalSince(start))
                    XCTAssertNotNil(mat)
                }
                times[algo] = best
            }
            let raw = Double(sizes["raw"] ?? 0), packed = Double(sizes["packbits"] ?? 1)
            rows.append(String(format: "%@: raw %.1f MB read in %.0f ms, packbits %.1f MB read in %.0f ms: %.2fx faster, %.1f%% more disk",
                               label, raw / 1e6, (times["raw"] ?? 0) * 1000, packed / 1e6, (times["packbits"] ?? 0) * 1000,
                               (times["packbits"] ?? 0) / max(times["raw"] ?? 1, 1e-9), (raw / packed - 1) * 100))
        }
        print("TIFF COMPRESSION MEASUREMENT\n" + rows.joined(separator: "\n"))
    }
}
