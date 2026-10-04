import XCTest
@testable import StarCore

/// Where star looks for ffmpeg and ffprobe, and what it says when it cannot start one.
///
/// The resolution rules are a pure function of the environment and of what exists on disk, so
/// they are tested by handing it both.  The failure this exists for — an x86_64 ffmpeg shipped to
/// Apple silicon, where the system's own error says only "couldn't be opened" — is tested with
/// fake executable headers, so it needs neither a second machine nor Rosetta.
final class ToolPathsTests: XCTestCase {

    // MARK: - resolution

    private func resolve(_ tool: String = "ffmpeg",
                         environment: [String: String] = [:],
                         executableDirectory: String? = "/opt/star/Star.app/Contents/MacOS",
                         runnable: Set<String> = []) -> String
    {
        ToolPaths.resolve(tool: tool,
                          environment: environment,
                          executableDirectory: executableDirectory.map { URL(fileURLWithPath: $0) },
                          isRunnable: { runnable.contains($0) })
    }

    func testTheCopyBesideTheExecutableIsUsed() {
        let beside = "/opt/star/Star.app/Contents/MacOS/\(ToolPaths.fileName(of: "ffmpeg"))"
        XCTAssertEqual(resolve(runnable: [beside]), beside)
    }

    func testTheBundledCopyBeatsOneOnPath() {
        let beside = "/opt/star/Star.app/Contents/MacOS/\(ToolPaths.fileName(of: "ffprobe"))"
        let onPath = "/usr/local/bin/\(ToolPaths.fileName(of: "ffprobe"))"
        XCTAssertEqual(resolve("ffprobe",
                               environment: ["PATH": "/usr/local/bin"],
                               runnable: [beside, onPath]),
                       beside)
    }

    func testPathIsTheFallbackWhenNothingIsBundled() {
        let onPath = "/usr/local/bin/\(ToolPaths.fileName(of: "ffmpeg"))"
        XCTAssertEqual(resolve(environment: ["PATH": "/usr/bin\(pathSeparator)/usr/local/bin"],
                               runnable: [onPath]),
                       onPath)
    }

    /// A directory somebody named on purpose is final, even if it turns out to be empty:
    /// quietly using a different copy would make the setting impossible to reason about.
    func testTheOverrideDirectoryIsFinalEvenWhenItIsEmpty() {
        let beside = "/opt/star/Star.app/Contents/MacOS/\(ToolPaths.fileName(of: "ffmpeg"))"
        let result = resolve(environment: [ToolPaths.directoryOverrideVariable: "/somewhere/else"],
                             runnable: [beside])
        XCTAssertEqual(result, "/somewhere/else/\(ToolPaths.fileName(of: "ffmpeg"))")
    }

    func testAnEmptyOverrideIsIgnored() {
        let beside = "/opt/star/Star.app/Contents/MacOS/\(ToolPaths.fileName(of: "ffmpeg"))"
        XCTAssertEqual(resolve(environment: [ToolPaths.directoryOverrideVariable: ""], runnable: [beside]),
                       beside)
    }

    /// With nothing runnable anywhere the answer is where the tool belongs, so that the error
    /// that follows says where to put it.
    func testWhenNothingIsRunnableTheAnswerIsBesideTheExecutable() {
        XCTAssertEqual(resolve(environment: ["PATH": "/usr/bin"]),
                       "/opt/star/Star.app/Contents/MacOS/\(ToolPaths.fileName(of: "ffmpeg"))")
    }

    func testWithNoExecutableDirectoryAtAllItStillAnswers() {
        XCTAssertEqual(resolve(executableDirectory: nil), ToolPaths.fileName(of: "ffmpeg"))
    }

    // MARK: - a development tree

    /// `swift build` leaves nothing beside the executable, but `ffmpeg/build.sh --install`
    /// put a copy in the repository's external_binaries/bin, several levels up.
    func testASwiftPMBuildFindsTheRepositorysCopy() {
        let name = ToolPaths.fileName(of: "ffmpeg")
        let repoCopy = "/work/star/external_binaries/bin/\(name)"
        XCTAssertEqual(resolve(executableDirectory: "/work/star/daemon/.build/debug", runnable: [repoCopy]),
                       repoCopy)
        XCTAssertEqual(resolve(executableDirectory: "/work/star/daemon/.build/arm64-apple-macosx/release",
                               runnable: [repoCopy]),
                       repoCopy)
    }

