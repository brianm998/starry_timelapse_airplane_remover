import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// public global
nonisolated(unsafe) public var constants = Constants(detectionType: .strong)

public final class Constants: Sendable {

    public let detectionType: DetectionType

    public init(detectionType: DetectionType) {
        self.detectionType = detectionType
    }
    
    // pixels with less changed intensity than this cannot start blobs
    // lower values give more blobs
    public var blobberMinPixelIntensity: UInt16 {
        switch self.detectionType {
        case .mild:
            return 7000
        case .strong:
            return 6000
        case .excessive:
            return 4500
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
            return 60 
        case .excessive:
            return 62
        }
    }

    // if a blob is smaller than size,
    // then discard it if it's median intensity is less than this
    // larger values give fewer blobs
    public var blobberSmallBlobQualifier: BlobQualifier {
        switch self.detectionType {
        case .mild:
            return .init(size: 25, medianIntensity: 3500)
        case .strong:
            return .init(size: 10, medianIntensity: 3500)
        case .excessive:
            return .init(size: 8, medianIntensity: 3000)
        }
    }
    
    // blobs smaller than this are ignored at the beginning of blob processing
    // smaller values give more blobs
    public var blobberMinBlobSize: Int {
        switch self.detectionType {
        case .mild:
            return 8         
        case .strong:
            return 5
        case .excessive:
            return 4
        }
    }

    // blobs smaller than this are discarded at the end of blob processing
    // smaller values give more blobs 
    public var finalMinBlobSize: Int {
        switch self.detectionType {
        case .mild:
            return 40      
        case .strong:
            return 20
        case .excessive:
            return 15
        }
    }

    // blobs with less median intensity than this are ignored
    // lower values give more blobs
    public var blobberMinBlobIntensity: UInt16 {
        switch self.detectionType {
        case .mild:
            return 2500      
        case .strong:
            return 1500
        case .excessive:
            return 1200
        }
    }

    // blobs smaller and dimmer than this are discarded at the end
    // smaller values give more blobs
    public var finalSmallDimBlobQualifier: BlobQualifier {
        switch self.detectionType {
        case .mild:
            return .init(size: 50, medianIntensity: 12000)
        case .strong:
            return .init(size: 30, medianIntensity: 10000)
        case .excessive:
            return .init(size: 20, medianIntensity: 8000)
        }
    }

    // blobs smaller and dimmer than this are discarded at the end
    // smaller values give more blobs
    public var finalMediumDimBlobQualifier: BlobQualifier {
        switch self.detectionType {
        case .mild:
            return .init(size: 60, medianIntensity: 15000)
        case .strong:
            return .init(size: 50, medianIntensity: 15000)
        case .excessive:
            return .init(size: 30, medianIntensity: 10000)
        }
    }

    // blobs smaller and dimmer than this are discarded at the end
    // smaller values give more blobs
    public var finalLargeDimBlobQualifier: BlobQualifier {
        switch self.detectionType {
        case .mild:
            return .init(size: 150, medianIntensity: 5000)
        case .strong:
            return .init(size: 120, medianIntensity: 3000)
        case .excessive:
            return .init(size: 80, medianIntensity: 2000)
        }
    }
}

// allows blobs if they are bigger or more intense than this
public struct BlobQualifier {
    let size: Int
    let medianIntensity: UInt16

    // is this blob allowed?
    func allows(_ blob: Blob) async -> Bool {
        let blobSize = await blob.size()
        let intensity = await blob.medianIntensity()
        
        return !(blobSize < size && intensity < medianIntensity)
    }
}
