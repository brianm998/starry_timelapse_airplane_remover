import Foundation
import logging

struct ToolPaths {
    let ffmpegPath: String
    let alignImageStackPath: String
}

func resolveToolPaths() throws -> ToolPaths {
    try installToolIfMissing("ffmpeg")
    try installToolIfMissing("align_image_stack", isCask: true)

    guard
        let ffmpegPath = which("ffmpeg")
    else {
        throw ToolError.toolNotFound("ffmpeg")
    }

    guard
        let alignImageStackPath = which("align_image_stack")
    else {
        throw ToolError.toolNotFound("align_image_stack")
    }

    return ToolPaths(ffmpegPath: ffmpegPath, alignImageStackPath: alignImageStackPath)
}

enum ToolError: Error, LocalizedError {
    case unableToInstallHomebrew
    case toolNotFound(String)
    case brewInstallFailed(String)

    var errorDescription: String? {
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

func runShell(_ command: String, arguments: [String] = []) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + arguments

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe

    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        throw NSError(domain: "shell", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: output])
    }

    return output.trimmingCharacters(in: .whitespacesAndNewlines)
}

func which(_ command: String) -> String? {
    return try? runShell("which", arguments: [command])
}

func installHomebrewIfNeeded() throws {
    if which("brew") != nil {
        return
    }

    Log.i("⚠️ Homebrew not found. Attempting to install...")

    let installCommand = """
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    """

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", installCommand]
    process.standardInput = FileHandle.standardInput
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw ToolError.unableToInstallHomebrew
    }

    Log.d("✅ Homebrew installed.")
}

func installToolIfMissing(_ name: String, isCask: Bool = false) throws {
    if which(name) != nil {
        return
    }

    Log.d("🔧 Installing \(name) via Homebrew...")
    try installHomebrewIfNeeded()

    let installArgs = isCask ? ["install", "--cask", name] : ["install", name]
    do {
        _ = try runShell("brew", arguments: installArgs)
    } catch {
        throw ToolError.brewInstallFailed(name)
    }

    guard which(name) != nil else {
        throw ToolError.toolNotFound(name)
    }

    Log.d("✅ \(name) installed.")
}

