import XCTest
import Foundation
import StarDaemonMessages
import SwiftProtobuf

// §12.3 — spawn `stard`, drive each method, assert outputs.
// Requires the binary to be built first: swift build

final class DaemonIntegrationTests: XCTestCase {

    static var stardPath: String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // StarDaemonTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // daemon/
            .appendingPathComponent(".build/debug/stard")
        return url.path
    }

    // Returns a DaemonProcess, or skips the test if the binary is absent.
    func launchDaemon(scratchDir: String) throws -> DaemonProcess {
        guard FileManager.default.fileExists(atPath: Self.stardPath) else {
            throw XCTSkip("stard binary not found at \(Self.stardPath) — run `swift build` first")
        }
        return try DaemonProcess(binaryPath: Self.stardPath, scratchDir: scratchDir)
    }

    func makeScratchDir() throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("stard-test-\(arc4random())").path
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        return tmp
    }

    func testDaemonHello() async throws {
        let tmp = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let daemon = try launchDaemon(scratchDir: tmp)
        defer { daemon.terminate() }

        var req = Star_V1_HelloRequest()
        req.clientVersion = "test-1.0"
        let resp: Star_V1_HelloResponse = try await daemon.call(method: "Daemon.Hello", request: req)

        XCTAssertFalse(resp.daemonVersion.isEmpty)
        XCTAssertEqual(resp.scratchDir, tmp)
    }

    func testUnknownMethodReturnsError() async throws {
        let tmp = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let daemon = try launchDaemon(scratchDir: tmp)
        defer { daemon.terminate() }

        let result = await daemon.rawCall(id: 99, method: "No.Such.Method", payload: Data())
        guard case .error(let msg, _) = result else {
            XCTFail("expected error, got \(result)"); return
        }
        XCTAssertTrue(msg.contains("unknown method"))
    }

    func testDaemonShutdown() async throws {
        let tmp = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let daemon = try launchDaemon(scratchDir: tmp)

        let req = Star_V1_ShutdownRequest()
        let _: Star_V1_ShutdownResponse = try await daemon.call(method: "Daemon.Shutdown", request: req)
        // After Shutdown the process should exit within 1 second.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertTrue(daemon.hasTerminated)
    }

    func testEmptySessionList() async throws {
        let tmp = try makeScratchDir()
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let daemon = try launchDaemon(scratchDir: tmp)
        defer { daemon.terminate() }

        let req = Star_V1_ListSessionsRequest()
        let resp: Star_V1_ListSessionsResponse = try await daemon.call(method: "Session.List", request: req)
        XCTAssertEqual(resp.sessions.count, 0)
    }
}

// MARK: - Minimal DaemonProcess driver

/// Every test that talks to `stard` (DaemonIntegrationTests, the ExportEndToEndTestCase subclasses,
/// SessionConfigPersistenceTests) goes through this driver, and its reads used to have no bound
/// (ticket #209: `swift test` sat at 0% CPU for 95 minutes with the main thread in XCTWaiter).
final class DaemonProcess: @unchecked Sendable {
    private let process: Process
    private let stdinPipe:  Pipe
    private let stdoutPipe: Pipe
    private var nextID: UInt64 = 1
    private let lock = NSLock()
    /// How long the daemon may send nothing while a call waits on it.  The reads below block in the
    /// kernel and ignore task cancellation, so a daemon that goes quiet would otherwise hold the test
    /// (and `swift test`, and the heavy lock) for ever.  It is per message, not per call: an export
    /// that keeps reporting progress can take as long as it likes.
    private let idleTimeout: TimeInterval
    private var timedOutWaitingFor: String?

