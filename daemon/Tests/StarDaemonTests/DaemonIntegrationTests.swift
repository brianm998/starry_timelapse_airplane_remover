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

final class DaemonProcess: @unchecked Sendable {
    private let process: Process
    private let stdinPipe:  Pipe
    private let stdoutPipe: Pipe
    private var nextID: UInt64 = 1
    private let lock = NSLock()

    init(binaryPath: String, scratchDir: String) throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--scratch", scratchDir]
        stdinPipe  = Pipe()
        stdoutPipe = Pipe()
        process.standardInput  = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError  = FileHandle.standardError
        try process.run()
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
        stdinPipe.fileHandleForWriting.write(frame)
    }

    private func readEnvelope() throws -> Star_V1_Envelope {
        let handle = stdoutPipe.fileHandleForReading
        let headerData = handle.readData(ofLength: 4)
        guard headerData.count == 4 else { throw DaemonDriverError.eof }
        let len = headerData.reduce(0) { ($0 << 8) | Int($1) }
        let body = handle.readData(ofLength: len)
        guard body.count == len else { throw DaemonDriverError.eof }
        return try Star_V1_Envelope(serializedBytes: body)
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
                let reply = try self.readEnvelope()
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

    enum DaemonDriverError: Error {
        case eof
        case remoteError(String, Int32)
        case unexpectedShape
    }
}
