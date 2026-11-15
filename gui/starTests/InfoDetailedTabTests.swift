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
        let stages = ["horizon", "neighbors", "aligned", "condensed", "subtraction",
                      "blobs", "blob_processing", "classification", "removal_mask", "final"]
        XCTAssertEqual(InfoType.detailedSections.map { $0.titleKey }, stages.map { "ui.info_detailed_\($0)_title" })
        XCTAssertEqual(InfoType.detailedSections.map { $0.bodyKey }, stages.map { "ui.info_detailed_\($0)_body" })
        XCTAssertEqual(InfoType.detailedSections.map { $0.art },
                       [.stageHorizon, .stageNeighbors, .stageAligned, .stageCondensed, .stageSubtraction,
                        .stageBlobs, .stageBlobProcessing, .stageClassification, .stageRemovalMask, .stageFinal])
        XCTAssertEqual(InfoType.detailedOpeningKey, "ui.info_detailed_intro")
        XCTAssertEqual(InfoType.detailedClosingKey, "ui.info_detailed_closing")
        XCTAssertEqual(InfoType.detailedClosing.count, 2)
        XCTAssertEqual(InfoType.detailed.infoText, InfoType.detailedText)
    }

    /// Every key the tab reads is in the catalogue, in every language, and none of the typos survives in English.
    func testDetailedKeysAreInEveryLanguage() {
        let keys = [InfoType.detailedOpeningKey, InfoType.detailedClosingKey]
            + InfoType.detailedSections.flatMap { [$0.titleKey, $0.bodyKey] }
        XCTAssertEqual(keys.count, 22)
        for key in keys {
            XCTAssertNotEqual(localized(key), key, "\(key) is missing")
        }
        let english = InfoType.detailedText
        for typo in ["neibhgoring", "procssed", "processd", "significally", " is is ", "brighest", "take while", "composts", "neighor"] {
            XCTAssertFalse(english.contains(typo), typo)
        }
    }
}
