import XCTest
import StarCore
import StarCppBridge
import StarDaemonMessages
@testable import stard

/// The outlier stage reads the detection strength from the global `constants`, which was set when
/// a session opened and never again, so changing Detection Strength in the settings had no effect
/// on the frames still to be processed until the sequence was reopened.
final class UpdateConfigDetectionTypeTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("UpdateConfigDetectionTypeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await constants.set(detectionType: .strong)
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func makeSession() async throws -> Session {
        let dir = scratch.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let width = 4, height = 4
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for i in 0..<(width * height) { data[i] = UInt8(i * 7 % 256) }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                             bytesPerRow: width,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)
        mat.write(to: dir.appendingPathComponent("frame0.tif").path)

        let sequence = try ImageSequence(dirname: dir.path, supportedImageFileTypes: [".tif", ".tiff"])
        let info = try await sequence.getImageInfo()
        let sessionDir = scratch.appendingPathComponent("session").path
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let configManager = await MainActor.run {
            ConfigManager(configFilename: "\(sessionDir)/config.json", config: Config())
        }
        return Session(sessionID: "s", scratchSessionDir: sessionDir,
                       configJsonPath: "\(sessionDir)/config.json",
                       configManager: configManager, imageSequence: sequence, imageInfo: info)
    }

    func testChangingTheDetectionStrengthReachesTheOutlierStageAtOnce() async throws {
        let session = try await makeSession()
        await constants.set(detectionType: .strong)

        var proto = Mapping.protoConfig(await session.config())
        proto.detectionType = Mapping.protoDetectionType(.mild)
        let updated = await session.updateConfig(from: proto)

        XCTAssertEqual(updated.detectionType, .mild)
        let live = await constants.getDetectionType()
        XCTAssertEqual(live, .mild, "the stored config changed but the outlier stage still reads the old strength")

        proto.detectionType = Mapping.protoDetectionType(.strong)
        _ = await session.updateConfig(from: proto)
        let back = await constants.getDetectionType()
        XCTAssertEqual(back, .strong)
    }
}
