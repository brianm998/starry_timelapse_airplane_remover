import Foundation
import CoreGraphics
import Cocoa
import SwiftUI

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

public enum FrameProcessingState: Int,
                                  CaseIterable,
                                  Codable,
                                  Sendable,
                                  Identifiable
{
    public var id: Self { self }
    
    case unprocessed
    case horizonDetection
    case starAlignment    
    case creatingAlignedFrame    
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

    public var message: String {
        switch self {
        case .unprocessed:
            return "unprocessed"
        case .horizonDetection:
            return "finding horizon"
        case .starAlignment:
            return "aligning stars"
        case .creatingAlignedFrame:
            return "creating aligned frame"
        case .subtractingNeighbor:
            return "subtracting aligned stars"
        case .assemblingPixels:
            return "assembling pixels"
        case .sortingPixels:
            return "sorting pixels"
        case .detectingBlobs:
            return "detecting blobs"

        case .filter1:
            return "filter 1"
        case .filter2:
            return "filter 2"
        case .filter3:
            return "filter 3"
        case .filter4:
            return "filter 4"
        case .filter5:
            return "filter 5"
        case .filter6:
            return "filter 6"
        case .filter7:
            return "filter 7"
        case .filter8:
            return "filter 8"
            
        case .firstClassification:
            return "first classification"

        case .readyForInterFrameProcessing: // XXX not covered in progress monitor
            return "ready for inter frame processing"
        case .secondClassification:
            return "second classification"
        case .outlierProcessingComplete:
            return "ready to finish"
        case .finishing:
            return "finishing"
        case .userModified:
            return "classified"

            // XXX what happens here ???
            
        case .writingOutlierValues:
            return "writing classification values"
        case .waitingToLoadImages:
            return "waiting to load images"
        case .loadingImages:
            return "loading images"
        case .loadingImages1:
            return "loading images 1"
        case .creatingRemovalMask:
            return "creating paint mask"
        case .assemblingProcessedFrame:
            return "calculating processed frame"
        case .writingOutputFile:
            return "writing to disk"
        case .complete:
            return "complete"
        }
    }

    public var isReadyForInterframeProcessing: Bool {
        switch self {
        case .unprocessed:
            return false
        case .horizonDetection:
            return false
        case .starAlignment:
            return false
        case .creatingAlignedFrame:
            return false
        case .subtractingNeighbor:
            return false
        case .assemblingPixels:
            return false
        case .sortingPixels:
            return false
        case .detectingBlobs:
            return false
        case .filter1:
            return false
        case .filter2:
            return false
        case .filter3:
            return false
        case .filter4:
            return false
        case .filter5:
            return false
        case .filter6:
            return false
        case .filter7:
            return false
        case .filter8:
            return false
        case .firstClassification:
            return false
        case .readyForInterFrameProcessing:
            return true
        case .secondClassification:
            return true
        case .outlierProcessingComplete:
            return true
        case .finishing:
            return true
        case .writingOutlierValues:
            return true
        case .userModified:
            return true
        case .waitingToLoadImages:
            return true
        case .loadingImages:
            return true
        case .loadingImages1:
            return true
        case .creatingRemovalMask:
            return true
        case .assemblingProcessedFrame:
            return true
        case .writingOutputFile:
            return true
        case .complete:
            return true
        }
    }

    public var shortString: String {
        switch self {
        case .unprocessed:
            return "unprocessed"
        case .horizonDetection:
            return "horizon"
        case .starAlignment:
            return "align"
        case .creatingAlignedFrame:
            return "combine align"
        case .subtractingNeighbor:
            return "subtract"
        case .assemblingPixels:
            return "assemble"
        case .sortingPixels:
            return "sorting"
        case .detectingBlobs:
            return "blob detection"
        case .filter1:
            return "filter 1"
        case .filter2:
            return "filter 2"
        case .filter3:
            return "filter 3"
        case .filter4:
            return "filter 4"
        case .filter5:
            return "filter 5"
        case .filter6:
            return "filter 6"
        case .filter7:
            return "filter 7"
        case .filter8:
            return "filter 8"
        case .firstClassification:
            return "class 1"
        case .readyForInterFrameProcessing:
            return "inter"
        case .secondClassification:
            return "class 2"
        case .outlierProcessingComplete:
            return "ready to finish"
        case .finishing:
            return "finishing"
        case .writingOutlierValues:
            return "write values"
        case .userModified:
            return "classified"
        case .waitingToLoadImages:
            return "waiting to load"
        case .loadingImages:
            return "loading 1"
        case .loadingImages1:
            return "loading 2"
        case .creatingRemovalMask:
            return "paint mask"
        case .assemblingProcessedFrame:
            return "painting"
        case .writingOutputFile:
            return "writing"
        case .complete:
            return ""
        }
    }
    public var color: Color {
        switch self {
        case .unprocessed:
            return .red
        case .horizonDetection:
            return .blue
        case .starAlignment:
            return .yellow
        case .creatingAlignedFrame:
            return .cyan
        case .subtractingNeighbor:
            return .orange
        case .assemblingPixels:
            return .blue
        case .sortingPixels:
            return .cyan
        case .detectingBlobs:
            return .yellow
        case .filter1:
            return .yellow
        case .filter2:
            return .yellow
        case .filter3:
            return .yellow
        case .filter4:
            return .yellow
        case .filter5:
            return .yellow
        case .filter6:
            return .yellow
        case .filter7:
            return .yellow
        case .filter8:
            return .yellow
        case .firstClassification:
            return .yellow
        case .readyForInterFrameProcessing:
            return .yellow
        case .secondClassification:
            return .yellow
        case .outlierProcessingComplete:
            return .yellow
        case .finishing:
            return .yellow
        case .writingOutlierValues:
            return .yellow
        case .userModified:
            return .yellow
        case .waitingToLoadImages:
            return .yellow
        case .loadingImages:
            return .yellow
        case .loadingImages1:
            return .yellow
        case .creatingRemovalMask:
            return .yellow
        case .assemblingProcessedFrame:
            return .yellow
        case .writingOutputFile:
            return .yellow
        case .complete:
            return .green
        }
    }
}

