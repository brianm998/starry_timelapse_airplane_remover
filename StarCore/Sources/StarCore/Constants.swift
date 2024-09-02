import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// public global
public let constants = Constants()

public class Constants {

    public var detectionType: DetectionType = .mild
    
    // pixels with less changed intensity than this cannot start blobs
    // lower values give more blobs
    public var blobberMinPixelIntensity: UInt16 {
        switch self.detectionType {
        case .mild:
            return 5000
        case .strong:
            return 3000
        case .excessive:
            return 2000
        case .exp:
            return 6500
        case .radical:
            return 6000
        }
    }

    // blobs can grow until they get this
    // percentage darker than their seed pixel
    // larger values make any individiual blob bigger,
    // and may increase the total number of blobs due to their size
    public var blobberMinContrast: Double {
        switch self.detectionType {
        case .mild:
            return 50        
        case .strong:
            return 55
        case .excessive:
            return 62
        case .exp:
            return 66 
        case .radical:
            return 60 
        }
    }

    // the size that blobs need to be smaller than for
    // blobberBrightMinIntensity to apply
    // larger size gives fewer blobs
    public var blobberBrightSmallSize: Double {
        switch self.detectionType {
        case .mild:
            return 25        
        case .strong:
            return 22
        case .excessive:
            return 20
        case .exp:
            return 25
        case .radical:
            return 5
        }
    }

    // if a blob is smaller than blobberBrightSmallSize,
    // then discard it if it's median intensity is less than this
    // larger values give fewer blobs
    public var blobberBrightMinIntensity: UInt16 {
        switch self.detectionType {
        case .mild:
            return 3500      
        case .strong:
            return 3300
        case .excessive:
            return 3000
        case .exp:
            return 3500
        case .radical:
            return 3500
        }
    }
    
    // blobs smaller than this are ignored by the blobber
    // smaller values give more blobs
    public var blobberMinBlobSize: Double {
        switch self.detectionType {
        case .mild:
            return 8         
        case .strong:
            return 6
        case .excessive:
            return 4
        case .exp:
            return 5
        case .radical:
            //return 1.8            // XXX this is the problem ATM
            return 1.85
            //return 3            // XXX this is the problem ATM
        }
    }

    // blobs with less median intensity than this are ignored
    // lower values give more blobs
    public var blobberMinBlobIntensity: UInt16 {
        switch self.detectionType {
        case .mild:
            return 2500      
        case .strong:
            return 2200
        case .excessive:
            return 2000
        case .exp:
            return 2500
        case .radical:
            return 1500
        }
    }
    
    // lines generated from the subtraction frame
    // that have fewer votes than this are ignored
    // larger values speed up processing and
    // decrease how many outlier groups are joined with lines
    public var khtMinLineVotes: Int {
        switch self.detectionType {
        case .mild:
            return 3000      
        case .strong:
            return 2500
        case .excessive:
            return 2000
        case .exp:
            return 3000
        case .radical:
            return 1000
        }
    }

    // how far off of the end of the line do we look when doing KHT processing?
    // larger values increase processing time
    public var khtLineExtensionAmount: Int {
        switch self.detectionType {
        case .mild:
            return 64
        case .strong:
            return 128
        case .excessive:
            return 256
        case .exp:
            return 64
        case .radical:
            return 4
        }
    }
}
