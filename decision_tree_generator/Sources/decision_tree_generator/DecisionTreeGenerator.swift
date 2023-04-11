import Foundation
import NtarCore
import ArgumentParser
import BinaryCodable
import CryptoKit


let thread_max = 36             // XXX move this

@available(macOS 10.15, *) 
class DecisionTreeGenerator {

    let decisionTypes: [OutlierGroup.TreeDecisionType]
    let decisionSplitTypes: [DecisionSplitType]
    let maxDepth: Int
    
    public init(withTypes types: [OutlierGroup.TreeDecisionType] = OutlierGroup.TreeDecisionType.allCases,
                andSplitTypes splitTypes: [DecisionSplitType] = [.median],
                maxDepth: Int? = nil)
    {
        decisionTypes = types
        decisionSplitTypes = splitTypes
        if let maxDepth = maxDepth {
            self.maxDepth = maxDepth
        } else {
            self.maxDepth = -1  // no limit
        }
    }
    
    // number of levels (groups of '    ') of indentation to start with 
    let initial_indent = 2
    
    // top level func that writes a compilable wrapper around the root tree node
    func generateTree(withPositiveData positive_test_data: [OutlierGroupValueMap],
                      andNegativeData negative_test_data: [OutlierGroupValueMap],
                      inputFilenames: [String],
                      baseFilename: String) async throws -> (String, String)
    {
        let end_time = Date()

        let formatter = DateComponentsFormatter()
        formatter.calendar = Calendar.current
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .full
        let duration_string = formatter.string(from: start_time, to: end_time) ?? "??"

        let indentation = "        "
        var digest = SHA256()

        digest.update(data: Data("\(positive_test_data.count)".utf8))
        digest.update(data: Data("\(negative_test_data.count)".utf8))
        
        var input_files_string = ""
        var input_files_array = "\(indentation)["
        for inputFilename in inputFilenames {
            input_files_string += "     - \(inputFilename)\n"
            input_files_array += "\n\(indentation)    \"\(inputFilename)\","
            digest.update(data: Data(inputFilename.utf8))
        }
        input_files_array.removeLast()
        input_files_array += "\n\(indentation)]"

        let generation_date = Date()

        for type in decisionTypes {
            digest.update(data: Data(type.rawValue.utf8))
        }

        for type in decisionSplitTypes {
            digest.update(data: Data(type.rawValue.utf8))
        }

        digest.update(data: Data("\(maxDepth)".utf8))
        
        let tree_hash = digest.finalize()
        let tree_hash_string = tree_hash.compactMap { String(format: "%02x", $0) }.joined()
        let generation_date_since_1970 = generation_date.timeIntervalSince1970

        var function_signature = ""
        var function_parameters = ""
        var function2_parameters = ""
        
        for type in decisionTypes {
            if type.needsAsync { 
                function_parameters += "            \(type): await self.decisionTreeValue(for: .\(type)),\n"
            } else {
                function_parameters += "            \(type): self.nonAsyncDecisionTreeValue(for: .\(type)),\n"
            }
            function2_parameters += "         \(type): map[.\(type)]!,\n"
            function_signature += "            \(type): Double,\n"
        }
        function_signature.removeLast()        
        function_signature.removeLast()
        function_parameters.removeLast()
        function_parameters.removeLast()
        function2_parameters.removeLast()
        function2_parameters.removeLast()

        let hash_prefix = tree_hash_string.prefix(sha_prefix_size)

        let filename = "\(baseFilename)\(hash_prefix).swift"

        // check to see if this file exists or not
        if file_manager.fileExists(atPath: filename) {
            // Don't do anything
            throw "decision tree already exists at \(filename)"
        }
        
        var decisionTypeString = "    public let decisionTypes: [OutlierGroup.TreeDecisionType] = [\n"
        
        for type in decisionTypes {
            decisionTypeString += "        .\(type.rawValue),\n"
        }
        decisionTypeString.removeLast()
        decisionTypeString.removeLast()
        
        decisionTypeString += "\n    ]\n"
        

        var skippedDecisionTypeString = "    public let notUsedDecisionTypes: [OutlierGroup.TreeDecisionType] = [\n"

        var was_added = false
        for type in OutlierGroup.TreeDecisionType.allCases {
            var should_add = true
            for requestedType in decisionTypes {
                if type == requestedType {
                    should_add = false
                    break
                }
            }
            if should_add {
                was_added = true 
                skippedDecisionTypeString += "        .\(type.rawValue),\n"
            }
        }
        if was_added {
            skippedDecisionTypeString.removeLast()
            skippedDecisionTypeString.removeLast()
        }
        
        skippedDecisionTypeString += "\n    ]\n"



        var decisionSplitTypeString = "    public let decisionSplitTypes: [DecisionSplitType] = [\n"
        
        for type in decisionSplitTypes {
            decisionSplitTypeString += "        .\(type.rawValue),\n"
        }
        decisionSplitTypeString.removeLast()
        decisionSplitTypeString.removeLast()

        decisionSplitTypeString += "\n    ]\n"

        //Log.d("getting root")

        // XXX problem in here somewhere:

        // the root tree node with all of the test data 
        let tree = await decisionTreeNode(with: ThreadSafeArray(positive_test_data),
                                          and: ThreadSafeArray(negative_test_data),
                                          indent: initial_indent)

        // XXX prune this mother fucker with test data
        
        let generated_swift_code = tree.swiftCode

        Log.d("got root")
        
        let swift_string = """
          /*
             auto generated by decision_tree_generator on \(generation_date) in \(duration_string)

             with test data consisting of:
               - \(positive_test_data.count) groups known to be positive
               - \(negative_test_data.count) groups known to be negative

             from input data described by:
          \(input_files_string)
          */

          import Foundation
          import NtarCore
          
          // DO NOT EDIT THIS FILE
          // DO NOT EDIT THIS FILE
          // DO NOT EDIT THIS FILE

          // decide the paintability of this OutlierGroup with a decision tree
          // return value is between -1 and 1, 1 is paint
          @available(macOS 10.15, *)
          extension OutlierGroup {
              public func shouldPaint_\(hash_prefix)(from tree: OutlierGroupDecisionTree_\(hash_prefix)) async -> Double {
                  return tree.shouldPaintFromDecisionTree(
          \(function_parameters)
                  )
              }
          }
          
          @available(macOS 10.15, *)
          public final class OutlierGroupDecisionTree_\(hash_prefix): DecisionTree {
              public init() { }
              public let sha256 = "\(tree_hash_string)"
              public let name = "\(hash_prefix)"
              public let sha256Prefix = "\(hash_prefix)"
              public let maxDepth = \(maxDepth)
              
              public let generationSecondsSince1970 = \(generation_date_since_1970)

              public let inputSequences =
          \(input_files_array)

              // the list of decision types this tree was made with
          \(decisionTypeString)

              // the list of decision types this tree did not use
          \(skippedDecisionTypeString)
          
              // the types of decision splits made
          \(decisionSplitTypeString)

              // decide the paintability of this OutlierGroup with a decision tree
              public func shouldPaintFromDecisionTree(group: OutlierGroup) async -> Double {
                  return await group.shouldPaint_\(hash_prefix)(from: self)
              }

              // a way to call into the decision tree without an OutlierGroup object
              // it's going to blow up unless supplied with the expected set of types
              // return value is between -1 and 1, 1 is paint
              public func shouldPaintFromDecisionTree(
                 types: [OutlierGroup.TreeDecisionType], // parallel
                 values: [Double]                        // arrays
                ) -> Double
              {
                var map: [OutlierGroup.TreeDecisionType:Double] = [:]
                for (index, type) in types.enumerated() {
                    let value = values[index]
                    map[type] = value
                }
                return shouldPaintFromDecisionTree(
          \(function2_parameters)
                )
              }

              // the actual tree resides here
              // return value is between -1 and 1, 1 is paint
              public func shouldPaintFromDecisionTree(
          \(function_signature)
                    ) -> Double
              {
          \(generated_swift_code)
              }
          }
          """

        return (swift_string, filename)
    }

