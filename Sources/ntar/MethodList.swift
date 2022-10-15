import Foundation

@available(macOS 10.15, *) 
actor MethodList {
    var list: [Int : () async -> Void] = [:]

    func add(atIndex index: Int, method: @escaping () async -> Void) {
        list[index] = method
    }

    func removeValue(forKey key: Int) {
        list.removeValue(forKey: key)
    }
    
    var count: Int {
        get {
            return list.count
        }
    }

    var nextKey: Int? {
        get {
            return list.sorted(by: { $0.key < $1.key}).first?.key
        }
    }
}
