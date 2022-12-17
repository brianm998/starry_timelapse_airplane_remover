import Foundation

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/
@available(macOS 10.15, *)
actor NumberRunning {
    private var count: UInt = 0

    let name: String
    let max: Int
    let position: Double
    
    init(in name: String, max: Int, position: Double) {
        self.name = name
        self.max = max
        self.position = position
    }
    
    public func increment() { count += 1 }
    public func decrement() { count -= 1 }
    public func currentValue() -> UInt { count }
}

