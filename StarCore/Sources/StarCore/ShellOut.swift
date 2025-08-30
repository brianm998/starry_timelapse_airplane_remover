import Foundation

// shell out stuff

func shellOut(
  to executable: String,        // needs full path name
  arguments args: [String],
  at workingDirectory: String? = nil) throws -> String
{
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = args
    
    // Set working directory if provided
    if let workingDirectory = workingDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

    if process.terminationStatus != 0 {
        throw ShellOutError(
            exitCode: process.terminationStatus,
            output: stdout,
            errorOutput: stderr
        )
    }

    return stdout
}


struct ShellOutError: Error, CustomStringConvertible {
    let exitCode: Int32
    let output: String
    let errorOutput: String
    
    var description: String {
        return """
        ShellOutError: Exit code \(exitCode)
        STDOUT:
        \(output)
        
        STDERR:
        \(errorOutput)
        """
    }
}

