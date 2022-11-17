import Foundation

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

@available(macOS 10.15, *) 
actor MethodList<T> {
    var list: [Int : () async -> T] = [:]

    func add(atIndex index: Int, method: @escaping () async -> T) {
        list[index] = method
    }

    func removeValue(forKey key: Int) {
        list.removeValue(forKey: key)
    }
    
    func value(forKey key: Int) async -> (() async -> T)? {
        return await list[key]
    }
    
    var count: Int {
        return list.count
    }

    var nextKey: Int? {
        return list.sorted(by: { $0.key < $1.key}).first?.key
    }
}
