import Foundation
import StarCppBridge
#if canImport(SwiftUI)
import SwiftUI
#endif

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// this class holds the logic for removing airplanes from a single frame

// the first pass is done upon init, finding and pruning outlier groups

public enum LoopReturn: Sendable {
    case `continue`
    case `break`
}

public enum AlignmentStep: Equatable,
                           Hashable,
                           Codable,
                           Sendable,
                           Identifiable,
                           CustomStringConvertible
{
    public var id: Self { self }

    public init?(from objcAlignmentStep: ObjCAlignmentStep, neighborNumber: Int = 0) {
        switch objcAlignmentStep {
        case .start:
            self = .start
        case .baseKeypointDetection:
            self = .baseKeypointDetection
        case .baseKeypointDetectionComplete:
            self = .baseKeypointDetectionComplete
        case .neighborKeypointDetection:
            self = .neighborKeypointDetection(neighborNumber)
        case .neighborKeypointMatch:
            self = .neighborKeypointMatch(neighborNumber)
        case .aligningNeighbor:
            self = .aligningNeighbor(neighborNumber)
        case .loadingNeighbor:
            self = .loadingNeighbor(neighborNumber)
        case .complete:
            self = .complete
        default:
            return nil
        }
    }
    
    case start
    case baseKeypointDetection
    case baseKeypointDetectionComplete
    case neighborKeypointDetection(Int) // XXX obsolete now
    case neighborKeypointMatch(Int)     // XXX obsolete now
    case aligningNeighbor(Int) // neighbor index
    case loadingNeighbor(Int) // neighbor index
    case complete

    public var description: String {
        switch self {
        case .start:
            "start"
        case .baseKeypointDetection:
            "base detect"
        case .baseKeypointDetectionComplete:
            "base done"
        case .aligningNeighbor(let neighborIndex):
            "align #\(neighborIndex)"
        case .neighborKeypointDetection(let neighborIndex):
            "detect #\(neighborIndex)"
        case .neighborKeypointMatch(let neighborIndex):
            "match #\(neighborIndex)"
        case .loadingNeighbor(let neighborIndex):
            "load #\(neighborIndex)"
        case .complete:
            "complete"
        }
    }
}

// Proto mirror: Star_V1_FrameProcessingState in daemon/proto/star.proto — keep cases in sync.
public enum SequenceProcessingState: Codable,
                                     Hashable,
                                     Sendable,
                                     Identifiable
{
    public var id: Self { self }

    case unprocessed
    case horizonDetection
    case starKeypoints
    case earthKeypoints
    case firstAlignment
    case secondAlignment
    case done
    case error(String)
}

