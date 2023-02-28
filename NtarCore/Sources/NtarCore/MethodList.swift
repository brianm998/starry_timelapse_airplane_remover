import Foundation

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

@available(macOS 10.15, *) 
actor MethodList<T> {
    var list: [Int : () async throws -> T]
    var removeClosure: ((Int) -> Void)?
    
    init(removeClosure: ((Int) -> Void)? = nil) {
        self.list = [:]
        self.removeClosure = removeClosure
    }
    
    init(list: [Int : () async throws -> T], removeClosure: ((Int) -> Void)? = nil) {
        self.list = list
        self.removeClosure = removeClosure
    }
    
    func add(atIndex index: Int, method: @escaping () async throws -> T) {
        list[index] = method
    }

    func set(removeClosure: @escaping (Int) -> Void) {
        self.removeClosure = removeClosure
    }
    
    func removeValue(forKey key: Int) {
        Log.v("removeValue(\(self.count))")
        list.removeValue(forKey: key)
        if let removeClosure = removeClosure {
            Log.v("removeClosure(\(self.count))")
            removeClosure(self.count)
        }
    }
    
    func value(forKey key: Int) async -> (() async throws -> T)? {
        return list[key]
    }
    
    var count: Int {
        return list.count
    }

    var nextKey: Int? {
        return list.sorted(by: { $0.key < $1.key}).first?.key
    }
}
