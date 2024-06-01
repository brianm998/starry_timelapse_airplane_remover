import Foundation
import StarCore
import ArgumentParser
import logging
import CryptoKit

// number of levels (groups of '    ') of indentation to start with 
let initialIndent = 2

struct TreeForestResult {
    let tree: DecisionTreeStruct
    let testScore: Double
}


actor DecisionTreeGenerator {

    let decisionTypes: [OutlierGroup.Feature]
    let decisionSplitTypes: [DecisionSplitType]
    let maxDepth: Int
    let pruneTree: Bool
    
    public init(withTypes types: [OutlierGroup.Feature] = OutlierGroup.Feature.allCases,
                andSplitTypes splitTypes: [DecisionSplitType] = [.median],
                pruneTree: Bool = true,
                maxDepth: Int? = nil)
    {
        decisionTypes = types
        decisionSplitTypes = splitTypes
        self.pruneTree = pruneTree
        if let maxDepth = maxDepth {
            self.maxDepth = maxDepth
        } else {
            self.maxDepth = -1  // no limit
        }
    }

    func generateForest(withInputData inputData: ClassifiedData,
                        andTestData testData: [ClassifiedData],
                        inputFilenames: [String],
                        treeCount: Int,
                        baseFilename: String) async throws -> [TreeForestResult]
    {
        /*
         split the input data into treeCount evenly spaced groups

         each tree has one of these data groups removed for validation,

         not training, creating treeCount different trees.
         
         finally write out a classifier which decides based upon the weighted
         sum of all of the trees in this forest, a group consensus.
         */
        
        let inputDataSplit = inputData.shuffleSplit(into: treeCount)

        var validationData = ClassifiedData()

        let trees = try await withLimitedThrowingTaskGroup(of: TreeForestResult.self) { taskGroup in
            var results: [TreeForestResult] = []
            for validationIndex in 0..<inputDataSplit.count {
                try await taskGroup.addTask() { 
                    // generate a tree from this validation data
                    validationData = inputDataSplit[validationIndex]
                    
                    // use the remaining data for training
                    let trainingData = ClassifiedData()
                    for i in 0..<inputDataSplit.count {
                        if i != validationIndex {
                            trainingData += inputDataSplit[i]
                        }
                    }

                    Log.i("have \(validationData.count) validationData, \(testData.map { $0.count }.reduce(0, +)) testData and \(trainingData.count) trainingData @ validation index \(validationIndex)")
                    
                    let tree = try await self.generateTree(withTrainingData: trainingData,
                                                           andTestData: validationData,
                                                           inputFilenames: inputFilenames,
                                                           baseFilename: baseFilename,
                                                           treeIndex: validationIndex)

                    Log.i("generated tree")
                    
                    // save this generated swift code to a file
                    if fileManager.fileExists(atPath: tree.filename) {
                        Log.i("overwriting already existing filename \(tree.filename)")
                        try fileManager.removeItem(atPath: tree.filename)
                    }

                    // write to file
                    fileManager.createFile(atPath: tree.filename,
                                            contents: tree.swiftCode.data(using: .utf8),
                                            attributes: nil)

                    // run test on test data
                    let (treeGood, treeBad) = await runTest(of: tree, onChunks: testData)
                    let score = Double(treeGood)/Double(treeGood + treeBad)
                    
                    return TreeForestResult(tree: tree, testScore: score)
                }
            }
            try await taskGroup.forEach() { results.append($0) }
            return results
        }

        return trees
    }    

    func writeClassifier(with forest: [TreeForestResult],
                         baseFilename: String) async throws -> OutlierGroupClassifier
    {
        var treesDeclarationString = ""
        var treesClassificationString1 = ""
        var treesClassificationString2 = ""
        var treesNameListString = "["
        var digest = SHA256()

        var treesTypeString = ""
        
        for tree in forest {
            let score = tree.testScore
            let name = tree.tree.name
            Log.i("have tree \(name) w/ score \(score)")

            treesDeclarationString += "    let tree_\(name) = OutlierGroupDecisionTree_\(name)()\n"
            treesClassificationString1 += "        total += self.tree_\(name).classification(of: group) * \(score)\n"
            treesClassificationString2 += "        total += self.tree_\(name).classification(of: featureData) * \(score)\n"
            treesNameListString += " \"\(name)\","

            treesTypeString += "   \(tree.tree.type)\n\n"
            
            digest.update(data: Data(name.utf8))
        }
        let treeHash = digest.finalize()
        let treeHashString = treeHash.compactMap { String(format: "%02x", $0) }.joined()
        let hashPrefix = String(treeHashString.prefix(shaPrefixSize))

        treesNameListString.removeLast()
        treesNameListString += "]"

        let filename = "\(baseFilename)\(hashPrefix).swift"

        var pruneString = ""
        if pruneTree {
            pruneString = "Trees were pruned with test data"
        } else {
            pruneString = "Trees were NOT pruned with test data"
        }

        var depthString = ""
        if maxDepth < 0 {
            depthString = "Trees were computed to the maximum depth possible"
        } else {
            depthString = "Trees were computed to a maximum depth of \(maxDepth) levels"
        }
        
        let generationDate = Date()
        let swiftString =
             """
             /*
                written by decision_tree_generator on \(generationDate).

                The classifications of \(forest.count) trees are combined here with weights from test data.
                
                \(depthString)

                \(pruneString)

             \(treesTypeString)
              */

             import Foundation
             import StarCore
             
             // DO NOT EDIT THIS FILE
             // DO NOT EDIT THIS FILE
             // DO NOT EDIT THIS FILE

             public final class OutlierGroupForestClassifier_\(hashPrefix): NamedOutlierGroupClassifier {

                 public init() { }

                 public let name = "\(hashPrefix)"
                 
                 public let type: ClassifierType = .forest(DecisionForestParams(name: \"\(hashPrefix)\",
                                                                                treeCount: \(forest.count),
                                                                                treeNames: \(treesNameListString)))

             \(treesDeclarationString)
                 // returns -1 for negative, +1 for positive
                 public func classification(of group: ClassifiableOutlierGroup) -> Double {
                     var total: Double = 0.0
             
             \(treesClassificationString1)
                     return total / \(forest.count)
                 }

                 // returns -1 for negative, +1 for positive
                 public func classification (
                    of features: [OutlierGroup.Feature],   // parallel
                    and values: [Double]                   // arrays
                 ) -> Double
                 {
                     var total: Double = 0.0
                     
                     let featureData = OutlierGroupFeatureData(features: features, values: values)
                     
             \(treesClassificationString2)
                     return total / \(forest.count)
                 }
             }
             """
        // save this generated swift code to a file
        if fileManager.fileExists(atPath: filename) {
            Log.i("overwriting already existing filename \(filename)")
            try fileManager.removeItem(atPath: filename)
        }

        // write to file
        fileManager.createFile(atPath: filename,
                                contents: swiftString.data(using: .utf8),
                                attributes: nil)

        return ForestClassifier(trees: forest)
    }
    
    // top level func that writes a compilable wrapper around the root tree node
    func generateTree(withTrainingData trainingData: ClassifiedData,
                      andTestData testData: ClassifiedData,
                      inputFilenames: [String],
                      baseFilename: String,
                      treeIndex: Int? = nil) async throws -> DecisionTreeStruct
    {
        let endTime = Date()

        let formatter = DateComponentsFormatter()
        formatter.calendar = Calendar.current
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .full
        let durationString = formatter.string(from: startTime, to: endTime) ?? "??"
        
        let indentation = "        "
        var digest = SHA256()

        if let treeIndex = treeIndex {
            digest.update(data: Data("\(treeIndex)".utf8))
        }
        
        digest.update(data: Data("\(trainingData.positiveData.count)".utf8))
        digest.update(data: Data("\(trainingData.negativeData.count)".utf8))

        if pruneTree {
            digest.update(data: Data("PRUNE".utf8))
        } else {
            digest.update(data: Data("NO PRUNE".utf8))
        }
        
        var inputFilesString = ""
        var inputFilesArray = "\(indentation)["
        for inputFilename in inputFilenames {
            inputFilesString += "     - \(inputFilename)\n"
            inputFilesArray += "\n\(indentation)    \"\(inputFilename)\","
            digest.update(data: Data(inputFilename.utf8))
        }
        inputFilesArray.removeLast()
        inputFilesArray += "\n\(indentation)]"

        let generationDate = Date()

        for type in decisionTypes {
            digest.update(data: Data(type.rawValue.utf8))
        }

        for type in decisionSplitTypes {
            digest.update(data: Data(type.rawValue.utf8))
        }

        digest.update(data: Data("\(maxDepth)".utf8))
        
        let treeHash = digest.finalize()
        let treeHashString = treeHash.compactMap { String(format: "%02x", $0) }.joined()
        let generationDateSince1970 = generationDate.timeIntervalSince1970

        let hashPrefix = String(treeHashString.prefix(shaPrefixSize))

        let filename = "\(baseFilename)\(hashPrefix).swift"

        let baseClassName = baseFilename.components(separatedBy: "/").last

        guard let baseClassName else { fatalError("bad baseFilename \(baseFilename)") }
        
        // check to see if this file exists or not
        /*
        if fileManager.fileExists(atPath: filename) {
            // Don't do anything
            throw "decision tree already exists at \(filename)"
        }
         */
        var decisionTypeString = "[\n"
        
        for type in decisionTypes {
            decisionTypeString += "        .\(type.rawValue),\n"
        }
        decisionTypeString.removeLast()
        decisionTypeString.removeLast()
        
        decisionTypeString += "\n    ]\n"
        

        var skippedDecisionTypeString = "    public let notUsedDecisionTypes: [OutlierGroup.Feature] = [\n"

        var wasAdded = false
        for type in OutlierGroup.Feature.allCases {
            var shouldAdd = true
            for requestedType in decisionTypes {
                if type == requestedType {
                    shouldAdd = false
                    break
                }
            }
            if shouldAdd {
                wasAdded = true 
                skippedDecisionTypeString += "        .\(type.rawValue),\n"
            }
        }
        if wasAdded {
            skippedDecisionTypeString.removeLast()
            skippedDecisionTypeString.removeLast()
        }
        
        skippedDecisionTypeString += "\n    ]\n"

        var decisionSplitTypeString = "[\n"
        
        for type in decisionSplitTypes {
            decisionSplitTypeString += "        .\(type.rawValue),\n"
        }
        decisionSplitTypeString.removeLast()
        decisionSplitTypeString.removeLast()

        decisionSplitTypeString += "\n    ]\n"

        Log.d("getting root")

        // the root tree node with all of the test data 
        var tree = await decisionTreeNode(withTrainingData: trainingData,
                                          indented: initialIndent,
                                          decisionTypes: decisionTypes,
                                          decisionSplitTypes: decisionSplitTypes,
                                          maxDepth: maxDepth)


        var generatedSwiftCode: String = ""
        if pruneTree {
            // prune this mother fucker with test data
            // this can take a long time
            tree = await prune(tree: tree, with: testData)
        }
        generatedSwiftCode = tree.swiftCode

        Log.d("got root")

        var treeString = ""
        
        if let treeIndex = treeIndex {
            treeString =
              """
                 This is tree number \(treeIndex) of a forest
              
              """
        }

        var pruneString = ""
        
        if pruneTree {
            pruneString =
              """
                 This tree was pruned with test data
              
              """
        } else {
            pruneString =
              """
                 This tree was NOT pruned with test data
              
              """
        }
        
        let swiftString = """
          /*
             written by decision_tree_generator on \(generationDate) in \(durationString)

             with training data consisting of:
               - \(trainingData.positiveData.count) groups known to be positive
               - \(trainingData.negativeData.count) groups known to be negative

             from input data described by:
          \(inputFilesString)
          \(treeString)
          \(pruneString)
          */
          
          import Foundation
          import StarCore
          
          // DO NOT EDIT THIS FILE
          // DO NOT EDIT THIS FILE
          // DO NOT EDIT THIS FILE

          public final class \(baseClassName)\(hashPrefix): DecisionTree {
              public init() { }
              public let sha256 = "\(treeHashString)"
              public let name = "\(hashPrefix)"
              public let sha256Prefix = "\(hashPrefix)"
              public let maxDepth = \(maxDepth)
              public let type: ClassifierType = .tree(DecisionTreeParams(name: \"\(hashPrefix)\",
                                                         inputSequences: \(inputFilesArray),
                                                         positiveTrainingSize: \(trainingData.positiveData.count),
                                                         negativeTrainingSize: \(trainingData.negativeData.count),
                                                         decisionTypes: \(decisionTypeString),
                                                         decisionSplitTypes: \(decisionSplitTypeString),
                                                         maxDepth: \(maxDepth),
                                                         pruned: \(pruneTree)))
              
              public let generationSecondsSince1970 = \(generationDateSince1970)

              // the list of decision types this tree did not use
          \(skippedDecisionTypeString)
          
              // a way to call into the decision tree without an OutlierGroup object
              // it's going to blow up unless supplied with the expected set of features
              // return value is between -1 and 1, 1 is paint
              public func classification(
                 of features: [OutlierGroup.Feature], // parallel
                 and values: [Double]                 // arrays
                ) -> Double
              {
                  let featureData = OutlierGroupFeatureData(features: features, values: values)
                  return classification(of: featureData)
              }

              // the actual tree resides here
              // return value is between -1 and 1, 1 is paint
              public func classification(of group: ClassifiableOutlierGroup) -> Double 
              {
          \(generatedSwiftCode)
              }
          }
          """

        return DecisionTreeStruct(name: hashPrefix,
                               swiftCode: swiftString,
                               tree: tree,
                               filename: filename,
                               sha256: treeHashString,
                               generationSecondsSince1970: generationDateSince1970,
                               inputSequences: inputFilenames,
                               decisionTypes: decisionTypes,
                               type: .tree(DecisionTreeParams(name: hashPrefix,
                                                          inputSequences: inputFilenames,
                                                          positiveTrainingSize: trainingData.positiveData.count,
                                                          negativeTrainingSize: trainingData.negativeData.count,
                                                          decisionTypes: decisionTypes,
                                                          decisionSplitTypes: decisionSplitTypes,
                                                          maxDepth: maxDepth,
                                                          pruned: pruneTree)))
    }

}

