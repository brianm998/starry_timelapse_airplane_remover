import Foundation

/*
 This OutlierGroup extention contains all of the decision tree specific logic.

 Adding a new case to the Feature and giving a value for it in decisionTreeValue
 is all needed to add a new value to the decision tree criteria
 
 */

// different ways we split up data sets that are still overlapping
public enum DecisionSplitType: String {
    case median
    case mean
    // XXX others ???
}

// a list of all extant decision trees at runtime, indexed by hash prefix
@available(macOS 10.15, *)
public var decisionTrees: [String: NamedOutlierGroupClassifier] = loadOutlierGroupClassifiers()

// try to load this classifier at runtime
public let currentClassifierName = "1ea755d8"

@available(macOS 10.15, *)
public var currentClassifier: NamedOutlierGroupClassifier? = loadCurrentClassifiers()


@available(macOS 10.15, *)
public func loadCurrentClassifiers() -> NamedOutlierGroupClassifier? {
    let ret = decisionTrees[currentClassifierName]
    Log.i("loaded current classifier \(String(describing: ret))")
    return ret
}

@available(macOS 10.15, *)
public func loadOutlierGroupClassifiers() -> [String : NamedOutlierGroupClassifier] {
    let decisionTrees = listClasses { $0.compactMap { $0 as? NamedOutlierGroupClassifier.Type } }
    var ret: [String: NamedOutlierGroupClassifier] = [:]
    for tree in decisionTrees {
        let instance = tree.init()
        ret[instance.name] = instance
    }
    Log.i("loaded \(ret.count) outlier group classifiers")
    return ret
}

// black magic from the objc runtime
fileprivate func listClasses<T>(_ body: (UnsafeBufferPointer<AnyClass>) throws -> T) rethrows -> T {
  var cnt: UInt32 = 0
  let ptr = objc_copyClassList(&cnt)
  defer { free(UnsafeMutableRawPointer(ptr)) }
  let buf = UnsafeBufferPointer( start: ptr, count: Int(cnt) )
  return try body(buf)
}

public enum StreakDirection {
    case forwards
    case backwards
}

