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

public actor Constants {        // XXX rename this

    private var detectionType: DetectionType

    private var houghLineFinderArgs: HoughLineFinder.Args = .init()

    public init(detectionType: DetectionType) {
        self.detectionType = detectionType
    }

    public func getDetectionType() -> DetectionType { detectionType }
    
    public func set(detectionType: DetectionType) async {
        self.detectionType = detectionType
        contentTypeDidChangeClosure?(detectionType)
        if let contentTypeDidChangeClosure {
            contentTypeDidChangeClosure(detectionType)
        }
    }

    private var contentTypeDidChangeClosure: ((DetectionType) -> Void)? = nil
    
    public func didChange(_ closure: @escaping (DetectionType) -> Void) {
        self.contentTypeDidChangeClosure = closure
    }

    public func getHoughLineFinderArgs() -> HoughLineFinder.Args { houghLineFinderArgs }

    public func set(houghLineFinderArgs newArgs: HoughLineFinder.Args) async {
        self.houghLineFinderArgs = newArgs
    }
}