// XXX document what this does
fileprivate func getValueDistributions(of values: [[Double]],
                                       on decisionTypes: [OutlierGroup.Feature])
      async -> [ValueDistribution?]
{
    let typeCount = OutlierGroup.Feature.allCases.count
    
    var array = [ValueDistribution?](repeating: nil, count: typeCount)
    
    var tasks: [Task<ValueDistribution,Never>] = []
    
    // for each type, calculate a min/max/mean/median for both paint and not
    for type in decisionTypes {
        let allValues = values[type.sortOrder] 
        let task = await runTaskOld() {
            var min =  Double.greatestFiniteMagnitude
            var max = -Double.greatestFiniteMagnitude
            var sum = 0.0
            //Log.d("all values for paint \(type): \(allValues)")
            
            let count = allValues.count
            for idx in 0..<count {
                let value = allValues[idx] 
                if value < min { min = value }
                if value > max { max = value }
                sum += value
            }
            sum /= Double(allValues.count)
            var median = 0.0
            if allValues.count > 0 {
                median = allValues.sorted()[allValues.count/2]
            }                   // XXX why are we getting zero sized values?
            return ValueDistribution(type: type,
                                     min: min,
                                     max: max,
                                     mean: sum,
                                     median: median)
            
        }
        tasks.append(task)
    }
    
    for task in tasks {
        let response = await task.value
        array[response.type.sortOrder] = response
    }
    
    return array
}

    // XXX document what this does
    fileprivate func transform(testData: [OutlierFeatureData],
                               on decisionTypes: [OutlierGroup.Feature]) 
      async -> [[Double]]
{
    let typeCount = OutlierGroup.Feature.allCases.count
    
    var array = [Array<Double>](repeating: [],
                                count: typeCount)
    
    var tasks: [Task<DecisionTypeValuesResult,Never>] = []
    
    for type in decisionTypes {
        let task = await runTaskOld() {
            var list: [Double] = []
            let max = testData.count
            for idx in 0..<max {
                let valueMap = testData[idx]
                //Log.d("type.sortOrder \(type.sortOrder) valueMap.values.count \(valueMap.values.count)")
                if type.sortOrder < valueMap.values.count {
                    let value = valueMap.values[type.sortOrder]
                    list.append(value)
                }
            }
            return DecisionTypeValuesResult(type: type, values: list)
        }
        tasks.append(task)
    }
    
    for task in tasks {
        let response = await task.value

        array[response.type.sortOrder] = response.values

//            Log.w("bad data response.values.count \(response.values.count) [\(response.values)]")   // XXX make this better
    }

    return array
}

    // XXX document what this does
