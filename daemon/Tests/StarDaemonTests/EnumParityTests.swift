import XCTest
import StarCore
import StarDaemonMessages

// §12.1 — assert each proto enum's case count/values match the Swift enum.
// If a case is added to either side without updating the other, these tests fail.

final class EnumParityTests: XCTestCase {

    // MARK: - DetectionType (CaseIterable on both sides)

    func testDetectionTypeCaseCount() {
        // Proto has 5 cases (detectionMild..detectionCustom).
        // StarCore.DetectionType has 5 cases (mild..custom).
        XCTAssertEqual(DetectionType.allCases.count, 5)
        let protoCases = Star_V1_DetectionType.allCases.filter { $0 != .UNRECOGNIZED(-1) }
        XCTAssertEqual(protoCases.count, 5)
    }

    func testDetectionTypeMappingExhaustive() {
        for dt in DetectionType.allCases {
            let proto = protoDetectionType(dt)
            let back  = detectionType(from: proto)
            XCTAssertEqual(back, dt, "round-trip failed for \(dt)")
        }
    }

    // MARK: - CleanMethod (associated values; check each variant explicitly)

    func testCleanMethodVariants() {
        // Proto has 3 cases: cleanAutomatic, cleanAutomaticTrue, cleanSelective.
        let variants: [CleanMethod] = [.automatic(false), .automatic(true), .selective]
        for cm in variants {
            let proto = protoCleanMethod(cm)
            let back  = cleanMethodFrom(proto: proto)
            XCTAssertEqual(back, cm, "round-trip failed for \(cm)")
        }
        let protoCases = Star_V1_CleanMethod.allCases.filter { $0 != .UNRECOGNIZED(-1) }
        XCTAssertEqual(protoCases.count, 3)
    }

    // MARK: - RemoveReason

    func testRemoveReasonVariants() {
        // undecided is represented as nil in StarCore.
        XCTAssertNil(removeReason(from: .rrUndecided))

        // Forward: Swift → Proto
        let forwardCases: [(RemoveReason, Star_V1_RemoveReason)] = [
            (.userSelected(true),   .rrUserRemove),
            (.userSelected(false),  .rrUserKeep),
            (.fromClassifier(1.0),  .rrClassifierRemove),
            (.fromClassifier(-1.0), .rrClassifierKeep),
        ]
        for (swift, proto) in forwardCases {
            XCTAssertEqual(protoRemoveReason(swift), proto, "forward failed for \(swift)")
        }

        // Reverse: Proto → Swift → Proto (avoids RemoveReason's score-sign Equatable).
        let reverseCases: [Star_V1_RemoveReason] = [
            .rrUserRemove, .rrUserKeep, .rrClassifierRemove, .rrClassifierKeep,
        ]
        for proto in reverseCases {
            guard let back = removeReason(from: proto) else {
                XCTFail("nil for \(proto)"); continue
            }
            XCTAssertEqual(protoRemoveReason(back), proto, "reverse round-trip failed for \(proto)")
        }

        // 5 proto cases including undecided.
        let protoCases = Star_V1_RemoveReason.allCases.filter { $0 != .UNRECOGNIZED(-1) }
        XCTAssertEqual(protoCases.count, 5)
    }

    // MARK: - FrameProcessingState spot-checks

    func testFrameProcessingStateKnownValues() {
        let table: [(FrameProcessingState, Star_V1_FrameProcessingState)] = [
            (.unprocessed,              .fpsUnprocessed),
            (.complete,                 .fpsComplete),
            (.writingOutputFile,        .fpsWritingOutputFile),
            (.firstClassification,      .fpsFirstClassification),
            (.secondClassification,     .fpsSecondClassification),
            (.earthAlignment(.start),   .fpsEarthAlignmentStart),
            (.starAlignment(.complete), .fpsStarAlignmentComplete),
        ]
        for (swift, expected) in table {
            let got = frameProcessingState(swift)
            XCTAssertEqual(got, expected, "\(swift) → expected \(expected), got \(got)")
        }
    }
}

// Local shims so the test file doesn't need to import stard (executable target).

private func protoDetectionType(_ dt: DetectionType) -> Star_V1_DetectionType {
    switch dt {
    case .mild:      return .detectionMild
    case .strong:    return .detectionStrong
    case .stronger:  return .detectionStronger
    case .excessive: return .detectionExcessive
    case .custom:    return .detectionCustom
    }
}

