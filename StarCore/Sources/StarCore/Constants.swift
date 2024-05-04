import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/


public let constants = Constants()


public enum ProcessingState {
    case fast
    case normal
    case slow
}

public class Constants {

    var processingState: ProcessingState = .fast
    
    public func set(processingState: ProcessingState) {
        self.processingState = processingState
    }

    // pixels with less changed intensity than this cannot start blobs
    // lower values give more blobs
    public var blobberMinPixelIntensity: UInt16 {
        switch self.processingState {
        case .fast:
            return 10000        
        case .normal:
            return 5000
        case .slow:
            return 2000
        }
    }

    // blobs can grow until the get this much
    // darker than their seed pixel
    // larger values give more blobs
    public var blobberMinContrast: Double {
        switch self.processingState {
        case .fast:
            return 30         
        case .normal:
            return 50         // XXX test this
        case .slow:
            return 62
        }
    }

    // the size that blobs need to be smaller than for
    // blobberBrightMinIntensity to apply
    public var blobberBrightSmallSize: Int {
        switch self.processingState {
        case .fast:
            return 50           // XXX test this
        case .normal:
            return 30         // XXX test this
        case .slow:
            return 20
        }
    }

    // if a blob is smaller than blobberBrightSmallSize,
    // then discard it if it's median intensity is less than this
    public var blobberBrightMinIntensity: UInt16 {
        switch self.processingState {
        case .fast:
            return 8000           // XXX test this
        case .normal:
            return 4000         // XXX test this
        case .slow:
            return 3000
        }
    }
    
    // blobs smaller than this are ignored by the blobber
    // smaller values give more blobs
    public var blobberMinBlobSize: Int {
        switch self.processingState {
        case .fast:
            return 16           // XXX test this
        case .normal:
            return 8         // XXX test this
        case .slow:
            return 4
        }
    }

    // blobs with less median intensity than this are ignored
    public var blobberMinBlobIntensity: UInt16 {
        switch self.processingState {
        case .fast:
            return 4000         // XXX test this
        case .normal:
            return 3000         // XXX test this
        case .slow:
            return 2000
        }
    }
    
    // lines generated from the subtraction frame
    // that have fewer votes than this are ignored
    // larger values speed up processing and
    // decrease how many outlier groups are joined with lines
    public var khtMinLineVotes: Int {
        switch self.processingState {
        case .fast:
            return 6000        
        case .normal:
            return 3000         // XXX test this
        case .slow:
            return 2000
        }
    }

    // how far off of the end of the line do we look when doing KHT processing?
    public var khtLineExtensionAmount: Int {
        switch self.processingState {
        case .fast:
            return 0           
        case .normal:
            return 64         // XXX test this
        case .slow:
            return 256
        }
    }

    
}
