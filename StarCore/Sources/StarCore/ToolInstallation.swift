import Foundation
import logging

public struct ToolPaths {
    public let ffmpegPath: String
    public let alignImageStackPath: String
}

public enum ToolError: Error, LocalizedError {
    case unableToInstallHomebrew
    case toolNotFound(String)
    case brewInstallFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unableToInstallHomebrew:
            return "Homebrew is not available and automatic installation failed or was denied."
        case .toolNotFound(let name):
            return "\(name) could not be found or installed."
        case .brewInstallFailed(let tool):
            return "Failed to install \(tool) via Homebrew."
        }
    }
}

/// Runs a shell command and returns its stdout (throws on non-zero exit)
func runShell(_ command: String, arguments: [String] = []) throws -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    proc.arguments = [command] + arguments

    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError  = pipe

    try proc.run()
    proc.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let out  = String(decoding: data, as: UTF8.self)
    guard proc.terminationStatus == 0 else {
        throw NSError(domain: "shell",
                      code: Int(proc.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: out])
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Attempts to install Homebrew if missing
func installHomebrewIfNeeded() throws {
    if let brewPath = try? runShell("which", arguments: ["brew"]), !brewPath.isEmpty {
        return
    }

    Log.i("⚠️ Homebrew not found. Attempting to install...")

    // Official Homebrew install script
    let installCmd = #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh")"#

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/bash")
    proc.arguments = ["-c", installCmd]

    // <--- FIX: assign FileHandle.* explicitly
    proc.standardInput  = FileHandle.standardInput
    proc.standardOutput = FileHandle.standardOutput
    proc.standardError  = FileHandle.standardError

    try proc.run()
    proc.waitUntilExit()

    guard proc.terminationStatus == 0 else {
        throw ToolError.unableToInstallHomebrew
    }
    Log.d("✅ Homebrew installed.")
}

/// Installs a brew formula or cask if missing
func installToolIfMissing(_ binaryName: String,
                          formulaName: String? = nil,
                          isCask: Bool = false) throws {
    // If already on PATH, skip
    if let path = try? runShell("which", arguments: [binaryName]), !path.isEmpty {
        return
    }

    let pkg = formulaName ?? binaryName
    Log.d("🔧 Installing \(pkg) via Homebrew…")
    try installHomebrewIfNeeded()

    let args = isCask ? ["install", "--cask", pkg] : ["install", pkg]
    do {
        _ = try runShell("brew", arguments: args)
        Log.d("✅ \(pkg) installed.")
    } catch {
        Log.e("Brew install failed for \(pkg): \(error)")
        throw ToolError.brewInstallFailed(pkg)
    }
}

/// Public entry: ensures ffmpeg & align_image_stack are installed and returns their exact paths
public func resolveToolPaths() throws -> ToolPaths {
    // 1) Ensure installation
    try installToolIfMissing("ffmpeg")
    try installToolIfMissing("align_image_stack", formulaName: "hugin", isCask: true)

    // 2) Locate ffmpeg via brew prefix
    let ffmpegPrefix = try runShell("brew", arguments: ["--prefix", "ffmpeg"])
    let ffmpegPath   = "\(ffmpegPrefix)/bin/ffmpeg"
    guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
        throw ToolError.toolNotFound("ffmpeg binary not found at \(ffmpegPath)")
    }

    // 3) Locate align_image_stack inside Hugin.app
    let appCandidate = "/Applications/Hugin.app/Contents/MacOS/align_image_stack"
    if FileManager.default.isExecutableFile(atPath: appCandidate) {
        return ToolPaths(ffmpegPath: ffmpegPath,
                         alignImageStackPath: appCandidate)
    }

    // 4) Check Homebrew Caskroom location
    let brewPrefix  = try runShell("brew", arguments: ["--prefix"])
    let caskroomDir = "\(brewPrefix)/Caskroom/hugin"
    if FileManager.default.fileExists(atPath: caskroomDir) {
        let versions = try FileManager.default.contentsOfDirectory(atPath: caskroomDir)
        for version in versions {
            let candidate = "\(caskroomDir)/\(version)/Hugin.app/Contents/MacOS/align_image_stack"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return ToolPaths(ffmpegPath: ffmpegPath,
                                 alignImageStackPath: candidate)
            }

            let candidate2 = "\(caskroomDir)/\(version)/Hugin/Hugin.app/Contents/MacOS/align_image_stack"
            if FileManager.default.isExecutableFile(atPath: candidate2) {
                return ToolPaths(ffmpegPath: ffmpegPath,
                                 alignImageStackPath: candidate2)
            }
        }
    }

    // 5) Fallback to which
    if let fallback = try? runShell("which", arguments: ["align_image_stack"]),
       !fallback.isEmpty {
        return ToolPaths(ffmpegPath: ffmpegPath,
                         alignImageStackPath: fallback)
    }

    throw ToolError.toolNotFound("align_image_stack")
}
