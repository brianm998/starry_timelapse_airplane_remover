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
public var decisionTrees: [String: NamedOutlierGroupClassifier] = loadOutlierGroupClassifiers()

// try to load this classifier at runtime
//public let currentClassifierName = "dd59698e" // older pre-alignment tree
//public let currentClassifierName = "1a4a93a6"   // newer smaller after alignment tree REDO
public let currentClassifierName = "a7624239" // newest, but slight worse than 1a4a93a6?
public var currentClassifier: NamedOutlierGroupClassifier? = loadCurrentClassifiers()


public func loadCurrentClassifiers() -> NamedOutlierGroupClassifier? {
    let ret = decisionTrees[currentClassifierName]
    Log.i("loaded current classifier \(String(describing: ret))")
    return ret
}

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

