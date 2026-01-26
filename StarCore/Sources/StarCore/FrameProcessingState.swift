import Foundation
import CoreGraphics
import Cocoa
import SwiftUI
import kht_bridge

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
        @unknown default:
            return nil
        }
    }
    
    case start
    case baseKeypointDetection
    case baseKeypointDetectionComplete
    case neighborKeypointDetection(Int)
    case neighborKeypointMatch(Int)
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

public enum SequenceProcessingState: Codable,
                                     Hashable,
                                     Sendable,
                                     Identifiable
{
    public var id: Self { self }

    case unprocessed
    case horizonDetection
    case firstAlignment
    case secondAlignment
    case done
    case error(String)
}

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
        .earthKeypoints,
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
    
    public var message: String {
        switch self {
        case .unprocessed:
            "unprocessed"
        case .horizonDetection:
            "finding horizon"
        case .mergingHorizon:
            "merging horizon"
        case .horizonDetected:
            "horizon found"
        case .starKeypoints:
            "star keypoints"
        case .earthKeypoints:
            "earth keypoints"
        case .starAlignment(let state):
            "aligning stars \(state)"
        case .earthAlignment(let state):
            "aligning earth \(state)"
        case .starAlignmentFailed:
            "star alignment failed"
        case .creatingStarAlignedFrame:
            "creating star aligned frame"
        case .creatingEarthAlignedFrame:
            "creating earth aligned frame"
        case .subtractingNeighbor:
            "subtracting aligned stars"
        case .assemblingPixels:
            "assembling pixels"
        case .sortingPixels:
            "sorting pixels"
        case .detectingBlobs:
            "detecting blobs"

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
            "first classification"

        case .readyForInterFrameProcessing: // XXX not covered in progress monitor
            "ready for inter frame processing"
        case .secondClassification:
            "second classification"
        case .outlierProcessingComplete:
            "ready to finish"
        case .finishing:
            "finishing"
        case .userModified:
            "classified"

            // XXX what happens here ???
            
        case .writingOutlierValues:
            "writing classification values"
        case .waitingToLoadImages:
            "waiting to load images"
        case .loadingImages:
            "loading images"
        case .loadingImages1:
            "loading images 1"
        case .creatingRemovalMask:
            "creating removal mask"
        case .assemblingProcessedFrame:
            "calculating processed frame"
        case .writingOutputFile:
            "writing to disk"
        case .complete:
            "complete"
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
        case .starAlignment(let state):
            "star align \(state)"
        case .earthAlignment(let state):
            "earth align \(state)"
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
        case .earthKeypoints:
            .orange
        case .starAlignment:
            .yellow
        case .earthAlignment:
            .cyan
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
}