// Proto mirror: Star_V1_FrameProcessingState in daemon/proto/star.proto — keep cases in sync.
public enum FrameProcessingState: Codable,
                                  Hashable,
                                  Sendable,
                                  Identifiable
{
    public var id: Self { self }
    
    case unprocessed
    case horizonDetection
    case horizonDetected
    case mergingHorizon
    case earthAlignment(AlignmentStep)
    case creatingEarthAlignedFrame
    case starKeypoints
    case earthKeypoints
    case starKeypointsFound
    case earthKeypointsFound
    case starAlignment(AlignmentStep)
    case starAlignmentFailed
    case creatingStarAlignedFrame
    case subtractingNeighbor
    case assemblingPixels
    case sortingPixels
    case detectingBlobs

    case filter1
    case filter2
    case filter3
    case filter4
    case filter5
    case filter6
    case filter7
    case filter8
    
    case firstClassification

    case readyForInterFrameProcessing
    case secondClassification
    case outlierProcessingComplete
    case finishing

    case userModified

    case writingOutlierValues
    
    case waitingToLoadImages
    case loadingImages
    case loadingImages1
    case creatingRemovalMask
    case assemblingProcessedFrame
    case writingOutputFile
    case complete

    public static let allCases: [FrameProcessingState] =
      [
        .unprocessed,
        .horizonDetection,
        .horizonDetected,
        .mergingHorizon,
        .earthAlignment(.start),
        .creatingEarthAlignedFrame,
        .starKeypoints,
        .starKeypointsFound,
        .earthKeypoints,
        .earthKeypointsFound,
        .starAlignment(.start),
        .starAlignmentFailed,
        .creatingStarAlignedFrame,
        .subtractingNeighbor,
        .assemblingPixels,
        .sortingPixels,
        .detectingBlobs,

        .filter1,
        .filter2,
        .filter3,
        .filter4,
        .filter5,
        .filter6,
        .filter7,
        .filter8,
        
        .firstClassification,

        .readyForInterFrameProcessing,
        .secondClassification,
        .outlierProcessingComplete,
        .finishing,

        .userModified,

        .writingOutlierValues,

        .waitingToLoadImages,
        .loadingImages,
        .loadingImages1,
        .creatingRemovalMask,
        .assemblingProcessedFrame,
        .writingOutputFile,
        .complete
      ]
    
    /// The state in the words the user reads, in the language they read.
    ///
    /// Display only — the cli progress bars, the gui filmstrip and the gui frame label all
    /// show this. Nothing keys off it; `shortString` is what the updatable log dedups on, and
    /// that one stays English on purpose so a language change does not orphan a live log line.
    public var message: String {
        switch self {
        case .unprocessed:
            localized("frame_state.unprocessed")
        case .horizonDetection:
            localized("frame_state.horizon_detection")
        case .mergingHorizon:
            localized("frame_state.merging_horizon")
        case .horizonDetected:
            localized("frame_state.horizon_detected")
        case .starKeypoints:
            localized("frame_state.star_keypoints")
        case .earthKeypoints:
            localized("frame_state.earth_keypoints")
        case .starKeypointsFound:
            localized("frame_state.star_keypoints_found")
        case .earthKeypointsFound:
            localized("frame_state.earth_keypoints_found")
        case .starAlignment(let state):
            localized("frame_state.star_alignment", state)
        case .earthAlignment(let state):
            localized("frame_state.earth_alignment", state)
        case .starAlignmentFailed:
            localized("frame_state.star_alignment_failed")
        case .creatingStarAlignedFrame:
            localized("frame_state.creating_star_aligned_frame")
        case .creatingEarthAlignedFrame:
            localized("frame_state.creating_earth_aligned_frame")
        case .subtractingNeighbor:
            localized("frame_state.subtracting_neighbor")
        case .assemblingPixels:
            localized("frame_state.assembling_pixels")
        case .sortingPixels:
            localized("frame_state.sorting_pixels")
        case .detectingBlobs:
            localized("frame_state.detecting_blobs")
        case .filter1:
            localized("frame_state.filter", 1)
        case .filter2:
            localized("frame_state.filter", 2)
        case .filter3:
            localized("frame_state.filter", 3)
        case .filter4:
            localized("frame_state.filter", 4)
        case .filter5:
            localized("frame_state.filter", 5)
        case .filter6:
            localized("frame_state.filter", 6)
        case .filter7:
            localized("frame_state.filter", 7)
        case .filter8:
            localized("frame_state.filter", 8)
        case .firstClassification:
            localized("frame_state.first_classification")
        case .readyForInterFrameProcessing:
            localized("frame_state.ready_for_inter_frame_processing")
        case .secondClassification:
            localized("frame_state.second_classification")
        case .outlierProcessingComplete:
            localized("frame_state.outlier_processing_complete")
        case .finishing:
            localized("frame_state.finishing")
        case .userModified:
            localized("frame_state.user_modified")
        case .writingOutlierValues:
            localized("frame_state.writing_outlier_values")
        case .waitingToLoadImages:
            localized("frame_state.waiting_to_load_images")
        case .loadingImages:
            localized("frame_state.loading_images")
        case .loadingImages1:
            localized("frame_state.loading_images1")
        case .creatingRemovalMask:
            localized("frame_state.creating_removal_mask")
        case .assemblingProcessedFrame:
            localized("frame_state.assembling_processed_frame")
        case .writingOutputFile:
            localized("frame_state.writing_output_file")
        case .complete:
            localized("frame_state.complete")
        }
    }

    public var isReadyForInterframeProcessing: Bool {
        switch self {
        case .unprocessed:
            false
        case .horizonDetection:
            false
        case .mergingHorizon:
            false
        case .horizonDetected:
            false
        case .starKeypoints:
            false
        case .earthKeypoints:
            false
        case .starKeypointsFound:
            false
        case .earthKeypointsFound:
            false
        case .starAlignment:
            false
        case .earthAlignment:
            false
        case .starAlignmentFailed:
            false
        case .creatingStarAlignedFrame:
            false
        case .creatingEarthAlignedFrame:
            false
        case .subtractingNeighbor:
            false
        case .assemblingPixels:
            false
        case .sortingPixels:
            false
        case .detectingBlobs:
            false
        case .filter1:
            false
        case .filter2:
            false
        case .filter3:
            false
        case .filter4:
            false
        case .filter5:
            false
        case .filter6:
            false
        case .filter7:
            false
        case .filter8:
            false
        case .firstClassification:
            false
        case .readyForInterFrameProcessing:
            true
        case .secondClassification:
            true
        case .outlierProcessingComplete:
            true
        case .finishing:
            true
        case .writingOutlierValues:
            true
        case .userModified:
            true
        case .waitingToLoadImages:
            true
        case .loadingImages:
            true
        case .loadingImages1:
            true
        case .creatingRemovalMask:
            true
        case .assemblingProcessedFrame:
            true
        case .writingOutputFile:
            true
        case .complete:
            true
        }
    }

    public var shortString: String {
        switch self {
        case .unprocessed:
            "unprocessed"
        case .horizonDetection:
            "horizon"
        case .mergingHorizon:
            "horizon"
        case .horizonDetected:
            "horizon"
        case .starKeypoints:
            "star keypoints"
        case .earthKeypoints:
            "earth keypoints"
        case .starKeypointsFound:
            "found star keypoints"
        case .earthKeypointsFound:
            "found earth keypoints"
        case .starAlignment(let state):
            switch state {
            case .complete:
                "star aligned"
            default:
                "star align \(state)"
            }
        case .earthAlignment(let state):
            switch state {
            case .complete:
                "earth aligned"
            default:
                "earth align \(state)"
            }
        case .starAlignmentFailed:
            "star failed"
        case .creatingStarAlignedFrame:
            "combine star align"
        case .creatingEarthAlignedFrame:
            "combine earth align"
        case .subtractingNeighbor:
            "subtract"
        case .assemblingPixels:
            "assemble"
        case .sortingPixels:
            "sorting"
        case .detectingBlobs:
            "blob detection"
        case .filter1:
            "filter 1"
        case .filter2:
            "filter 2"
        case .filter3:
            "filter 3"
        case .filter4:
            "filter 4"
        case .filter5:
            "filter 5"
        case .filter6:
            "filter 6"
        case .filter7:
            "filter 7"
        case .filter8:
            "filter 8"
        case .firstClassification:
            "class 1"
        case .readyForInterFrameProcessing:
            "inter"
        case .secondClassification:
            "class 2"
        case .outlierProcessingComplete:
            "ready to finish"
        case .finishing:
            "finishing"
        case .writingOutlierValues:
            "write values"
        case .userModified:
            "classified"
        case .waitingToLoadImages:
            "waiting to load"
        case .loadingImages:
            "loading 1"
        case .loadingImages1:
            "loading 2"
        case .creatingRemovalMask:
            "removal mask"
        case .assemblingProcessedFrame:
            "removal"
        case .writingOutputFile:
            "writing"
        case .complete:
            ""
        }
    }
#if canImport(SwiftUI)
    public var color: Color {
        switch self {
        case .unprocessed:
            .red
        case .horizonDetection:
            .blue
        case .mergingHorizon:
            .cyan
        case .horizonDetected:
            .green
        case .starKeypoints:
            .orange
        case .starKeypointsFound:
            .green
        case .earthKeypoints:
            .orange
        case .earthKeypointsFound:
            .green
        case .starAlignment(let state):
            switch state {
            case .complete:
                .green
            default:
                .yellow
            }
        case .earthAlignment(let state):
            switch state {
            case .complete:
                .green
            default:
                .cyan
            }
        case .starAlignmentFailed:
            .orange
        case .creatingStarAlignedFrame:
            .cyan
        case .creatingEarthAlignedFrame:
            .purple
        case .subtractingNeighbor:
            .orange
        case .assemblingPixels:
            .blue
        case .sortingPixels:
            .cyan
        case .detectingBlobs:
            .yellow
        case .filter1:
            .yellow
        case .filter2:
            .yellow
        case .filter3:
            .yellow
        case .filter4:
            .yellow
        case .filter5:
            .yellow
        case .filter6:
            .yellow
        case .filter7:
            .yellow
        case .filter8:
            .yellow
        case .firstClassification:
            .yellow
        case .readyForInterFrameProcessing:
            .yellow
        case .secondClassification:
            .yellow
        case .outlierProcessingComplete:
            .yellow
        case .finishing:
            .yellow
        case .writingOutlierValues:
            .yellow
        case .userModified:
            .yellow
        case .waitingToLoadImages:
            .yellow
        case .loadingImages:
            .yellow
        case .loadingImages1:
            .yellow
        case .creatingRemovalMask:
            .yellow
        case .assemblingProcessedFrame:
            .yellow
        case .writingOutputFile:
            .yellow
        case .complete:
            .green
        }
    }
    #endif
}

