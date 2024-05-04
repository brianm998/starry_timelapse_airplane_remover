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
    public var blobberMinIntensity: UInt16 {
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
    
    public var khtMinLineVotes: Int {
        switch self.processingState {
        case .fast:
            return 10000        
        case .normal:
            return 4000         // XXX test this
        case .slow:
            return 800
        }
    }

    public var khtLineExtensionAmount: Int {
        switch self.processingState {
        case .fast:
            return 64           
        case .normal:
            return 128         // XXX test this
        case .slow:
            return 256
        }
    }

    
}