fileprivate func recurseOn(result: DecisionResult, indent: Int,
                           decisionTypes: [OutlierGroup.Feature],
                           decisionSplitTypes: [DecisionSplitType],
                           maxDepth: Int) async -> DecisionTreeNode {
    //Log.d("best at indent \(indent) was \(result.type) \(String(format: "%g", result.lessThanSplit)) \(String(format: "%g", result.greaterThanSplit)) \(String(format: "%g", result.value)) < Should \(await result.lessThanPositive.count) < ShouldNot \(await result.lessThanNegative.count) > Should  \(await result.lessThanPositive.count) > ShouldNot \(await result.greaterThanNegative.count)")
    
    // we've identified the best type to differentiate the test data
    // output a tree node with this type and value
    var lessResponse: TreeResponse?
    var greaterResponse: TreeResponse?
    
    let lessThanPaintCount = result.lessThanPositive.count
    let lessThanNotPaintCount = result.lessThanNegative.count
    
    let greaterThanPaintCount = result.greaterThanPositive.count
    let greaterThanNotPaintCount = result.greaterThanNegative.count
    
    let paintMax = Double(lessThanPaintCount+greaterThanPaintCount)
    let notPaintMax = Double(lessThanNotPaintCount+greaterThanNotPaintCount)
    
    // divide by max to even out 1/10 disparity in true/false data
    let lessThanPaintDiv = Double(lessThanPaintCount)/paintMax
    let greaterThanPaintDiv = Double(greaterThanPaintCount)/paintMax
    
    let lessThanStumpValue = lessThanPaintDiv / (lessThanPaintDiv + Double(lessThanNotPaintCount)/notPaintMax) * 2 - 1
    
    //Log.i("lessThanPaintCount \(lessThanPaintCount) lessThanNotPaintCount \(lessThanNotPaintCount) lessThanStumpValue \(lessThanStumpValue)")
    
    
    let greaterThanStumpValue = greaterThanPaintDiv / (greaterThanPaintDiv + Double(greaterThanNotPaintCount)/notPaintMax) * 2 - 1
    
    //Log.i("greaterThanPaintCount \(greaterThanPaintCount) greaterThanNotPaintCount \(greaterThanNotPaintCount) greaterThanStumpValue \(greaterThanStumpValue)")
    
    
    if at(max: indent + 2, at: maxDepth) {
        // stump, don't extend the tree branches further
        return DecisionTreeNode(type: result.type,
                                value: result.value,
                                lessThan: FullyPositiveTreeNode(indent: 0), // not used
                                lessThanStumpValue: lessThanStumpValue,
                                greaterThan: FullyPositiveTreeNode(indent: 0), // not used
                                greaterThanStumpValue: greaterThanStumpValue,
                                indent: indent/* + 1*/,
                                stump: true)
    } else {
        
        let lessThanPositive = result.lessThanPositive//.map { $0 }
        let lessThanNegative = result.lessThanNegative//.map { $0 }
        
        let greaterThanPositive = result.greaterThanPositive//.map { $0 }
        let greaterThanNegative = result.greaterThanNegative//.map { $0 }
        
        let lessResponseTask = await runTaskOld() {
            /*

             XXX

             handle cases where there is no test data on one side or the other

             in this case, currently we're returning -1 or 1.

             we should try to use the LinearChoiceTreeNode instead, with median data
             
            if lessThanPositive.count == 0 {

            } else if lessThanNegative.count == 0 {
                
            } else {
                
 */
                let _decisionTypes = decisionTypes
                let _decisionSplitTypes = decisionSplitTypes
                let lessTree = await decisionTreeNode(
                  withTrainingData: ClassifiedData(positiveData: lessThanPositive,
                                                   negativeData: lessThanNegative),
                  indented: indent + 1,
                  decisionTypes: _decisionTypes,
                  decisionSplitTypes: _decisionSplitTypes,
                  maxDepth: maxDepth)
                return TreeResponse(treeNode: lessTree, position: .less,
                                  stumpValue: lessThanStumpValue)
//            }
        }
        
        let _decisionTypes = decisionTypes
        let _decisionSplitTypes = decisionSplitTypes
        let greaterTree = await decisionTreeNode(
              withTrainingData: ClassifiedData(positiveData: greaterThanPositive,
                                               negativeData: greaterThanNegative),
              indented: indent + 1,
              decisionTypes: _decisionTypes,
              decisionSplitTypes: _decisionSplitTypes,
              maxDepth: maxDepth)
        greaterResponse = TreeResponse(treeNode: greaterTree, position: .greater,
                                        stumpValue: greaterThanStumpValue)
        
        lessResponse = await lessResponseTask.value
    }
    
    if let lessResponse = lessResponse,
       let greaterResponse = greaterResponse
    {
        let ret = DecisionTreeNode(type: result.type,
                                value: result.value,
                                lessThan: lessResponse.treeNode,
                                lessThanStumpValue: lessResponse.stumpValue,
                                greaterThan: greaterResponse.treeNode,
                                greaterThanStumpValue: greaterResponse.stumpValue,
                                indent: indent)
        
        return ret
    } else {
        Log.e("holy fuck")
        fatalError("doh")
    }
}

