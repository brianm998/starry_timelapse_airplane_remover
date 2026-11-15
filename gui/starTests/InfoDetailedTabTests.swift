import XCTest
import AVFoundation
import CryptoKit
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star



/// The Detailed tab is ten sections, each followed by its stage picture.
final class InfoDetailedTabTests: XCTestCase {
    func testDetailedSections() {
        XCTAssertEqual(InfoType.detailedSections.map { $0.heading },
                       ["Identify the horizon, if desired.", "Identify a set of neighbor frames.",
                        "Align the neighbor frames for sky and maybe earth too.", "Condense the aligned neighbor frames.",
                        "Subtract the aligned neighbor frame.", "Detect Blobs", "Blob Processing",
                        "Outlier Group classification.", "Removal Mask Creation.", "Final Bad Pixel Removal"])
        XCTAssertEqual(InfoType.detailedSections.map { $0.art },
                       [.stageHorizon, .stageNeighbors, .stageAligned, .stageCondensed, .stageSubtraction,
                        .stageBlobs, .stageBlobProcessing, .stageClassification, .stageRemovalMask, .stageFinal])
        // The words, joined, are the text the tab always had (SHA-256 of that text).
        XCTAssertEqual(InfoType.detailed.infoText, InfoType.detailedText)
        XCTAssertEqual(sha256Hex(InfoType.detailedText),
                       "70fc99140e013d953d1e697a787d5e2873346e33ea5e9256def671b723af5d12")
    }

    private func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
