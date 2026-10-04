import Foundation
import logging

/// Where star finds the ffmpeg and ffprobe it drives, and — when one cannot be started — why.
///
/// star ships its own pair, built by ffmpeg/build.sh (see ffmpeg/README.md), next to each
/// executable that needs them: Star.app/Contents/MacOS for the gui, beside stard in the
/// star-desktop bundle.  Anything else is only a fallback, so that a development build and a
/// machine that has its own ffmpeg still work.
///
/// Looked at, in order:
///   1. `$STAR_FFMPEG_DIR`, if set.  That is final: a directory somebody named on purpose is
///      never quietly replaced by another copy, even if it turns out to be empty.
///   2. beside the running executable
///   3. `external_binaries/bin` of the repository, for a SwiftPM build under `.build`, which
///      is where `ffmpeg/build.sh --install` puts them
///   4. the directories on `PATH`
///
/// If none of those holds a runnable copy the result is where (2) would have been, so the
/// error that follows names the place the tool belongs.
public struct ToolPaths {

    /// Names a directory holding `ffmpeg` and `ffprobe`; consulted before anywhere else.
    public static let directoryOverrideVariable = "STAR_FFMPEG_DIR"

    public static var ffmpeg: String { path(of: "ffmpeg") }
    public static var ffprobe: String { path(of: "ffprobe") }

    /// True if both tools resolve to something that can be run.
    public static var isAvailable: Bool {
        isRunnable(ffmpeg) && isRunnable(ffprobe)
    }

    // MARK: - resolution

    /// The file name of `tool` on this platform.
    static func fileName(of tool: String) -> String {
        #if os(Windows)
        return "\(tool).exe"
        #else
        return tool
        #endif
    }

    static func path(of tool: String) -> String {
        resolve(tool: tool,
                environment: ProcessInfo.processInfo.environment,
                executableDirectory: Bundle.main.executableURL?.deletingLastPathComponent(),
                isRunnable: isRunnable)
    }

    /// The resolution rules, free of the process's own state so they can be tested.
    static func resolve(tool: String,
                        environment: [String: String],
                        executableDirectory: URL?,
                        isRunnable: (String) -> Bool) -> String
    {
        let name = fileName(of: tool)

        if let override = environment[directoryOverrideVariable], !override.isEmpty {
            return URL(fileURLWithPath: override).appendingPathComponent(name).path
        }

        var candidates: [URL] = []
        if let executableDirectory {
            candidates.append(executableDirectory.appendingPathComponent(name))
            candidates += developmentTreeCandidates(name: name, from: executableDirectory)
        }
        candidates += searchPathCandidates(name: name, environment: environment)

        if let found = candidates.first(where: { isRunnable($0.path) }) {
            return found.path
        }
        return executableDirectory?.appendingPathComponent(name).path ?? name
    }

    /// A SwiftPM build runs from `<repo>/<package>/.build/<configuration>/` with nothing
    /// bundled beside it, but the repository keeps the copy it built in `external_binaries/bin`.
    /// Only looked for under a `.build` directory, so an installed copy of star never goes
    /// hunting through whatever happens to sit above it.
    static func developmentTreeCandidates(name: String, from directory: URL) -> [URL] {
        var directory = directory.standardizedFileURL
        guard directory.pathComponents.contains(".build") else { return [] }

        var candidates: [URL] = []
        while directory.pathComponents.count > 1 {
            candidates.append(directory
                                .appendingPathComponent("external_binaries")
                                .appendingPathComponent("bin")
                                .appendingPathComponent(name))
            directory.deleteLastPathComponent()
        }
        return candidates
    }

    static func searchPathCandidates(name: String, environment: [String: String]) -> [URL] {
        guard let searchPath = environment["PATH"] else { return [] }
        #if os(Windows)
        let separator: Character = ";"
        #else
        let separator: Character = ":"
        #endif
        return searchPath
          .split(separator: separator)
          .map { URL(fileURLWithPath: String($0)).appendingPathComponent(name) }
    }

