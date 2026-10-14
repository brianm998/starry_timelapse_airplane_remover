import Foundation
import logging

/// What the ffmpeg star is running has, and what this machine can actually start.
///
/// The tables in FFmpegCodec.swift list every encoder star knows how to offer, whichever
/// platform's ffmpeg carries it.  Two things narrow that to what a user can use:
///
///  - the ffmpeg in use may not have an encoder at all: VideoToolbox only exists in the Mac
///    build, NVENC only in the Windows and Linux ones, and a build made from source may have
///    dropped a software codec;
///  - a hardware encoder that is built in still needs the hardware.  `h264_nvenc` is in every
///    Windows ffmpeg whether or not the PC has an NVIDIA GPU, and listing it there would be a
///    button that fails.
///
/// The first is answered by `ffmpeg -encoders`.  The second can only be answered by trying, so
/// each hardware encoder is started once, on a few black frames, and the answer is kept for the
/// life of the process.  `warmUp()` does all of it in the background so that the Render Video
/// dialog, which asks, is not the thing that waits.
///
/// If ffmpeg cannot be run at all (a checkout that has not built one, a unit test) nothing is
/// filtered: the tables are then the best information there is, and the export that follows
/// reports the real problem.
public final class FFmpegCapabilities: @unchecked Sendable {

    public static let shared = FFmpegCapabilities()

    /// Runs ffmpeg with the arguments; its exit status and merged output, or nil if it could not
    /// be started.  A parameter so that tests need no ffmpeg.
    typealias Runner = @Sendable (_ arguments: [String]) -> (status: Int32, output: String)?

    private let runner: Runner
    private let lock = NSLock()
    private var loaded = false
    /// Encoder names from `ffmpeg -encoders`; nil if that could not be read.
    private var listed: Set<String>?
    /// The hardware encoders that started.
    private var started: Set<String> = []

    init(runner: @escaping Runner = FFmpegCapabilities.runBundledFFmpeg) {
        self.runner = runner
    }

    /// Reads what ffmpeg has and tries its hardware encoders, off the calling thread.
    public func warmUp() {
        DispatchQueue.global(qos: .utility).async { [self] in
            load()
        }
    }

    /// True if `encoder` can be used: this ffmpeg has it, and for a hardware encoder it starts
    /// on this machine.  Waits for the first answer if one is still being worked out.
    public func isUsable(_ encoder: FFmpegEncoder) -> Bool {
        load()
        lock.lock()
        defer { lock.unlock() }
        guard let listed else { return true }
        guard listed.contains(encoder.rawValue) else { return false }
        return !encoder.isHardware || started.contains(encoder.rawValue)
    }

    // MARK: -

    private func load() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true

        guard let result = runner(["-hide_banner", "-encoders"]), result.status == 0 else {
            Log.w("could not list ffmpeg's encoders (\(ToolPaths.ffmpeg)); not narrowing the encoder list")
            return
        }
        let names = Self.encoderNames(inListing: result.output)
        listed = names

        // Only the ones the dialog could offer: a hardware encoder with no software pixel format
        // (the Vulkan and VAAPI ones) is not reachable from still images, so is not worth starting.
        let candidates = FFmpegEncoder.allCases.filter {
            $0.isHardware && names.contains($0.rawValue) && !$0.usablePixelFormats.isEmpty
        }
        guard !candidates.isEmpty else { return }

        let outcomes = ProbeOutcomes()
        let runner = self.runner
        DispatchQueue.concurrentPerform(iterations: candidates.count) { index in
            let encoder = candidates[index]
            outcomes.record(encoder.rawValue, works: Self.starts(encoder, using: runner))
        }
        started = outcomes.names
        Log.i("hardware encoders that start here: \(started.sorted().joined(separator: ", "))")
    }

    /// Encodes three black frames with `encoder` and throws the result away.
    static func starts(_ encoder: FFmpegEncoder, using runner: Runner) -> Bool {
        guard let pixelFormat = encoder.usablePixelFormats.first else { return false }
        let arguments = [
            "-hide_banner", "-nostdin", "-loglevel", "error",
            "-f", "lavfi", "-i", "color=c=black:s=1280x720:r=24",
            "-frames:v", "3",
            "-c:v", encoder.rawValue, "-pix_fmt", pixelFormat.rawValue,
            "-f", "null", "-",
        ]
        guard let result = runner(arguments) else { return false }
        return result.status == 0
    }

    /// The names in `ffmpeg -encoders`: after the `------` line, each row is six flag
    /// characters, then the name.
    static func encoderNames(inListing listing: String) -> Set<String> {
        var names: Set<String> = []
        var inTable = false
        for line in listing.split(whereSeparator: \.isNewline) {
            if !inTable {
                inTable = line.trimmingCharacters(in: .whitespaces).hasPrefix("------")
                continue
            }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.count >= 2, fields[0].count == 6 {
                names.insert(String(fields[1]))
            }
        }
        return names
    }

    /// Runs the bundled ffmpeg, giving up on it after 30 seconds: a hardware encoder whose driver
    /// hangs must not hang the app.
    static func runBundledFFmpeg(_ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ToolPaths.ffmpeg)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// The probes run concurrently and each reports once.
private final class ProbeOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var started: Set<String> = []

    func record(_ name: String, works: Bool) {
        guard works else { return }
        lock.lock()
        started.insert(name)
        lock.unlock()
    }

    var names: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
}
