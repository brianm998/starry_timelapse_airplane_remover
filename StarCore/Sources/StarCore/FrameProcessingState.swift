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
                                  Sendable
{
    case unprocessed
    case starAlignment    
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
    case filter9
    case filter10
    case filter11
    case filter12
    case filter13
    case filter14
    case filter15
    case filter16
    
    case populatingOutlierGroups
    case readyForInterFrameProcessing
    case interFrameProcessing
    case outlierProcessingComplete
    case finishing

    case userModified

    case writingOutlierValues
    
    case waitingToLoadImages
    case loadingImages
    case loadingImages1
    case painting
    case painting2
    case writingOutputFile
    case complete

    public var message: String {
        switch self {
        case .unprocessed:
            return "unprocessed"
        case .starAlignment:
            return "aligning stars"
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
        case .filter9:
            return "filter 9"
        case .filter10:
            return "filter 10"
        case .filter11:
            return "filter 11"
        case .filter12:
            return "filter 12"
        case .filter13:
            return "filter 13"
        case .filter14:
            return "filter 14"
        case .filter15:
            return "filter 15"
        case .filter16:
            return "filter 16"
            
        case .populatingOutlierGroups:
            return "populating outlier groups"
        case .readyForInterFrameProcessing: // XXX not covered in progress monitor
            return "ready for inter frame processing"
        case .interFrameProcessing:
            return "classifing outlier groups"
        case .outlierProcessingComplete:
            return "ready to finish"
        case .finishing:
            return "finishing"
        case .userModified:
            return "classified"
        case .writingOutlierValues:
            return "writing outlier classification values"
        case .waitingToLoadImages:
            return "waiting to load images"
        case .loadingImages:
            return "loading images"
        case .loadingImages1:
            return "loading images 1"
        case .painting:
            return "creating paint mask"
        case .painting2:
            return "painting"
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
        case .starAlignment:
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
        case .filter9:
            return false
        case .filter10:
            return false
        case .filter11:
            return false
        case .filter12:
            return false
        case .filter13:
            return false
        case .filter14:
            return false
        case .filter15:
            return false
        case .filter16:
            return false
        case .populatingOutlierGroups:
            return false
        case .readyForInterFrameProcessing:
            return true
        case .interFrameProcessing:
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
        case .painting:
            return true
        case .painting2:
            return true
        case .writingOutputFile:
            return true
        case .complete:
            return true
        }
    }

    public var color: Color {
        switch self {
        case .unprocessed:
            return .red
        case .starAlignment:
            return .yellow
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
        case .filter9:
            return .yellow
        case .filter10:
            return .yellow
        case .filter11:
            return .yellow
        case .filter12:
            return .yellow
        case .filter13:
            return .yellow
        case .filter14:
            return .yellow
        case .filter15:
            return .yellow
        case .filter16:
            return .yellow
        case .populatingOutlierGroups:
            return .yellow
        case .readyForInterFrameProcessing:
            return .yellow
        case .interFrameProcessing:
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
        case .painting:
            return .yellow
        case .painting2:
            return .yellow
        case .writingOutputFile:
            return .yellow
        case .complete:
            return .green
        }
    }
}