    static func isRunnable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        #if os(Windows)
        return true
        #else
        return FileManager.default.isExecutableFile(atPath: path)
        #endif
    }

    // MARK: - why a tool will not start

    /// The architecture this process is running as; a tool for any other one cannot be
    /// started (Rosetta lets an arm64 Mac run x86_64 code, but is not always installed).
    #if arch(arm64)
    static let processArchitecture = "arm64"
    #elseif arch(x86_64)
    static let processArchitecture = "x86_64"
    #else
    static let processArchitecture = "unknown"
    #endif

    /// One sentence on why `path` cannot be run, or nil if nothing looks wrong with it.
    ///
    /// This exists because the underlying failure — "The file “ffmpeg” couldn’t be opened",
    /// POSIX error 86, `Bad CPU type in executable` — says nothing about what is actually
    /// wrong, which for a long time was an x86_64 ffmpeg on an Apple silicon Mac.
    public static func problem(with path: String) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            return """
              \(path) does not exist. star keeps ffmpeg and ffprobe next to its own executable; \
              set \(directoryOverrideVariable) to a directory holding both to use another copy
              """
        }
        if let architectures = executableArchitectures(at: path),
           !architectures.isEmpty,
           !architectures.contains(processArchitecture)
        {
            let built = architectures.joined(separator: ", ")
            return "\(path) is built for \(built), but star is running as \(processArchitecture)"
        }
        #if !os(Windows)
        if !fileManager.isExecutableFile(atPath: path) {
            return "\(path) is not marked executable"
        }
        #endif
        return nil
    }

    /// The CPU architectures an executable file contains, by reading its header, or nil if it
    /// is not a Mach-O, ELF or PE file (or cannot be read).  Names are the ones `uname -m`,
    /// `lipo -archs` and `#if arch()` use: arm64, x86_64, i386, arm.
    static func executableArchitectures(at path: String) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096) else { return nil }
        return executableArchitectures(inHeader: [UInt8](head))
    }

    static func executableArchitectures(inHeader bytes: [UInt8]) -> [String]? {
        func u16(_ offset: Int, bigEndian: Bool = false) -> UInt32? {
            guard offset + 2 <= bytes.count else { return nil }
            let pair = (UInt32(bytes[offset]), UInt32(bytes[offset + 1]))
            return bigEndian ? pair.0 << 8 | pair.1 : pair.1 << 8 | pair.0
        }
        func u32(_ offset: Int, bigEndian: Bool = false) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            let quad = bytes[offset ..< offset + 4].map { UInt32($0) }
            return bigEndian
              ? quad[0] << 24 | quad[1] << 16 | quad[2] << 8 | quad[3]
              : quad[3] << 24 | quad[2] << 16 | quad[1] << 8 | quad[0]
        }

        guard bytes.count >= 8 else { return nil }

        // Mach-O, universal: 0xCAFEBABE (32-bit entries) or 0xCAFEBABF (64-bit), big endian,
        // then a count and that many {cputype, cpusubtype, offset, size, align} records.
        if let magic = u32(0, bigEndian: true), magic == 0xCAFEBABE || magic == 0xCAFEBABF {
            guard let count = u32(4, bigEndian: true), count > 0, count < 32 else { return nil }
            let stride = magic == 0xCAFEBABE ? 20 : 32
            var architectures: [String] = []
            for index in 0 ..< Int(count) {
                guard let cpu = u32(8 + index * stride, bigEndian: true) else { break }
                architectures.append(machOArchitecture(cpu))
            }
            return architectures
        }

        // Mach-O, one architecture, little endian: 0xFEEDFACF (64-bit) / 0xFEEDFACE (32-bit).
        if let magic = u32(0), magic == 0xFEEDFACF || magic == 0xFEEDFACE, let cpu = u32(4) {
            return [machOArchitecture(cpu)]
        }

        // ELF: 0x7F "ELF", then e_machine two bytes in at offset 18, in the file's own byte order.
        if bytes[0] == 0x7F, bytes[1] == 0x45, bytes[2] == 0x4C, bytes[3] == 0x46 {
            guard let machine = u16(18, bigEndian: bytes.count > 5 && bytes[5] == 2) else { return nil }
            switch machine {
            case 0x3E: return ["x86_64"]
            case 0xB7: return ["arm64"]
            case 0x03: return ["i386"]
            case 0x28: return ["arm"]
            default:   return ["unknown"]
            }
        }

        // PE (Windows): "MZ", the offset of the "PE\0\0" signature at 0x3C, then the machine.
        if bytes[0] == 0x4D, bytes[1] == 0x5A,
           let peOffset = u32(0x3C).map(Int.init),
           peOffset + 6 <= bytes.count,
           bytes[peOffset] == 0x50, bytes[peOffset + 1] == 0x45,
           let machine = u16(peOffset + 4)
        {
            switch machine {
            case 0x8664: return ["x86_64"]
            case 0xAA64: return ["arm64"]
            case 0x014C: return ["i386"]
            case 0x01C4: return ["arm"]
            default:     return ["unknown"]
            }
        }

        return nil
    }

    private static func machOArchitecture(_ cpuType: UInt32) -> String {
        switch cpuType {
        case 0x0100000C: return "arm64"
        case 0x01000007: return "x86_64"
        case 0x00000007: return "i386"
        case 0x0000000C: return "arm"
        default:         return "unknown"
        }
    }
}

/// A tool that could not be started at all, as opposed to one that ran and failed.
///
/// Carries the reason `ToolPaths.problem(with:)` finds in the file itself in preference to the
/// system's own wording, which for the commonest causes does not name them.
public struct ToolLaunchError: LocalizedError, CustomStringConvertible, Sendable {
    public let path: String
    public let underlying: String
    public let problem: String?

    public init(path: String, underlying: Error) {
        self.path = path
        self.underlying = underlying.localizedDescription
        self.problem = ToolPaths.problem(with: path)
    }

    public var description: String {
        var message = "could not start \(path): "
        message += problem ?? underlying
        return message
    }

    public var errorDescription: String? { description }
}
