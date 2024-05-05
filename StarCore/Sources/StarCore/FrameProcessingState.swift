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

public enum LoopReturn {
    case `continue`
    case `break`
}

public enum FrameProcessingState: Int, CaseIterable, Codable {
    case unprocessed
    case starAlignment    
    case loadingImages    
    case subtractingNeighbor
    case findingLines
    case initialDimIsolatedRemoval
    case assemblingPixels
    case sortingPixels
    case detectingBlobs
    case isolatedBlobRemoval
    case aligningBlobsWithLines
    case smallDimBlobRemobal
    case finalIsolatedBlobRemoval
    case finalDimBlobRemoval
    case populatingOutlierGroups
    case readyForInterFrameProcessing
    case interFrameProcessing
    case outlierProcessingComplete
    // XXX add gui check step?

    case writingBinaryOutliers
    case writingOutlierValues
    
    case reloadingImages
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
        case .loadingImages:
            return"loading images"
        case .subtractingNeighbor:
            return "subtracting aligned neighbor frame"
        case .findingLines:
            return "finding lines"
        case .initialDimIsolatedRemoval:
            return "dim blob removal"
        case .assemblingPixels:
            return "assembling pixels"
        case .sortingPixels:
            return "sorting pixels"
        case .detectingBlobs:
            return "detecting blobs"
        case .isolatedBlobRemoval:
            return "initial isolated blob removal"
        case .aligningBlobsWithLines:
            return "aligning blobs with lines"
        case .smallDimBlobRemobal:
            return "small dim blob removal"
        case .finalIsolatedBlobRemoval:
            return "final isolated blob removal"
        case .finalDimBlobRemoval:
            return "final dim blob removal"
        case .populatingOutlierGroups:
            return "populating outlier groups"
        case .readyForInterFrameProcessing: // XXX not covered in progress monitor
            return "ready for inter frame processing"
        case .interFrameProcessing:
            return "classifing outlier groups"
        case .outlierProcessingComplete:
            return "ready to finish"
        case .writingBinaryOutliers:
            return "writing raw outlier data"
        case .writingOutlierValues:
            return "writing outlier classification values"
        case .reloadingImages:
            return "reloadingImages"
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

