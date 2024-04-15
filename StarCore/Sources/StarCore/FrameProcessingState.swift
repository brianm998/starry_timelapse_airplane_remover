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
    case detectingOutliers1
    case detectingOutliers2
    case detectingOutliers2a
    case detectingOutliers2aa
    case detectingOutliers2b
    case detectingOutliers2c
    case detectingOutliers2d
    case detectingOutliers2e
    case detectingOutliers3
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
        case .detectingOutliers1:
            return "finding lines"
        case .detectingOutliers2:
            return "detecting blobs"
        case .detectingOutliers2a:
            return "initial isolated blob removal"
        case .detectingOutliers2aa:
            return "aligning blobs with lines"
        case .detectingOutliers2b:
            return "blob absorber"
        case .detectingOutliers2c:
            return "blob extender"
        case .detectingOutliers2d:
            return "blob smasher"
        case .detectingOutliers2e:
            return "final isolated blob removal"
        case .detectingOutliers3:
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

