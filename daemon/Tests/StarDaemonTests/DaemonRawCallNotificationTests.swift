import XCTest
import Foundation
import StarDaemonMessages
import SwiftProtobuf

/// stard volunteers warning notifications at any time.  rawCall used to take the first envelope as
/// the reply, so one arriving before it failed the call with "unexpected kind notification" (ticket #224).
final class DaemonRawCallNotificationTests: XCTestCase {

    func testRawCallSkipsANotificationBeforeTheReply() async throws {
        var notification = Star_V1_Envelope()
        notification.kind   = .notification
        notification.method = "Star.Warning"
        var reply = Star_V1_Envelope()
        reply.id      = 1
        reply.kind    = .response
        reply.payload = Data([1, 2, 3])

        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("rawcall-notification-\(arc4random()).bin")
        var bytes = Data()
        for env in [notification, reply] { bytes.append(encodeFrame(try env.serializedData())) }
        try bytes.write(to: fixture)
        defer { try? FileManager.default.removeItem(at: fixture) }

        // A stand-in daemon: replays the two frames, then stays up (stdin open) until terminated.
        let daemon = try DaemonProcess(binaryPath: "/bin/sh", scratchDir: "",
                                       arguments: ["-c", "cat \"$0\"; sleep 30", fixture.path], idleTimeout: 10)
        defer { daemon.terminate() }

        let result = await daemon.rawCall(id: 1, method: "Daemon.Hello", payload: Data())
        guard case .response(let payload) = result else { return XCTFail("expected the response, got \(result)") }
        XCTAssertEqual(payload, Data([1, 2, 3]))
    }
}
