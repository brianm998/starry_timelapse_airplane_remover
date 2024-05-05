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

    var detectionType: DetectionType = .mild
    
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
        }
    }

    // blobs can grow until the get this much
    // darker than their seed pixel
    // larger values give more blobs
    public var blobberMinContrast: Double {
        switch self.detectionType {
        case .mild:
            return 50        
        case .strong:
            return 55
        case .excessive:
            return 62
        }
    }

    // the size that blobs need to be smaller than for
    // blobberBrightMinIntensity to apply
    // larger size gives fewer blobs
    public var blobberBrightSmallSize: Int {
        switch self.detectionType {
        case .mild:
            return 25        
        case .strong:
            return 22
        case .excessive:
            return 20
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
        }
    }
    
    // blobs smaller than this are ignored by the blobber
    // smaller values give more blobs
    public var blobberMinBlobSize: Int {
        switch self.detectionType {
        case .mild:
            return 8         
        case .strong:
            return 6
        case .excessive:
            return 4
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
        }
    }
}