fileprivate func at(max indent: Int, at maxDepth: Int) -> Bool {
    if maxDepth < 0 { return false } // no limit
    return indent - initialIndent > maxDepth
}

fileprivate func result(for type: OutlierGroup.Feature,
                        decisionValue: Double,
                        withTrainingData trainingData: ClassifiedData)
  async -> FeatureResult
{
    var lessThanPositive: [OutlierFeatureData] = []
    var lessThanNegative: [OutlierFeatureData] = []
    
    var greaterThanPositive: [OutlierFeatureData] = []
    var greaterThanNegative: [OutlierFeatureData] = []
    
    // calculate how the data would split if we used the above decision value
    
    let positiveTrainingDataCount = trainingData.positiveData.count
    for index in 0..<positiveTrainingDataCount {
        let groupValues = trainingData.positiveData[index]
        let groupValue = groupValues.values[type.sortOrder] // crash here / bad index here too

        if groupValue < decisionValue {
            lessThanPositive.append(groupValues)
        } else {
            greaterThanPositive.append(groupValues)
        }
    }
    
    let negativeTrainingDataCount = trainingData.negativeData.count 
    for index in 0..<negativeTrainingDataCount {
        let groupValues = trainingData.negativeData[index]
        let groupValue = groupValues.values[type.sortOrder]
        if groupValue < decisionValue {
            lessThanNegative.append(groupValues)
        } else {
            greaterThanNegative.append(groupValues)
        }
    }

    var ret = FeatureResult(type: type)
    ret.decisionResult =
      await DecisionResult(type: type,
                           value: decisionValue,
                           lessThanPositive: lessThanPositive,
                           lessThanNegative: lessThanNegative,
                           greaterThanPositive: greaterThanPositive,
                           greaterThanNegative: greaterThanNegative)
    // XXX pass test data up here ^^^ ???
    
    return ret
}

