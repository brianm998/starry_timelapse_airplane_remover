import Foundation
import CoreGraphics
import Cocoa

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
    case isolatedBlobRemoval1
    case isolatedBlobRemoval2
    case isolatedBlobRemoval3
    case isolatedBlobRemoval4
    case smallLinearBlobAbsorbtion
    case largerLinearBlobAbsorbtion
    case finalCrunch
    case populatingOutlierGroups
    case readyForInterFrameProcessing
    case interFrameProcessing
    case outlierProcessingComplete
    case finishing
    // XXX add gui check step?

    case writingOutlierValues
    
    case loadingImages
    case loadingImages1
    case painting
    case painting2
    case writingOutputFile
    case complete

    var message: String {
        switch self {
        case .unprocessed:
            return ""
        case .starAlignment:
            return "aligning stars"
        case .subtractingNeighbor:
            return "subtracting aligned neighbor frame"
        case .assemblingPixels:
            return "assembling pixels"
        case .sortingPixels:
            return "sorting pixels"
        case .detectingBlobs:
            return "detecting blobs"
        case .isolatedBlobRemoval1:
            return "isolated blob removal phase 1"
        case .isolatedBlobRemoval2:
            return "isolated blob removal phase 2"
        case .isolatedBlobRemoval3:
            return "isolated blob removal phase 3"
        case .isolatedBlobRemoval4:
            return "isolated blob removal phase 4"
        case .smallLinearBlobAbsorbtion:
            return "small linear blob absorbtion"
        case .largerLinearBlobAbsorbtion:
            return "larger linear blob absorbtion"
        case .finalCrunch:
            return "final crunch"
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
        case .writingOutlierValues:
            return "writing outlier classification values"
        case .loadingImages:
            return "loading images"
        case .loadingImages1:
            return "loading images 1"
        case .painting:
            return "creating paint mask"
        case .painting2:
            return "painting"
        case .writingOutputFile:
            return "frames writing to disk"
        case .complete:
            return "frames complete"
        }
    }
}