    /// `environment` replaces the daemon's whole environment if given; nil is this process's own.
    init(binaryPath: String, scratchDir: String, environment: [String: String]? = nil,
         arguments: [String]? = nil, idleTimeout: TimeInterval = 60) throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = arguments ?? ["--scratch", scratchDir]
        self.idleTimeout = idleTimeout
        if let environment { process.environment = environment }
        stdinPipe  = Pipe()
        stdoutPipe = Pipe()
        process.standardInput  = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError  = FileHandle.standardError
        // Writing to a daemon that has already died must be an error, not a SIGPIPE that kills xctest.
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        // The daemon holds its ends now.  Keeping ours open means the read end never sees end of
        // file when the daemon dies, so a crashed daemon looked exactly like a quiet one: a hang.
        try? stdoutPipe.fileHandleForWriting.close()
        try? stdinPipe.fileHandleForReading.close()
    }

    var hasTerminated: Bool { !process.isRunning }

    func terminate() { process.terminate() }

    enum Response {
        case response(Data)
        case error(String, Int32)
        case streamItem(Data)
        case streamEnd
    }

    private func nextRequestID() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let id = nextID; nextID += 1; return id
    }

    private func writeEnvelope(_ env: Star_V1_Envelope) throws {
        let data  = try env.serializedData()
        let frame = encodeFrame(data)
        try stdinPipe.fileHandleForWriting.write(contentsOf: frame)
    }

    /// Reads one envelope.  If the daemon sends nothing for `idleTimeout`, it is killed, which ends
    /// the read with end of file, and the error says what was being waited for.
    private func readEnvelope(waitingFor what: String) throws -> Star_V1_Envelope {
        let watchdog = DispatchWorkItem { [self] in
            lock.lock(); timedOutWaitingFor = what; lock.unlock()
            process.terminate()
            // A daemon that ignores SIGTERM, or a child of it holding the pipe open, must not outlive this.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if self.process.isRunning { kill(pid, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + idleTimeout, execute: watchdog)
        defer { watchdog.cancel() }
        do {
            let handle = stdoutPipe.fileHandleForReading
            let headerData = handle.readData(ofLength: 4)
            guard headerData.count == 4 else { throw DaemonDriverError.eof }
            let len = headerData.reduce(0) { ($0 << 8) | Int($1) }
            let body = handle.readData(ofLength: len)
            guard body.count == len else { throw DaemonDriverError.eof }
            return try Star_V1_Envelope(serializedBytes: body)
        } catch {
            lock.lock(); let timedOut = timedOutWaitingFor; lock.unlock()
            if timedOut != nil { throw DaemonDriverError.timedOut(what, idleTimeout) }
            throw error
        }
    }

    func rawCall(id: UInt64, method: String, payload: Data) async -> Response {
        await Task.detached {
            var env = Star_V1_Envelope()
            env.id      = id
            env.kind    = .request
            env.method  = method
            env.payload = payload
            do {
                try self.writeEnvelope(env)
                let reply = try self.readEnvelope(waitingFor: method)
                switch reply.kind {
                case .response:   return .response(reply.payload)
                case .error:      return .error(reply.error, reply.errorCode)
                case .streamItem: return .streamItem(reply.payload)
                case .streamEnd:  return .streamEnd
                default:          return .error("unexpected kind \(reply.kind)", -1)
                }
            } catch {
                return .error("\(error)", -1)
            }
        }.value
    }

    func call<Req: Message, Resp: Message>(method: String, request: Req) async throws -> Resp {
        let id      = nextRequestID()
        let payload = try request.serializedData()
        let result  = await rawCall(id: id, method: method, payload: payload)
        switch result {
        case .response(let data):          return try Resp(serializedBytes: data)
        case .error(let msg, let code):    throw DaemonDriverError.remoteError(msg, code)
        default:                           throw DaemonDriverError.unexpectedShape
        }
    }

    /// What a server-streaming call sent: every item in order, and how it ended.
    struct StreamResult {
        var items: [Data] = []
        /// The daemon's message and code if the stream ended in an error; nil if it ended normally.
        var failure: (message: String, code: Int32)?
    }

    /// Calls a server-streaming method (`Session.OpenVideo`, `Export.Video`, ...) and collects the
    /// stream until the daemon ends it, one way or the other.  Notifications the daemon volunteers
    /// (warnings) are not part of any call's stream and are skipped.
    func stream<Req: Message>(method: String, request: Req) async throws -> StreamResult {
        let id = nextRequestID()
        var env = Star_V1_Envelope()
        env.id      = id
        env.kind    = .request
        env.method  = method
        env.payload = try request.serializedData()
        let sent = env

        return await Task.detached {
            var result = StreamResult()
            do {
                try self.writeEnvelope(sent)
                while true {
                    let reply = try self.readEnvelope(waitingFor: sent.method)
                    switch reply.kind {
                    case .streamItem:
                        result.items.append(reply.payload)
                    case .streamEnd:
                        return result
                    case .response:
                        result.items.append(reply.payload)
                        return result
                    case .error:
                        result.failure = (reply.error, reply.errorCode)
                        return result
                    default:
                        continue
                    }
                }
            } catch {
                result.failure = ("\(error)", -1)
                return result
            }
        }.value
    }

    enum DaemonDriverError: Error, CustomStringConvertible {
        case eof
        /// The daemon sent nothing for this long, while this call waited on it.
        case timedOut(String, TimeInterval)
        case remoteError(String, Int32)
        case unexpectedShape

        var description: String {
            switch self {
            case .eof: return "the daemon closed its output (it exited or crashed)"
            case .timedOut(let what, let seconds): return "timed out after \(seconds)s waiting for \(what); the daemon was killed"
            case .remoteError(let message, let code): return "remoteError(\(message), \(code))"
            case .unexpectedShape: return "unexpectedShape"
            }
        }
    }
}