// recursively return a decision tree that differentiates the test data
fileprivate func decisionTreeNode(withTrainingData trainingData: ClassifiedData,
                                  indented indent: Int,
                                  decisionTypes: [OutlierGroup.Feature],
                                  decisionSplitTypes: [DecisionSplitType],
                                  maxDepth: Int)
  async -> SwiftDecisionTree
{
    let positiveTrainingDataCount = trainingData.positiveData.count
    let negativeTrainingDataCount = trainingData.negativeData.count 
    
    //Log.d("new node w/ positiveTrainingDataCount \(positiveTrainingDataCount) negativeTrainingDataCount \(negativeTrainingDataCount)")
    
    if positiveTrainingDataCount == 0,
       negativeTrainingDataCount == 0
    {
        // in this case it's not clear what to return so we blow up
        Log.e("Cannot calculate anything with no input data")
        fatalError("no input data not allowed")
    }
    if positiveTrainingDataCount == 0 {
        // func was called without any data to paint, return don't paint it all
        // XXX instead of returning -1, use logic from LinearChoiceTreeNode
        return FullyNegativeTreeNode(indent: indent)
    }
    if negativeTrainingDataCount == 0 {
        // func was called without any data to not paint, return paint it all
        // XXX instead of returning 1, use logic from LinearChoiceTreeNode
        return FullyPositiveTreeNode(indent: indent)
    }
    
    // this is the 0-1 percentage of positivity
    let originalSplit =
      Double(positiveTrainingDataCount) /
      Double(negativeTrainingDataCount + positiveTrainingDataCount)

    //Log.d("originalSplit \(originalSplit)")
    
    // we have non zero test data of both kinds
    
    // collate should paint and not paint test data by type
    // look for boundries where we can further isolate 
    
    // raw values for each type
    // index these by outlierGroup.sortOrder
    
    // iterate ofer all decision tree types to pick the best one
    // that differentiates the test data
    
    let positiveTask = await runTaskOld() {
        // indexed by outlierGroup.sortOrder
        let positiveValues = await transform(testData: trainingData.positiveData, on: decisionTypes)
        return await getValueDistributions(of: positiveValues, on: decisionTypes)
    }
    
    let negativeTask = await runTaskOld() {
        // indexed by outlierGroup.sortOrder
        let negativeValues = await transform(testData: trainingData.negativeData, on: decisionTypes)
        return await getValueDistributions(of: negativeValues, on: decisionTypes)
    }
    
    let positiveDist = await positiveTask.value
    let negativeDist = await negativeTask.value
    
    var tasks: [Task<Array<FeatureResult>,Never>] = []
    
    // this one is likely a problem
    
    var decisionResults: [DecisionResult] = []
    var decisionTreeNodes: [FeatureResult] = []
    
    for type in decisionTypes {
        let paintDistFU: ValueDistribution? = positiveDist[type.sortOrder]
        let notPaintDistFU: ValueDistribution? = negativeDist[type.sortOrder]
        if let paintDist: ValueDistribution = paintDistFU,
           let notPaintDist: ValueDistribution = notPaintDistFU
        {
            let task = await runTaskOld() {
                if paintDist.max < notPaintDist.min {
                    // we have a linear split between all provided test data
                    // this is an end leaf node, both paths after decision lead to a result
                    //Log.d("clear distinction \(paintDist.max) < \(notPaintDist.min)")

                    var ret = FeatureResult(type: type)
                    ret.decisionTreeNode =
                      DecisionTreeNode(type: type,
                                       value: (paintDist.max + notPaintDist.min) / 2,
                                       lessThan: FullyPositiveTreeNode(indent: indent + 1),
                                       lessThanStumpValue: 1,
                                       greaterThan: FullyNegativeTreeNode(indent: indent + 1),
                                       greaterThanStumpValue: -1,
                                       indent: indent)
                     /*
                      // this LinearChoiceTreeNode underperformed the above by 1-2%
                      LinearChoiceTreeNode(type: type,
                                           min: paintDist.median,
                                           max: notPaintDist.median,
                                           indent: indent)
                                           ret.positiveDist = paintDist
                       */
                    ret.positiveDist = paintDist
                    ret.negativeDist = notPaintDist
                    return [ret]
                } else if notPaintDist.max < paintDist.min {
                    //Log.d("clear distinction \(notPaintDist.max) < \(paintDist.min)")
                    // we have a linear split between all provided test data
                    // this is an end leaf node, both paths after decision lead to a result
                    
                    var ret = FeatureResult(type: type)
                    ret.decisionTreeNode =
                      DecisionTreeNode(type: type,
                                       value: (notPaintDist.max + paintDist.min) / 2,
                                       lessThan: FullyNegativeTreeNode(indent: indent + 1),
                                       lessThanStumpValue: -1,
                                       greaterThan: FullyPositiveTreeNode(indent: indent + 1),
                                       greaterThanStumpValue: 1,
                                       indent: indent)
                      /*
                      LinearChoiceTreeNode(type: type,
                                           min: notPaintDist.median,
                                           max: paintDist.median,
                                           indent: indent)
                                           ret.positiveDist = paintDist
                       */
                    ret.positiveDist = paintDist
                    ret.negativeDist = notPaintDist
                    return [ret]
                } else {

                    // we do not have a linear split between all provided test data
                    // we need to figure out what type is best to segregate
                    // the test data further
                    
                    // test this type to see how much we can split the data based upon it
                    /*
                     if indent == initialIndent {
                     Log.d("for \(type) paintDist min \(paintDist.min) median \(paintDist.median) mean \(paintDist.mean) max \(paintDist.max) notPaintDist min \(notPaintDist.min) mean \(notPaintDist.mean) median \(notPaintDist.max) median \(notPaintDist.max)")
                     }
                     */
                    
                    var ret: [FeatureResult] = []
                    
                    for splitType in decisionSplitTypes {
                        switch splitType {
                        case .mean:
                            let result = await
                              result(for: type,
                                     decisionValue: (paintDist.mean + notPaintDist.mean) / 2,
                                     withTrainingData: trainingData)
                            ret.append(result)
                            
                        case .median:
                            let result = await 
                              result(for: type,
                                     decisionValue: (paintDist.median + notPaintDist.median) / 2,
                                     withTrainingData: trainingData)
                            ret.append(result)
                        }
                    }
                    return ret
                }
            }
            tasks.append(task)
        } else {
            Log.w("WTF")
        }
    }
          
    for task in tasks {
        let responses = await task.value

        let max = responses.count

        for idx in 0..<max {
            let response = responses[idx]

            if let result = response.decisionResult {
                decisionResults.append(result)
            }
            
            if let _ = response.decisionTreeNode,
               let _ = response.positiveDist,
               let _ = response.negativeDist
            {
                decisionTreeNodes.append(response)
            }
        } 
    }
    
    var rankedDecisionResults: [RankedResult<DecisionResult>] = []
    var bestTreeNodes: [RankedResult<SwiftDecisionTree>] = []
    
    let numberResponses = decisionTreeNodes.count
    for idx in 0..<numberResponses {
        let response = decisionTreeNodes[idx] 
        
        // these are direct splits that evenly cleave the input data into separate groups
        if let decisionTreeNode = response.decisionTreeNode,
           let paintDist = response.positiveDist,
           let notPaintDist = response.negativeDist
        {
            // check each direct decision result and choose the best one
            // based upon the difference between their edges and their means
            if paintDist.max < notPaintDist.min {
                let split =
                  (notPaintDist.min - paintDist.max) /
                  (notPaintDist.median - paintDist.median)
                let result = RankedResult(rank: split,
                                          type: response.type,
                                          result: decisionTreeNode)
                bestTreeNodes.append(result)
            } else if notPaintDist.max < paintDist.min {
                let split =
                  (paintDist.min - notPaintDist.max) /
                  (paintDist.median - notPaintDist.median)
                let result = RankedResult(rank: split,
                                          type: response.type,
                                          result: decisionTreeNode)
                bestTreeNodes.append(result)
            }
        }
    }
    
    let max = decisionResults.count
    for idx in 0..<max {
        let decisionResult = decisionResults[idx]
        // these are tree nodes that require recursion
        
        // choose the type with the best distribution 
        // that will generate the shortest tree
        if decisionResult.lessThanSplit > originalSplit {
            // the less than split is biggest so far
            let split = decisionResult.lessThanSplit - originalSplit
            
            rankedDecisionResults.append(RankedResult(rank: split,
                                                      type: decisionResult.type,
                                                      result: decisionResult)) 
            
        } else {
            //Log.d("decisionResult.lessThanSplit \(decisionResult.lessThanSplit) > originalSplit \(originalSplit)")
        }
        if decisionResult.greaterThanSplit > originalSplit {
            // the greater than split is biggest so far
            let split = decisionResult.greaterThanSplit - originalSplit
            
            rankedDecisionResults.append(RankedResult(rank: split,
                                                      type: decisionResult.type,
                                                      result: decisionResult)) 
        } else {
            //Log.d("decisionResult.greaterThanSplit \(decisionResult.greaterThanSplit) > originalSplit \(originalSplit)")
        }
    }
    
    // return a direct tree node if we have it (no recursion)
    // make sure we choose the best one of these
    if bestTreeNodes.count != 0 {
        if bestTreeNodes.count == 1 {
            return bestTreeNodes[0].result
        } else {
            // here we need to determine between them
            // current approach is to sort first by rank,
            // grouping identical first ranks into a group
            // which is then sorted now by type
            
            let sorted = bestTreeNodes.sorted { lhs, rhs in
                return lhs.rank > rhs.rank
            }
            
            var maxList: [RankedResult<SwiftDecisionTree>] = [sorted[0]]
            
            let initial = sorted[0] 
            let max = sorted.count
            for i in 1..<max {
                let item = sorted[i] 
                if item.rank == initial.rank {
                    maxList.append(item)
                }
            }
            
            if maxList.count == 1 {
                return maxList[0].result
            } else {
                // XXX future improvement is to sort by something else here
                
                // sort them by type
                let maxSort = maxList.sorted { $0.type < $1.type }
                
                return maxSort[0].result
            }
        }
    }

    // if not, setup to recurse
    let rankedDecisionResultsCount = rankedDecisionResults.count
    if rankedDecisionResultsCount != 0 {
        let rankedDecisionResultsCount = rankedDecisionResults.count
        if rankedDecisionResultsCount == 1 {
            return await recurseOn(result: rankedDecisionResults[0].result,
                                   indent: indent,
                                   decisionTypes: decisionTypes,
                                   decisionSplitTypes: decisionSplitTypes,
                                   maxDepth: maxDepth)
        } else {
            // choose the first one somehow
            let sorted = rankedDecisionResults.sorted { lhs, rhs in
                return lhs.rank > rhs.rank
            }
            
            var maxList: [RankedResult<DecisionResult>] = [sorted[0]]
            
            let initial = sorted[0] 
            let max = sorted.count
            for i in 1..<max {
                let item = sorted[i] 
                if item.rank == initial.rank {
                    maxList.append(item)
                }
            }
            
            
            if maxList.count == 1 {
                /*
                 if indent == initialIndent {
                        Log.i("maxlist count is one, using type \(maxList[0].result.type)")
                        }
                        
                 */
                // sorting by rank gave us just one
                return await recurseOn(result: maxList[0].result,
                                       indent: indent,
                                       decisionTypes: decisionTypes,
                                       decisionSplitTypes: decisionSplitTypes,
                                       maxDepth: maxDepth) // XXX
            } else {
                // sort them by type next
                
                // XXX maybe sort by something else?
                
                let maxSort = maxList.sorted { $0.type < $1.type }
                /*
                 if indent == initialIndent {
                 Log.i("sorted by type is one, using type \(maxSort[0].result.type)")
                 }
                 */                  
                return await recurseOn(result: maxSort[0].result,
                                       indent: indent,
                                       decisionTypes: decisionTypes,
                                       decisionSplitTypes: decisionSplitTypes,
                                       maxDepth: maxDepth) // XXX
            }
        }
    } else {
        Log.e("no best type, defaulting to false :(")
        fatalError("FUCK")
        //return FullyNegativeTreeNode(indent: indent + 1)
    }
}