    /// An installed star must not go looking through whatever happens to be above it.
    func testAnInstalledExecutableDoesNotSearchUpwards() {
        let name = ToolPaths.fileName(of: "ffmpeg")
        let stray = "/usr/external_binaries/bin/\(name)"
        XCTAssertEqual(resolve(executableDirectory: "/usr/local/bin", runnable: [stray]),
                       "/usr/local/bin/\(name)")
        XCTAssertTrue(ToolPaths.developmentTreeCandidates(name: name,
                                                          from: URL(fileURLWithPath: "/usr/local/bin")).isEmpty)
    }

    func testTheBundledCopyBeatsTheRepositorysEvenUnderABuildDirectory() {
        let name = ToolPaths.fileName(of: "ffmpeg")
        let beside = "/work/star/daemon/.build/debug/\(name)"
        let repoCopy = "/work/star/external_binaries/bin/\(name)"
        XCTAssertEqual(resolve(executableDirectory: "/work/star/daemon/.build/debug",
                               runnable: [beside, repoCopy]),
                       beside)
    }

    // MARK: - reading an executable's architecture

    /// A thin 64-bit little-endian Mach-O header for `cpuType`.
    private func machO(cpuType: UInt32) -> [UInt8] {
        var bytes = le32(0xFEEDFACF)
        bytes += le32(cpuType)
        bytes += [UInt8](repeating: 0, count: 24)
        return bytes
    }

    /// A universal Mach-O header listing `cpuTypes`.
    private func fatMachO(_ cpuTypes: [UInt32]) -> [UInt8] {
        var bytes = be32(0xCAFEBABE)
        bytes += be32(UInt32(cpuTypes.count))
        for cpuType in cpuTypes {
            // cputype, cpusubtype, offset, size, align
            for field in [cpuType, 0, 0x4000, 0x1000, 14] {
                bytes += be32(field)
            }
        }
        return bytes
    }

