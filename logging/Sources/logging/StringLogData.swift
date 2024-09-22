/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/
import Foundation

public struct StringLogData: LogData {

    public let description: String

    public init(with convertable: CustomStringConvertible) {
        self.description = convertable.description
    }

    public init(with string: String) {
        self.description = string
    }

    public init<T>(with data: T) {
        self.description = String(describing: data)
    }
}

