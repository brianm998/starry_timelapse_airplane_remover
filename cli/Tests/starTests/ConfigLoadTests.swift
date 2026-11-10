import XCTest
import ArgumentParser
import StarCore
@testable import star

/// `star <dir>/config.json` used to print a config load failure and then carry on with an
/// empty config, so the user saw an unrelated error about a folder they never named. The
/// load is now a throwing function whose error ends the run.
final class ConfigLoadTests: XCTestCase {

    private func tempFile(_ contents: String?) throws -> String {
        let dir = FileManager.default.temporaryDirectory
          .appendingPathComponent("ConfigLoadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.json").path
        if let contents { try contents.write(toFile: path, atomically: true, encoding: .utf8) }
        return path
    }

    func testInvalidConfigJsonThrowsWithItsPath() async throws {
        let path = try tempFile("{ this is not json")
        do {
            _ = try await loadSavedConfig(at: path)
            XCTFail("an unreadable config must throw")
        } catch {
            let text = "\(error)"
            XCTAssertTrue(text.contains(path), "error should name the file: \(text)")
            XCTAssertTrue(text.contains("DecodingError") || text.contains("dataCorrupted"),
                          "error should carry the decode failure: \(text)")
        }
    }

    func testMissingConfigThrowsWithItsPath() async throws {
        let path = try tempFile(nil)
        do {
            _ = try await loadSavedConfig(at: path)
            XCTFail("a missing config must throw")
        } catch {
            XCTAssertTrue("\(error)".contains(path))
        }
    }

    func testValidConfigLoads() async throws {
        let path = try tempFile(nil)
        var config = Config()
        config.detectionType = .strong
        config.writeJson(named: path, overwrite: true)
        let manager = try await loadSavedConfig(at: path)
        let loaded = await manager.config()
        XCTAssertEqual(loaded.detectionType, .strong)
    }
}