    private func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
    }

    private func be32(_ value: UInt32) -> [UInt8] { le32(value).reversed() }

    private let arm64 = UInt32(0x0100000C)
    private let x86_64 = UInt32(0x01000007)

    func testAThinMachOReportsItsArchitecture() {
        XCTAssertEqual(ToolPaths.executableArchitectures(inHeader: machO(cpuType: arm64)), ["arm64"])
        XCTAssertEqual(ToolPaths.executableArchitectures(inHeader: machO(cpuType: x86_64)), ["x86_64"])
    }

    func testAUniversalMachOReportsEverySlice() {
        XCTAssertEqual(ToolPaths.executableArchitectures(inHeader: fatMachO([x86_64, arm64])),
                       ["x86_64", "arm64"])
    }

    func testELFReportsItsArchitecture() {
        func elf(machine: UInt16) -> [UInt8] {
            var header = [UInt8](repeating: 0, count: 64)
            header.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
            header[4] = 2   // 64-bit
            header[5] = 1   // little endian
            header[18] = UInt8(machine & 0xFF)
            header[19] = UInt8(machine >> 8)
            return header
        }
        XCTAssertEqual(ToolPaths.executableArchitectures(inHeader: elf(machine: 0x3E)), ["x86_64"])
        XCTAssertEqual(ToolPaths.executableArchitectures(inHeader: elf(machine: 0xB7)), ["arm64"])
    }

    func testPEReportsItsArchitecture() {
        func pe(machine: UInt16) -> [UInt8] {
            var header = [UInt8](repeating: 0, count: 256)
            header[0] = 0x4D; header[1] = 0x5A            // "MZ"
            header[0x3C] = 0x80                           // the PE signature is at 0x80
            header[0x80] = 0x50; header[0x81] = 0x45      // "PE\0\0"
            header[0x84] = UInt8(machine & 0xFF)
            header[0x85] = UInt8(machine >> 8)
            return header
        }
        XCTAssertEqual(ToolPaths.executableArchitectures(inHeader: pe(machine: 0x8664)), ["x86_64"])
        XCTAssertEqual(ToolPaths.executableArchitectures(inHeader: pe(machine: 0xAA64)), ["arm64"])
    }

    func testAScriptOrJunkHasNoArchitecture() {
        XCTAssertNil(ToolPaths.executableArchitectures(inHeader: Array("#!/bin/sh\necho hello\n".utf8)))
        XCTAssertNil(ToolPaths.executableArchitectures(inHeader: []))
        XCTAssertNil(ToolPaths.executableArchitectures(inHeader: [0xCA, 0xFE]))
    }

    // MARK: - saying why a tool will not start

    private func scratchFile(_ contents: [UInt8], executable: Bool = true) throws -> String {
        let directory = FileManager.default.temporaryDirectory
          .appendingPathComponent("ToolPathsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("ffmpeg")
        try Data(contents).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644],
                                              ofItemAtPath: file.path)
        return file.path
    }

    /// The header of an executable built for the architecture this process is not.
    private func foreignMachO() -> (header: [UInt8], name: String) {
        ToolPaths.processArchitecture == "arm64"
          ? (machO(cpuType: x86_64), "x86_64")
          : (machO(cpuType: arm64), "arm64")
    }

    #if os(macOS)
    /// The reported failure: an x86_64 ffmpeg on an Apple silicon Mac.
    func testAWrongArchitectureToolIsNamedAsSuch() throws {
        let foreign = foreignMachO()
        let path = try scratchFile(foreign.header)
        let problem = try XCTUnwrap(ToolPaths.problem(with: path))
        XCTAssertTrue(problem.contains("built for \(foreign.name)"), problem)
        XCTAssertTrue(problem.contains("running as \(ToolPaths.processArchitecture)"), problem)
    }

    func testAUniversalToolWithThisArchitectureIsFine() throws {
        let path = try scratchFile(fatMachO([x86_64, arm64]))
        XCTAssertNil(ToolPaths.problem(with: path))
    }

    func testAToolThatIsNotExecutableIsNamedAsSuch() throws {
        let path = try scratchFile(fatMachO([x86_64, arm64]), executable: false)
        let problem = try XCTUnwrap(ToolPaths.problem(with: path))
        XCTAssertTrue(problem.contains("not marked executable"), problem)
    }
    #endif

    func testAMissingToolSaysHowToProvideOne() throws {
        let problem = try XCTUnwrap(ToolPaths.problem(with: "/definitely/not/here/ffmpeg"))
        XCTAssertTrue(problem.contains("does not exist"), problem)
        XCTAssertTrue(problem.contains(ToolPaths.directoryOverrideVariable), problem)
    }

    #if os(macOS)
    func testALaunchFailureCarriesTheDiagnosisRatherThanTheSystemsWording() throws {
        let foreign = foreignMachO()
        let path = try scratchFile(foreign.header)
        let underlying = NSError(domain: NSCocoaErrorDomain, code: 3584,
                                 userInfo: [NSLocalizedDescriptionKey: "The file “ffmpeg” couldn’t be opened."])
        let error = ToolLaunchError(path: path, underlying: underlying)
        XCTAssertTrue(error.description.contains("built for \(foreign.name)"), error.description)
        XCTAssertFalse(error.description.contains("couldn’t be opened"), error.description)
        XCTAssertEqual(error.errorDescription, error.description)
    }

    /// End to end: actually launching a tool built for the wrong architecture, the way the
    /// failure first appeared.  The kernel refuses to run it, and the error that comes out
    /// has to say why.
    func testStartingAForeignExecutableGivesTheDiagnosis() throws {
        let foreign = foreignMachO()
        let path = try scratchFile(foreign.header)
        XCTAssertThrowsError(try shellOut(to: path, arguments: ["-version"])) { error in
            XCTAssertTrue(String(describing: error).contains("built for \(foreign.name)"),
                          String(describing: error))
        }
    }
    #endif

    // MARK: - hardware

    func testDecodingIsSoftwareUnlessAskedOtherwise() {
        XCTAssertEqual(FFmpegHardware.decodeArguments(environment: [:]), [])
        for off in ["", "0", "no", "off", "none", "false", "OFF", " none "] {
            XCTAssertEqual(FFmpegHardware.decodeArguments(environment: [FFmpegHardware.decodeVariable: off]), [],
                           "'\(off)' should leave decoding in software")
        }
    }

    func testAnExplicitMethodIsPassedToFFmpeg() {
        XCTAssertEqual(FFmpegHardware.decodeArguments(environment: [FFmpegHardware.decodeVariable: "videotoolbox"]),
                       ["-hwaccel", "videotoolbox"])
        XCTAssertEqual(FFmpegHardware.decodeArguments(environment: [FFmpegHardware.decodeVariable: " auto "]),
                       ["-hwaccel", "auto"])
    }

    // MARK: -

    private var pathSeparator: String {
        #if os(Windows)
        ";"
        #else
        ":"
        #endif
    }
}
