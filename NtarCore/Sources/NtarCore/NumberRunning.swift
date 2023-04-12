import Foundation

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/
@available(macOS 10.15, *)
public actor NumberRunning {
    private var count: UInt = 0

    public init() { }
    
    public func increment() { count += 1 }
    public func decrement() { if count > 0 {count -= 1} else { Log.e("cannot decrement past zero") } }
    public func currentValue() -> UInt { count }
    public func startOnIncrement(to max: UInt) -> Bool {
        if count >= max { return false }
        count += 1
        return true
    }
}