    // recursively return a decision tree that differentiates the test data
    fileprivate func decisionTreeNode(with positive_test_data: ThreadSafeArray<OutlierGroupValueMap>,
                                      and negative_test_data: ThreadSafeArray<OutlierGroupValueMap>,
                                      indent: Int) async -> SwiftDecisionTree
    {
        
        if indent == self.initial_indent {
            Log.i("decisionTreeNode with indent \(indent) positive_test_data.count \(await positive_test_data.count) negative_test_data.count \(await negative_test_data.count)")
        }

        let positive_test_data_count = await positive_test_data.count
        let negative_test_data_count = await negative_test_data.count 
        
        //Log.i("FUCK positive_test_data_count \(positive_test_data_count) negative_test_data_count \(negative_test_data_count)")
        
        if positive_test_data_count == 0,
           negative_test_data_count == 0
        {
            // in this case it's not clear what to return so we blow up
            Log.e("Cannot calculate anything with no input data")
            fatalError("no input data not allowed")
        }
        if positive_test_data_count == 0 {
            // func was called without any data to paint, return don't paint it all
            return FullyNegativeTreeNode(indent: indent)
        }
        if negative_test_data_count == 0 {
            // func was called without any data to not paint, return paint it all
            return FullyPositiveTreeNode(indent: indent)
        }

        // XXX XXX XXX worked here XXX XXX XXX
        
        // this is the 0-1 percentage of positivity
        let original_split =
          Double(positive_test_data_count) /
          Double(negative_test_data_count + positive_test_data_count)

        // we have non zero test data of both kinds
        
        // collate should paint and not paint test data by type
        // look for boundries where we can further isolate 

        // raw values for each type
        // index these by outlierGroup.sortOrder

        let type_count = OutlierGroup.TreeDecisionType.allCases.count
        
        
        // XXX XXX XXX
        // XXX XXX XXX
        // WORKS HERE
        // XXX XXX XXX
        // XXX XXX XXX

        // indexed by outlierGroup.sortOrder
        let positiveValues = await transform(testData: positive_test_data)
        let positiveDist = await getValueDistributions(of: positiveValues)
        
        // indexed by outlierGroup.sortOrder
        let negativeValues = await transform(testData: negative_test_data)
        let negativeDist = await getValueDistributions(of: negativeValues)

        // iterate ofer all decision tree types to pick the best one
        // that differentiates the test data

        // XXX make these return values of the task group below, and
        // XXX put the task group into a separate method

        //Log.d("about to die")


        // XXX XXX XXX
        // XXX XXX XXX
        // XXX XXX XXX
        if false {return FullyNegativeTreeNode(indent: indent)}
        // XXX XXX XXX
        // XXX XXX XXX
        // XXX XXX XXX

        // this one is likely a problem
        let (decisionResults, decisionTreeNodes) = 
          await withLimitedTaskGroup(of: ThreadSafeArray<TreeDecisionTypeResult>.self,
                                     limitedTo: thread_max) { taskGroup in

              var decisionResults = ThreadSafeArray<DecisionResult>()
              var decisionTreeNodes = ThreadSafeArray<TreeDecisionTypeResult>()
              for type in self.decisionTypes {
                  if let paint_dist_FU: ValueDistribution? = await positiveDist.get(at: type.sortOrder),
                     let not_paint_dist_FU: ValueDistribution? = await negativeDist.get(at: type.sortOrder),
                     let paint_dist: ValueDistribution = paint_dist_FU,
                     let not_paint_dist: ValueDistribution = not_paint_dist_FU
                  {
                      await taskGroup.addTask() {
                          //Log.d("type \(type)")
                          if paint_dist.max < not_paint_dist.min {
                              // we have a linear split between all provided test data
                              // this is an end leaf node, both paths after decision lead to a result
                              //Log.d("clear distinction \(paint_dist.max) < \(not_paint_dist.min)")
                              
                              var ret = TreeDecisionTypeResult(type: type)
                              ret.decisionTreeNode =
                                DecisionTreeNode(type: type,
                                                 value: (paint_dist.max + not_paint_dist.min) / 2,
                                                 lessThan: FullyPositiveTreeNode(indent: indent + 1),
                                                 lessThanStumpValue: 1,
                                                 greaterThan: FullyNegativeTreeNode(indent: indent + 1),
                                                 greaterThanStumpValue: -1,
                                                 indent: indent)
                              ret.positiveDist = paint_dist
                              ret.negativeDist = not_paint_dist
                              return ThreadSafeArray([ret])
                          } else if not_paint_dist.max < paint_dist.min {
                              //Log.d("clear distinction \(not_paint_dist.max) < \(paint_dist.min)")
                              // we have a linear split between all provided test data
                              // this is an end leaf node, both paths after decision lead to a result
                              var ret = TreeDecisionTypeResult(type: type)
                              ret.decisionTreeNode =
                                DecisionTreeNode(type: type,
                                                 value: (not_paint_dist.max + paint_dist.min) / 2,
                                                 lessThan: FullyNegativeTreeNode(indent: indent + 1),
                                                 lessThanStumpValue: -1,
                                                 greaterThan: FullyPositiveTreeNode(indent: indent + 1),
                                                 greaterThanStumpValue: 1,
                                                 indent: indent)
                              ret.positiveDist = paint_dist
                              ret.negativeDist = not_paint_dist
                              return ThreadSafeArray([ret])
                          } else {
                              // we do not have a linear split between all provided test data
                              // we need to figure out what type is best to segregate
                              // the test data further

                              // test this type to see how much we can split the data based upon it

                              if indent == self.initial_indent {
                                  Log.d("for \(type) paint_dist min \(paint_dist.min) median \(paint_dist.median) mean \(paint_dist.mean) max \(paint_dist.max) not_paint_dist min \(not_paint_dist.min) mean \(not_paint_dist.mean) median \(not_paint_dist.max) median \(not_paint_dist.max)")
                              }
                              
                              var ret = ThreadSafeArray<TreeDecisionTypeResult>()
                              
                              for splitType in self.decisionSplitTypes {
                                  switch splitType {
                                  case .mean:
                                      let result = await
                                        self.result(for: type,
                                                    decisionValue: (paint_dist.mean + not_paint_dist.mean) / 2,
                                                    withPositiveData: positive_test_data,
                                                    andNegativeData: negative_test_data)
                                      await ret.append(result)

                                  case .median:
                                      let result = await 
                                        self.result(for: type,
                                                    decisionValue: (paint_dist.median + not_paint_dist.median) / 2,
                                                    withPositiveData: positive_test_data,
                                                    andNegativeData: negative_test_data)
                                      await ret.append(result)
                                  }
                              }
                              return ret
                          }
                      }
                  }
              }

              while let responses = await taskGroup.next() {
                  let max = await responses.count
                  
                  for idx in 0..<max {
                      if let response = await responses.get(at: idx) {
                          
                          if let result = response.decisionResult {
                              await decisionResults.append(result)
                          }
                          
                          if let _ = response.decisionTreeNode,
                             let _ = response.positiveDist,
                             let _ = response.negativeDist
                          {
                              await decisionTreeNodes.append(response)
                          }
                      } 
                  }
              }
              return (decisionResults, decisionTreeNodes)
          }
        
        // XXX XXX XXX
        // XXX XXX XXX
        // XXX XXX XXX
        //  dies before here
        // XXX XXX XXX
        // XXX XXX XXX
        // XXX XXX XXX

        
        // XXX XXX XXX
        // XXX XXX XXX
        // XXX XXX XXX
        if false {return FullyNegativeTreeNode(indent: indent)}
        // XXX XXX XXX
        // XXX XXX XXX
        // XXX XXX XXX

        var rankedDecisionResults = ThreadSafeArray<RankedResult<DecisionResult>>()
        var bestTreeNodes = ThreadSafeArray<RankedResult<SwiftDecisionTree>>()

        let number_responses = await decisionTreeNodes.count
        for idx in 0..<number_responses {
            if let response = await decisionTreeNodes.get(at: idx) {

                // these are direct splits that evenly cleave the input data into separate groups
                if let decisionTreeNode = response.decisionTreeNode,
                   let paint_dist = response.positiveDist,
                   let not_paint_dist = response.negativeDist
                {
                    // check each direct decision result and choose the best one
                    // based upon the difference between their edges and their means
                    if paint_dist.max < not_paint_dist.min {
                        let split =
                          (not_paint_dist.min - paint_dist.max) /
                          (not_paint_dist.median - paint_dist.median)
                        let result = RankedResult(rank: split,
                                                  type: response.type,
                                                  result: decisionTreeNode)
                        await bestTreeNodes.append(result)
                    } else if not_paint_dist.max < paint_dist.min {
                        let split =
                          (paint_dist.min - not_paint_dist.max) /
                          (paint_dist.median - not_paint_dist.median)
                        let result = RankedResult(rank: split,
                                                  type: response.type,
                                                  result: decisionTreeNode)
                        await bestTreeNodes.append(result)
                    }
                }
            }
        }

        // XXX died here XXX
        
        let max = await decisionResults.count
        for idx in 0..<max {
            let decisionResult = await decisionResults.get(at: idx)!
            // these are tree nodes that require recursion
            
            // choose the type with the best distribution 
            // that will generate the shortest tree
            if decisionResult.lessThanSplit > original_split {
                // the less than split is biggest so far
                let split = decisionResult.lessThanSplit - original_split
                
                await rankedDecisionResults.append(RankedResult(rank: split,
                                                                type: decisionResult.type,
                                                                result: decisionResult)) 
                
            }
            if decisionResult.greaterThanSplit > original_split {
                // the greater than split is biggest so far
                let split = decisionResult.greaterThanSplit - original_split
                
                await rankedDecisionResults.append(RankedResult(rank: split,
                                                                type: decisionResult.type,
                                                                result: decisionResult)) 
            }
        }
        //        }

        // return a direct tree node if we have it (no recursion)
        // make sure we choose the best one of theese
        if await bestTreeNodes.count != 0 {
            if await bestTreeNodes.count == 1 {
                return await bestTreeNodes.get(at: 0)!.result
            } else {
                // here we need to determine between them
                // current approach is to sort first by rank,
                // grouping identical first ranks into a group
                // which is then sorted now by type

                let sorted = await bestTreeNodes.sorted { lhs, rhs in
                    return lhs.rank > rhs.rank
                }

                var maxList: [RankedResult<SwiftDecisionTree>] = [await sorted.get(at: 0)!]

                if let initial = await sorted.get(at: 0) {
                    let max = await sorted.count
                    for i in 1..<max {
                        if let item = await sorted.get(at: i) {
                            if item.rank == initial.rank {
                                maxList.append(item)
                            }
                        }
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
        let rankedDecisionResultsCount = await rankedDecisionResults.count
        if rankedDecisionResultsCount != 0 {
            let rankedDecisionResultsCount = await rankedDecisionResults.count
            if rankedDecisionResultsCount == 1 {
                return await recurseOn(result: await rankedDecisionResults.get(at: 0)!.result, indent: indent)
            } else {
                // choose the first one somehow
                let sorted = await rankedDecisionResults.sorted { lhs, rhs in
                    return lhs.rank > rhs.rank
                }
                
                var maxList: [RankedResult<DecisionResult>] = [await sorted.get(at: 0)!]
                
                if let initial = await sorted.get(at: 0) {
                    let max = await sorted.count
                    for i in 1..<max {
                        if let item = await sorted.get(at: i) {
                            if item.rank == initial.rank {
                                maxList.append(item)
                            }
                        }
                    }
                }

                if maxList.count == 1 {
                    
                    if indent == self.initial_indent {
                        Log.i("maxlist count is one, using type \(maxList[0].result.type)")
                    }
                    // sorting by rank gave us just one
                    return await recurseOn(result: maxList[0].result, indent: indent) // XXX
                } else {
                    // sort them by type next

                    // XXX maybe sort by something else?

                    let maxSort = maxList.sorted { $0.type < $1.type }

                    if indent == self.initial_indent {
                        Log.i("sorted by type is one, using type \(maxSort[0].result.type)")
                    }
                    
                    return await recurseOn(result: maxSort[0].result, indent: indent) // XXX
                }
            }
        } else {
            Log.e("no best type, defaulting to false :(")
            return FullyNegativeTreeNode(indent: indent + 1)
        }
    }

    // XXX document what this does
    fileprivate func getValueDistributions(of values: ThreadSafeArray<ThreadSafeArray<Double>>)
      async -> ThreadSafeArray<ValueDistribution?>
    {
        return await withLimitedTaskGroup(of: ValueDistribution.self,
                                          limitedTo: thread_max) { taskGroup in
            let type_count = OutlierGroup.TreeDecisionType.allCases.count
            var array = [ValueDistribution?](repeating: nil, count: type_count)
            // for each type, calculate a min/max/mean/median for both paint and not
            for type in decisionTypes {
                if let all_values = await values.get(at: type.sortOrder) {
                    await taskGroup.addTask() {
                        var min = Double.greatestFiniteMagnitude
                        var max = -Double.greatestFiniteMagnitude
                        var sum = 0.0
                        //Log.d("all values for paint \(type): \(all_values)")

                        let count = await all_values.count
                        for idx in 0..<count {
                            if let value = await all_values.get(at: idx) {
                                if value < min { min = value }
                                if value > max { max = value }
                                sum += value
                            }
                        }
                        sum /= Double(await all_values.count)                           // VV ??
                        let median = await all_values.sorted().get(at: all_values.count/2) ?? 0
                        return ValueDistribution(type: type, min: min, max: max,
                                                 mean: sum, median: median)
                    }
                }
            }
            while let response = await taskGroup.next() {
                array[response.type.sortOrder] = response
            }
            return ThreadSafeArray(array)
        }
    }
    
    // XXX document what this does
    fileprivate func transform(testData: ThreadSafeArray<OutlierGroupValueMap>) 
      async -> ThreadSafeArray<ThreadSafeArray<Double>>
    {
        return await withLimitedTaskGroup(of: DecisionTypeValuesResult.self,
                                          limitedTo: thread_max) { taskGroup in
            let type_count = OutlierGroup.TreeDecisionType.allCases.count
            var array = [ThreadSafeArray<Double>](repeating: ThreadSafeArray<Double>([]),
                                                  count: type_count)
            for type in decisionTypes {
                await taskGroup.addTask() {
                    var list: [Double] = []
                    let max = await testData.count
                    for idx in 0..<max {
                        if let testData = await testData.get(at: idx),
                           let value = await testData.get(at: type.sortOrder)
                        {
                            list.append(value)
                        }
                    }
                    return DecisionTypeValuesResult(type: type, values: ThreadSafeArray(list))
                }
            }
            
            while let response = await taskGroup.next() {
                array[response.type.sortOrder] = response.values
            }
            return ThreadSafeArray(array)
        }
    }

    // XXX document what this does
    fileprivate func recurseOn(result: DecisionResult, indent: Int) async -> DecisionTreeNode {
        //Log.d("best at indent \(indent) was \(result.type) \(String(format: "%g", result.lessThanSplit)) \(String(format: "%g", result.greaterThanSplit)) \(String(format: "%g", result.value)) < Should \(await result.lessThanPositive.count) < ShouldNot \(await result.lessThanNegative.count) > Should  \(await result.lessThanPositive.count) > ShouldNot \(await result.greaterThanNegative.count)")

        // we've identified the best type to differentiate the test data
        // output a tree node with this type and value
        var less_response: TreeResponse?
        var greater_response: TreeResponse?

        let lessThanPaintCount = await result.lessThanPositive.count
        let lessThanNotPaintCount = await result.lessThanNegative.count

        let greaterThanPaintCount = await result.greaterThanPositive.count
        let greaterThanNotPaintCount = await result.greaterThanNegative.count

        let paintMax = Double(lessThanPaintCount+greaterThanPaintCount)
        let notPaintMax = Double(lessThanNotPaintCount+greaterThanNotPaintCount)

        // divide by max to even out 1/10 disparity in true/false data
        let lessThanPaintDiv = Double(lessThanPaintCount)/paintMax
        let greaterThanPaintDiv = Double(greaterThanPaintCount)/paintMax
        
        let lessThanStumpValue = lessThanPaintDiv / (lessThanPaintDiv + Double(lessThanNotPaintCount)/notPaintMax) * 2 - 1

        Log.i("lessThanPaintCount \(lessThanPaintCount) lessThanNotPaintCount \(lessThanNotPaintCount) lessThanStumpValue \(lessThanStumpValue)")


        let greaterThanStumpValue = greaterThanPaintDiv / (greaterThanPaintDiv + Double(greaterThanNotPaintCount)/notPaintMax) * 2 - 1
        
        Log.i("greaterThanPaintCount \(greaterThanPaintCount) greaterThanNotPaintCount \(greaterThanNotPaintCount) greaterThanStumpValue \(greaterThanStumpValue)")

        if at(max: indent + 2) {
            // stump, don't extend the tree branches further
            var ret = DecisionTreeNode(type: result.type,
                                       value: result.value,
                                       lessThan: FullyPositiveTreeNode(indent: 0), // not used
                                       lessThanStumpValue: lessThanStumpValue,
                                       greaterThan: FullyPositiveTreeNode(indent: 0), // not used
                                       greaterThanStumpValue: greaterThanStumpValue,
                                       indent: indent/* + 1*/)
            ret.stump = true 
            return ret
        } else {
            (less_response, greater_response) = 
              await withLimitedTaskGroup(of: TreeResponse.self,
                                         limitedTo: thread_max) { taskGroup in
                  
                  await taskGroup.addTask() {
                      let less_tree = await self.decisionTreeNode(with: result.lessThanPositive,
                                                                  and: result.lessThanNegative,
                                                                  indent: indent + 1)
                      return TreeResponse(treeNode: less_tree, position: .less,
                                          stumpValue: lessThanStumpValue)
                  }
                  await taskGroup.addTask() {
                      let greater_tree = await self.decisionTreeNode(with: result.greaterThanPositive,
                                                                     and: result.greaterThanNegative,
                                                                     indent: indent + 1)
                      return TreeResponse(treeNode: greater_tree, position: .greater,
                                          stumpValue: greaterThanStumpValue)
                  }
                  
                  var less_response: TreeResponse?
                  var greater_response: TreeResponse?
                  
                  while let response = await taskGroup.next() {
                      switch response.position {
                      case .less:
                          less_response = response
                      case .greater:
                          greater_response = response
                      }
                  }
                  return (less_response, greater_response)
              }
        }
        //Log.d("WTF")
        
        if let less_response = less_response,
           let greater_response = greater_response
        {
            var ret = DecisionTreeNode(type: result.type,
                                       value: result.value,
                                       lessThan: less_response.treeNode,
                                       lessThanStumpValue: less_response.stumpValue,
                                       greaterThan: greater_response.treeNode,
                                       greaterThanStumpValue: greater_response.stumpValue,
                                       indent: indent)

            return ret
        } else {
            Log.e("holy fuck")
            fatalError("doh")
        }
    }

    fileprivate func at(max indent: Int) -> Bool {
        if maxDepth < 0 { return false } // no limit
        return indent - initial_indent > maxDepth
    }
    
    fileprivate func result(for type: OutlierGroup.TreeDecisionType,
                            decisionValue: Double,
                            withPositiveData positive_test_data: ThreadSafeArray<OutlierGroupValueMap>,
                            andNegativeData negative_test_data: ThreadSafeArray<OutlierGroupValueMap>)
      async -> TreeDecisionTypeResult
    {
        let lessThanPositive = ThreadSafeArray<OutlierGroupValueMap>()
        let lessThanNegative = ThreadSafeArray<OutlierGroupValueMap>()
        
        let greaterThanPositive = ThreadSafeArray<OutlierGroupValueMap>()
        let greaterThanNegative = ThreadSafeArray<OutlierGroupValueMap>()
        
        // calculate how the data would split if we used the above decision value

        // XXX XXX XXX
        // CRASH START
        // XXX XXX XXX

        let positive_test_data_count = await positive_test_data.count
        for index in 0..<positive_test_data_count {
            if let group_values = await positive_test_data.get(at: index),
               let group_value = await group_values.get(at: type.sortOrder) // crash here
            {
        /**/
                if group_value < decisionValue {
                    await lessThanPositive.append(group_values)
                } else {
                    await greaterThanPositive.append(group_values)
                }
/*         */

            }
        }
        // XXX XXX XXX
        // CRASH END
        // XXX XXX XXX
/**/

        let negative_test_data_count = await negative_test_data.count 
        for index in 0..<negative_test_data_count {
            if let group_values = await negative_test_data.get(at: index),
               let group_value = await group_values.get(at: type.sortOrder)
            {
                if group_value < decisionValue {
                    await lessThanNegative.append(group_values)
                } else {
                    await greaterThanNegative.append(group_values)
                }

            }
        }
/*  */      
        var ret = TreeDecisionTypeResult(type: type)
        ret.decisionResult =
          await DecisionResult(type: type,
                               value: decisionValue,
                               lessThanPositive: lessThanPositive,
                               lessThanNegative: lessThanNegative,
                               greaterThanPositive: greaterThanPositive,
                               greaterThanNegative: greaterThanNegative)

        return ret
    }
}


@available(macOS 10.15, *) 
fileprivate struct RankedResult<T>: Comparable {
    let rank: Double
    let type: OutlierGroup.TreeDecisionType
    let result: T

    public static func ==(lhs: RankedResult<T>, rhs: RankedResult<T>) -> Bool {
        return lhs.rank == rhs.rank
    }
    
    public static func <(lhs: RankedResult<T>, rhs: RankedResult<T>) -> Bool {
        return lhs.rank < rhs.rank
    }        
}

@available(macOS 10.15, *) 
fileprivate struct DecisionTypeValuesResult {
    let type: OutlierGroup.TreeDecisionType
    let values: ThreadSafeArray<Double>
}

@available(macOS 10.15, *) 
fileprivate struct TreeDecisionTypeResult {
    init(type: OutlierGroup.TreeDecisionType) {
        self.type = type
    }
    let type: OutlierGroup.TreeDecisionType
    var decisionResult: DecisionResult?
    var decisionTreeNode: SwiftDecisionTree?
    var positiveDist: ValueDistribution?
    var negativeDist: ValueDistribution?
}

@available(macOS 10.15, *) 
fileprivate struct ValueDistribution {
    let type: OutlierGroup.TreeDecisionType
    let min: Double
    let max: Double
    let mean: Double
    let median: Double
}

@available(macOS 10.15, *) 
fileprivate struct TreeResponse {
    enum Place {
        case less
        case greater
    }
    
    let treeNode: SwiftDecisionTree
    let position: Place
    let stumpValue: Double
}
    
@available(macOS 10.15, *) 
fileprivate struct DecisionResult {
    let type: OutlierGroup.TreeDecisionType
    let value: Double
    let lessThanPositive: ThreadSafeArray<OutlierGroupValueMap>
    let lessThanNegative: ThreadSafeArray<OutlierGroupValueMap>
    let greaterThanPositive: ThreadSafeArray<OutlierGroupValueMap>
    let greaterThanNegative: ThreadSafeArray<OutlierGroupValueMap>
    let lessThanSplit: Double
    let greaterThanSplit: Double
    
    public init(type: OutlierGroup.TreeDecisionType,
                value: Double = 0,
                lessThanPositive: ThreadSafeArray<OutlierGroupValueMap>,
                lessThanNegative: ThreadSafeArray<OutlierGroupValueMap>,
                greaterThanPositive: ThreadSafeArray<OutlierGroupValueMap>,
                greaterThanNegative: ThreadSafeArray<OutlierGroupValueMap>) async
    {

        self.type = type
        self.value = value
        self.lessThanPositive = lessThanPositive
        self.lessThanNegative = lessThanNegative
        self.greaterThanPositive = greaterThanPositive
        self.greaterThanNegative = greaterThanNegative

        let lessThanPositiveCount = await lessThanPositive.count
        let lessThanNegativeCount = await lessThanNegative.count
        let greaterThanPositiveCount = await greaterThanPositive.count
        let greaterThanNegativeCount = await greaterThanNegative.count
        
        // XXX somehow factor in how far away the training data is from the split as well?
        
        // this is the 0-1 percentage of positive on the less than split
        self.lessThanSplit =
          Double(lessThanPositiveCount) /
          Double(lessThanNegativeCount + lessThanPositiveCount)

        // this is the 0-1 percentage of positive on the greater than split
        self.greaterThanSplit =
          Double(greaterThanPositiveCount) /
          Double(greaterThanNegativeCount + greaterThanPositiveCount)
    }
}

fileprivate let file_manager = FileManager.default
