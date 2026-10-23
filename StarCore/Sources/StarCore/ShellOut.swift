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
    // Never the parent's stdin.  A child that inherits it can read it, and ffmpeg does, for
    // keypresses: whatever else is reading the same terminal or pipe loses those bytes, and a
    // stray `q` ends the encode.  (stard already points its own stdin at /dev/null; the gui and
    // the cli do not.)
    process.standardInput = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        throw ToolLaunchError(path: executable, underlying: error)
    }

    // Both pipes are drained while the child runs. Waiting for exit first, and only then reading,
    // deadlocks a child that writes more than a pipe holds (64 KB): it blocks on the full pipe,
    // never exits, and `waitUntilExit` never returns. ffmpeg's `-progress` and probe output get
    // there. Each pipe has a reader of its own because a child that fills one while the parent is
    // blocked reading the other deadlocks just the same.
    let collected = PipeCollector()
    let readers = DispatchGroup()
    for (pipe, isStdout) in [(stdoutPipe, true), (stderrPipe, false)] {
        readers.enter()
        DispatchQueue.global().async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            collected.set(data, stdout: isStdout)
            readers.leave()
        }
    }
    process.waitUntilExit()
    readers.wait()

    let stdoutData = collected.stdout
    let stderrData = collected.stderr
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


/// What the two reader threads collected.
private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func set(_ data: Data, stdout: Bool) {
        lock.lock(); defer { lock.unlock() }
        if stdout { out = data } else { err = data }
    }
    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return err }
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

