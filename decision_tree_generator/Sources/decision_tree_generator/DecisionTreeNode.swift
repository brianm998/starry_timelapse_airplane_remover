
import Foundation
import StarCore


// a function called by the top level decision tree to keep individual functions
// from getting so big the complier takes days to compile it.
class DecisionSubtree: SwiftDecisionSubtree, @unchecked Sendable {

    let rootNode: DecisionTreeNode
    let id = UUID()
    
    init(rootNode: DecisionTreeNode) {
        self.rootNode = rootNode
    }

    var methodName: String {
        "subtree_\(id)"
          .replacingOccurrences(of: "-", with: "_")
    }
    
    var swiftCode: (String, [SwiftDecisionSubtree]) {
        let (nodeSwift, furtherSubtrees) = rootNode.furtherRecurseSwiftCode
        let swift = """

          
              fileprivate func \(methodName)(_ group: ClassifiableOutlierGroup) async -> Double {
          \(nodeSwift)
              }
          """
        return (swift, furtherSubtrees)
    }
}

// decision node which decides upon a value of some type
// delegating to one of two further code paths
class DecisionTreeNode: SwiftDecisionTree, @unchecked Sendable {

    public init (type: OutlierGroup.Feature,
                 value: Double,
                 lessThan: SwiftDecisionTree,
                 lessThanStumpValue: Double,
                 greaterThan: SwiftDecisionTree,
                 greaterThanStumpValue: Double,
                 indent: Int,            // really recursion level
                 newMethodLevel: Int,    // how far we recurse before making a new method
                 stump: Bool = false)
    {
        self.type = type
        self.value = value
        self.lessThan = lessThan
        self.greaterThan = greaterThan
        self.indent = indent
        self.lessThanStumpValue = lessThanStumpValue
        self.greaterThanStumpValue = greaterThanStumpValue
        self.newMethodLevel = newMethodLevel
        self.stump = stump
    }

    // stump means cutting off the tree at this node, and returning stumped values
    // of the test data on either side of the split
    var stump: Bool
    let lessThanStumpValue: Double
    let greaterThanStumpValue: Double
      
    // the kind of value we are deciding upon
    let type: OutlierGroup.Feature

    // the value that we are splitting upon
    let value: Double

    var valueString: String {
        "\(value)"
          .replacingOccurrences(of: ".", with: "_")
          .replacingOccurrences(of: "-", with: "_")
    }
    
    // code to handle the case where the input data is less than the given value
    let lessThan: SwiftDecisionTree

    // code to handle the case where the input data is greater than the given value
    let greaterThan: SwiftDecisionTree

    // indentention is levels of recursion, not spaces directly
    let indent: Int

    // how far do we recurse before starting a new method?
    let newMethodLevel: Int
    
    // runtime execution
    func classification(of group: ClassifiableOutlierGroup) async -> Double {
        let outlierValue = await group.decisionTreeValueAsync(for: type)
        if stump {
            if outlierValue < value {
                return lessThanStumpValue
            } else {
                return greaterThanStumpValue
            }
        } else {
            if outlierValue < value {
                return await lessThan.classification(of: group)
            } else {
                return await greaterThan.classification(of: group)
            }
        }
    }

    func classification
      (
        of features: [OutlierGroup.Feature], // parallel
        and values: [Double]                 // arrays
      ) async -> Double
    {
        for i in 0 ..< features.count {
            if features[i] == type {
                let outlierValue = values[i]

                if stump {
                    if outlierValue < value {
                        return lessThanStumpValue
                    } else {
                        return greaterThanStumpValue
                    }
                } else {
                    if outlierValue < value {
                        return await lessThan.classification(of: features, and: values)
                    } else {
                        return await greaterThan.classification(of: features, and: values)
                    }
                }
                
            }
        }
        fatalError("cannot find \(type)")
    }

    var furtherRecurseSwiftCode: (String, [SwiftDecisionSubtree]) {
        // recurse on an if statement
        let (lessThanSwift, lessThanSubtrees) = lessThan.swiftCode
        let (greaterThanSwift, greaterThanSubtrees) = greaterThan.swiftCode

        var indentation = ""
        for _ in 0..<initialIndent+(indent % newMethodLevel) { indentation += "    " }
        var awaitStr = ""
        var asyncStr = ""
        if type.needsAsync {
            awaitStr = "await "
            asyncStr = "Async"
        }
        
        let swift = """
          \(indentation)if \(awaitStr)group.decisionTreeValue\(asyncStr)(for: .\(type)) < \(value) {
          \(lessThanSwift)
          \(indentation)} else {
          \(greaterThanSwift)
          \(indentation)}
          """
        return (swift, lessThanSubtrees + greaterThanSubtrees)
    }
    
    // write swift code to do the same thing
    var swiftCode: (String, [SwiftDecisionSubtree]) {
        var indentation = ""
        for _ in 0..<initialIndent+(indent % newMethodLevel) { indentation += "    " }
        var awaitStr = ""
        var asyncStr = ""
        if type.needsAsync {
            awaitStr = "await "
            asyncStr = "Async"
        }
        if stump {
            let swift = """
              \(indentation)if \(awaitStr)group.decisionTreeValue\(asyncStr)(for: .\(type)) < \(value) {
              \(indentation)    return \(lessThanStumpValue)
              \(indentation)} else {
              \(indentation)    return \(greaterThanStumpValue)
              \(indentation)}
              """
            return (swift, [])
        } else {
            if indent != 0,
               indent % newMethodLevel == 0
            {
                // make a subtree instead of extending the tree further
                let subtree = DecisionSubtree(rootNode: self)

                var specialIndentation = ""
                for _ in 0..<initialIndent+newMethodLevel { specialIndentation += "    " }
                
                let swift = """
                  \(specialIndentation)return await \(subtree.methodName)(group)
                  """
                return (swift, [subtree])
            } else {
                return furtherRecurseSwiftCode
            }            
            
        }
    }
}