fileprivate struct RankedResult<T>: Comparable {
    let rank: Double
    let type: OutlierGroup.Feature
    let result: T

    public static func ==(lhs: RankedResult<T>, rhs: RankedResult<T>) -> Bool {
        return lhs.rank == rhs.rank
    }
    
    public static func <(lhs: RankedResult<T>, rhs: RankedResult<T>) -> Bool {
        return lhs.rank < rhs.rank
    }        
}

fileprivate struct DecisionTypeValuesResult {
    let type: OutlierGroup.Feature
    let values: [Double]
}

fileprivate struct FeatureResult {
    init(type: OutlierGroup.Feature) {
        self.type = type
    }
    let type: OutlierGroup.Feature
    var decisionResult: DecisionResult?
    var decisionTreeNode: SwiftDecisionTree?
    var positiveDist: ValueDistribution?
    var negativeDist: ValueDistribution?
}

fileprivate struct ValueDistribution {
    let type: OutlierGroup.Feature
    let min: Double
    let max: Double
    let mean: Double
    let median: Double
}

fileprivate struct TreeResponse {
    enum Place {
        case less
        case greater
    }
    
    let treeNode: SwiftDecisionTree
    let position: Place
    let stumpValue: Double
}
    
fileprivate struct DecisionResult {
    let type: OutlierGroup.Feature
    let value: Double
    let lessThanPositive: [OutlierFeatureData]
    let lessThanNegative: [OutlierFeatureData]
    let greaterThanPositive: [OutlierFeatureData]
    let greaterThanNegative: [OutlierFeatureData]
    let lessThanSplit: Double
    let greaterThanSplit: Double
    
    public init(type: OutlierGroup.Feature,
                value: Double = 0,
                lessThanPositive: [OutlierFeatureData],
                lessThanNegative: [OutlierFeatureData],
                greaterThanPositive: [OutlierFeatureData],
                greaterThanNegative: [OutlierFeatureData]) async
    {

        self.type = type
        self.value = value
        self.lessThanPositive = lessThanPositive
        self.lessThanNegative = lessThanNegative
        self.greaterThanPositive = greaterThanPositive
        self.greaterThanNegative = greaterThanNegative

        let lessThanPositiveCount = lessThanPositive.count
        let lessThanNegativeCount = lessThanNegative.count
        let greaterThanPositiveCount = greaterThanPositive.count
        let greaterThanNegativeCount = greaterThanNegative.count
        
        // XXX somehow factor in how far away the training data is from the split as well?
        
        // this is the 0-1 percentage of positive on the less than split

        if lessThanNegativeCount + lessThanPositiveCount == 0 {
            self.lessThanSplit = 0
        } else {
            self.lessThanSplit =
              Double(lessThanPositiveCount) /
              Double(lessThanNegativeCount + lessThanPositiveCount)
        }
        //Log.d("self.lessThanSplit \(self.lessThanSplit) lessThanNegativeCount \(lessThanNegativeCount) lessThanPositiveCount \(lessThanPositiveCount)")

        // this is the 0-1 percentage of positive on the greater than split
        if greaterThanNegativeCount + greaterThanPositiveCount == 0 {
            self.greaterThanSplit = 0
        } else {
            self.greaterThanSplit =
              Double(greaterThanPositiveCount) /
              Double(greaterThanNegativeCount + greaterThanPositiveCount)
        }
        //Log.d("self.greaterThanSplit \(self.greaterThanSplit) greaterThanNegativeCount \(greaterThanNegativeCount) greaterThanPositiveCount \(greaterThanPositiveCount)")
    }
}