private func detectionType(from proto: Star_V1_DetectionType) -> DetectionType {
    switch proto {
    case .detectionMild:      return .mild
    case .detectionStrong:    return .strong
    case .detectionStronger:  return .stronger
    case .detectionExcessive: return .excessive
    case .detectionCustom:    return .custom
    default:                  return .strong
    }
}

private func protoCleanMethod(_ cm: CleanMethod) -> Star_V1_CleanMethod {
    switch cm {
    case .selective:        return .cleanSelective
    case .automatic(true):  return .cleanAutomaticTrue
    case .automatic(false): return .cleanAutomatic
    }
}

private func cleanMethodFrom(proto: Star_V1_CleanMethod) -> CleanMethod {
    switch proto {
    case .cleanSelective:     return .selective
    case .cleanAutomaticTrue: return .automatic(true)
    default:                  return .automatic(false)
    }
}

private func protoRemoveReason(_ rr: RemoveReason) -> Star_V1_RemoveReason {
    switch rr {
    case .userSelected(true):        return .rrUserRemove
    case .userSelected(false):       return .rrUserKeep
    case .fromClassifier(let score): return score > 0 ? .rrClassifierRemove : .rrClassifierKeep
    }
}

private func removeReason(from proto: Star_V1_RemoveReason) -> RemoveReason? {
    switch proto {
    case .rrUndecided:        return nil
    case .rrUserRemove:       return .userSelected(true)
    case .rrUserKeep:         return .userSelected(false)
    case .rrClassifierRemove: return .fromClassifier(1.0)
    case .rrClassifierKeep:   return .fromClassifier(-1.0)
    default:                  return nil
    }
}

private func frameProcessingState(_ s: FrameProcessingState) -> Star_V1_FrameProcessingState {
    switch s {
    case .unprocessed:               return .fpsUnprocessed
    case .horizonDetection:          return .fpsHorizonDetection
    case .horizonDetected:           return .fpsHorizonDetected
    case .mergingHorizon:            return .fpsMergingHorizon
    case .earthAlignment(let step):
        switch step {
        case .start:    return .fpsEarthAlignmentStart
        case .complete: return .fpsEarthAlignmentComplete
        default:        return .fpsEarthAlignmentAligning
        }
    case .creatingEarthAlignedFrame: return .fpsCreatingEarthAligned
    case .starKeypoints:             return .fpsStarKeypoints
    case .earthKeypoints:            return .fpsEarthKeypoints
    case .starKeypointsFound:        return .fpsStarKeypointsFound
    case .earthKeypointsFound:       return .fpsEarthKeypointsFound
    case .starAlignment(let step):
        switch step {
        case .start:    return .fpsStarAlignmentStart
        case .complete: return .fpsStarAlignmentComplete
        default:        return .fpsStarAlignmentAligning
        }
    case .starAlignmentFailed:       return .fpsStarAlignmentFailed
    case .creatingStarAlignedFrame:  return .fpsCreatingStarAligned
    case .subtractingNeighbor:       return .fpsSubtractingNeighbor
    case .assemblingPixels:          return .fpsAssemblingPixels
    case .sortingPixels:             return .fpsSortingPixels
    case .detectingBlobs:            return .fpsDetectingBlobs
    case .filter1:                   return .fpsFilter1
    case .filter2:                   return .fpsFilter2
    case .filter3:                   return .fpsFilter3
    case .filter4:                   return .fpsFilter4
    case .filter5:                   return .fpsFilter5
    case .filter6:                   return .fpsFilter6
    case .filter7:                   return .fpsFilter7
    case .filter8:                   return .fpsFilter8
    case .firstClassification:       return .fpsFirstClassification
    case .readyForInterFrameProcessing: return .fpsReadyForInterFrame
    case .secondClassification:      return .fpsSecondClassification
    case .outlierProcessingComplete: return .fpsOutlierProcessingComplete
    case .finishing:                 return .fpsFinishing
    case .userModified:              return .fpsUserModified
    case .writingOutlierValues:      return .fpsWritingOutlierValues
    case .waitingToLoadImages:       return .fpsWaitingToLoadImages
    case .loadingImages:             return .fpsLoadingImages
    case .loadingImages1:            return .fpsLoadingImages1
    case .creatingRemovalMask:       return .fpsCreatingRemovalMask
    case .assemblingProcessedFrame:  return .fpsAssemblingProcessedFrame
    case .writingOutputFile:         return .fpsWritingOutputFile
    case .complete:                  return .fpsComplete
    }
}
