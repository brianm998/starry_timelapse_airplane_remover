import XCTest

#if !os(Windows)
/// The fatal-signal handler (`crash_handler.c`) writes the crashing thread's backtrace to
/// stderr, so a failure on a CI runner that keeps no crash report still names the site.  It
/// can only be observed from outside the dying process, so this spawns `StarCrashProbe`,
/// which installs the handler and dereferences an unmapped address.
final class CrashHandlerBacktraceTests: XCTestCase {

    /// The probe is built next to the test bundle: SwiftPM puts `StarCrashProbe` in the
    /// products directory, which is the `.xctest` bundle's parent on macOS and the
    /// `.xctest` executable's parent on Linux.
    private func probeURL() throws -> URL {
        let bundleURL = Bundle(for: CrashHandlerBacktraceTests.self).bundleURL
        let url = bundleURL.deletingLastPathComponent().appendingPathComponent("StarCrashProbe")
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            XCTFail("StarCrashProbe not found at \(url.path); it is built with the tests")
            throw CancellationError()
        }
        return url
    }

    func testASegfaultingChildWritesABacktraceToStderr() throws {
        let probe = try probeURL()
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("crash-handler-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = directory.appendingPathComponent("crash.note")

        let process = Process()
        process.executableURL = probe
        process.arguments = [note.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        // Read to EOF before waiting, so a full pipe cannot stall the child.
        let data = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)

        XCTAssertEqual(process.terminationReason, .uncaughtSignal, output)
        XCTAssertEqual(process.terminationStatus, SIGSEGV, output)
        XCTAssertTrue(output.contains("signal: SIGSEGV"), output)

        let header = "backtrace of the crashing thread:\n"
        guard let range = output.range(of: header) else {
            XCTFail("no backtrace header in the child's stderr:\n\(output)")
            return
        }
        let frames = output[range.upperBound...]
          .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertGreaterThanOrEqual(frames.count, 1, "no frame after the header:\n\(output)")
    }
}
#endif