public func runTest(of classifier: OutlierGroupClassifier,
                    onChunks classifiedData: [ClassifiedData]) async -> (Int, Int)
{
    // handle more than one classified data batch and run in parallel
    
    var numberGood: Int = 0
    var numberBad: Int = 0
    
    await withLimitedTaskGroup(of: (positive: Int,negative: Int).self) { taskGroup in
        for i in 0 ..< classifiedData.count {
            await taskGroup.addTask(){ 
                return await runTest(of: classifier, on: classifiedData[i])
            }
        }
        await taskGroup.forEach()  { result in
            numberGood += result.positive
            numberBad += result.negative
        }
    }
    return (numberGood, numberBad)
}

public func runTest(of classifier: OutlierGroupClassifier,
                    on classifiedData: ClassifiedData) async -> (Int, Int)
{
    let features = OutlierGroup.Feature.allCases

    var numberGood = 0
    var numberBad = 0
    
    for positiveData in classifiedData.positiveData {
        let classification = classifier.classification(of: features,
                                                       and: positiveData.values)
        if classification < 0 {
            // wrong
            numberBad += 1
        } else {
            //right
            numberGood += 1
        }
    }

    for negativeData in classifiedData.negativeData {
        let classification = classifier.classification(of: features,
                                                       and: negativeData.values)
        if classification < 0 {
            //right
            numberGood += 1
        } else {
            // wrong
            numberBad += 1
        }
    }

    return (numberGood, numberBad)
}

