import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// public global is safe because it's an actor
public let constants = Constants(detectionType: .strong)

public actor Constants {

    private var detectionType: DetectionType

    public init(detectionType: DetectionType) {
        self.detectionType = detectionType
    }

    public func getDetectionType() -> DetectionType { detectionType }
    
    public func set(detectionType: DetectionType) async {
        self.detectionType = detectionType
        didChangeClosure?(detectionType)
        if let didChangeClosure {
            didChangeClosure(detectionType)
        }
    }

    private var didChangeClosure: ((DetectionType) -> Void)? = nil
    
    public func didChange(_ closure: @escaping (DetectionType) -> Void) {
        self.didChangeClosure = closure
    }
    
    // pixels with less changed intensity than this cannot start blobs
    // lower values give more blobs
    public var blobberMinPixelIntensity: UInt16 {
        switch self.detectionType {
        case .mild:
            return 6000
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

    // how close to zero (in percentage) can the intensity of pixels decrease before
    // being left out of a blob
    // zero means that only pixels of minimumLocalMaximum or higher will be in blobs
    // 50 means that all pixels half as bright or more than the maximum will be in a blob
    // 100 means that all pixels will be in a blob
    public var blobberMinContrast: Double {
        switch self.detectionType {
        case .mild:
            return 60        
        case .strong:
            return 60 
        case .excessive:
            return 62
        }
    }
}