fileprivate func prune(tree: SwiftDecisionTree,
                       with testData: ClassifiedData) async -> SwiftDecisionTree
{
    // first split out the test data into chunks

    // then run tests in parallel

    let chunkedTestData = testData.split(into: ProcessInfo.processInfo.activeProcessorCount)

    var (bestGood, bestBad) = await runTest(of: tree, onChunks: chunkedTestData)

    let total = bestGood + bestBad
    
    var bestPercentageGood = Double(bestGood)/Double(total)*100
    let origPercentageGood = bestPercentageGood
    
    if bestBad == 0 {
        // can't get better than this, on point trying
        Log.i("not pruning tree with \(bestPercentageGood) initial test results.  Use a different test data set for pruning.")
        return tree
    } 
    
    Log.i("Prune start: bestGood \(bestGood), bestBad \(bestBad) \(bestPercentageGood)% good on \(testData.count) data points")

    // prune from the root node, checking how well the tree performs on the test data
    // with and without stumping the node in question.
    // If the non-stumped test results aren't better, then cut the tree off at that node
    
    if let rootNode = tree as? DecisionTreeNode {
        // iterate over every DecisionTreeNode and try stumping it and comparing to the
        // best found score so far
        
        var nodesToStump: [DecisionTreeNode] = [rootNode]
    
        while nodesToStump.count > 0 {
            let stumpNode = nodesToStump.removeFirst()
            if !stumpNode.stump {
                stumpNode.stump = true

                let (good, _) = await runTest(of: tree, onChunks: chunkedTestData)
                /*
                 >= stumps when they're equal
                 >  doesn't stump in that case
                 */
                if good > bestGood {
                    bestGood = good
                    bestPercentageGood = Double(bestGood)/Double(total)*100
                    // this was better, keep the stump
                    Log.i("pruning \(nodesToStump.count) nodes \(bestPercentageGood)% good better by \(good-bestGood) on \(testData.count) data points keeping stump w/ bestGood \(bestGood) \(bestPercentageGood)% good")
                } else {
                    // it was worse, remove stump
                    stumpNode.stump = false
                    if let lessNode = stumpNode.lessThan as? DecisionTreeNode {
                        // XXX narrow down data to that on this side

                        if let _ = lessNode.lessThan as? DecisionTreeNode,
                           let _ = lessNode.greaterThan as? DecisionTreeNode
                        {
                            nodesToStump.append(lessNode)
                        }
                    }
                    if let greaterNode = stumpNode.greaterThan as? DecisionTreeNode {
                        // XXX narrow down data to that on this side
                        if let _ = greaterNode.lessThan as? DecisionTreeNode,
                           let _ = greaterNode.greaterThan as? DecisionTreeNode
                        {
                            nodesToStump.append(greaterNode)
                        }
                    }
                    Log.i("Prune check: worse by \(good-bestGood) on \(testData.count) data points")
                }
            }
        }
    }

    Log.i("after pruning, \(origPercentageGood)% to \(bestPercentageGood)%, a \(bestPercentageGood-origPercentageGood)% improvement")
    
    return tree
}

fileprivate let fileManager = FileManager.default
