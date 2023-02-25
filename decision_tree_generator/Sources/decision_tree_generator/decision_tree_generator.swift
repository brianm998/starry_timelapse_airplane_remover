import Foundation
import NtarCore
import ArgumentParser

@available(macOS 10.15, *) 
struct OutlierGroupValues {
    var values: [OutlierGroup.DecisionTreeCharacteristic: Double] = [:]
}

@main
@available(macOS 10.15, *) 
struct decision_tree_generator: ParsableCommand {

    @Argument(help: """
        fill this shit in better sometime later
        """)
    var json_config_file_names: [String]
    
    mutating func run() throws {
        Log.handlers[.console] = ConsoleLogHandler(at: .debug)

        Log.i("Starting")
        generate_tree()
    }

    func generate_tree() {
        let dispatch_group = DispatchGroup()
        dispatch_group.enter()
        Task {
            var should_paint_test_data: [OutlierGroupValues] = []
            var should_not_paint_test_data: [OutlierGroupValues] = []
            
            for json_config_file_name in json_config_file_names {
                Log.d("should read \(json_config_file_name)")
                
                do {
                    let config = try await Config.read(fromFilename: json_config_file_name)
                    Log.d("got config from \(json_config_file_name)")
                    
                    var callbacks = Callbacks()

                    var frames: [FrameAirplaneRemover] = []
                    
                    var endClosure: () -> Void = { }
                    
                    // called when we should check a frame
                    callbacks.frameCheckClosure = { new_frame in
                        frames.append(new_frame)
                        endClosure()
                        Log.d("frameCheckClosure for frame \(new_frame.frame_index)")
                    }
                    
                    // XXX is this VVV obsolete???
                    callbacks.countOfFramesToCheck = { 1 }

                    let eraser = try NighttimeAirplaneRemover(with: config,
                                                              callbacks: callbacks,
                                                              processExistingFiles: true,
                                                              fullyProcess: false)
                    let sequence_size = await eraser.image_sequence.filenames.count
                    endClosure = {
                        if frames.count == sequence_size {
                            Log.i("stopping that shit")
                            eraser.shouldRun = false
                        }
                    }
                    
                    Log.i("got \(sequence_size) frames")
                    // XXX run it and get the outlier groups

                    try eraser.run()

                    if let image_width = eraser.image_width,
                       let image_height = eraser.image_height
                    {
                        // load the outliers in parallel
                        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                            for frame in frames {
                                taskGroup.addTask(/*priority: .medium*/) {
                                    try await frame.loadOutliers()
                                }
                            }
                            try await taskGroup.waitForAll()
                        }
                        for frame in frames {
                            // iterate through all outliers
                            if let outlier_groups = await frame.outlierGroups() {
                                for outlier_group in outlier_groups {
                                    let name = await outlier_group.name
                                    if let should_paint = await outlier_group.shouldPaint {
                                        let will_paint = should_paint.willPaint
                                        var values = OutlierGroupValues()
                                        
                                        for characteristic in OutlierGroup.DecisionTreeCharacteristic.allCases {
                                            let value = await outlier_group.decisionTreeValue(for: characteristic)
                                            switch characteristic {
                                            case .size:
                                                values.values[characteristic] = value
                                            case .width:
                                                values.values[characteristic] = value
                                            case .height:
                                                values.values[characteristic] = value
                                            case .centerX:
                                                values.values[characteristic] = value/Double(image_width)
                                            case .centerY:
                                                values.values[characteristic] = value/Double(image_height)
                                            }
                                        }
                                        if will_paint {
                                            should_paint_test_data.append(values)
                                        } else {
                                            should_not_paint_test_data.append(values)
                                        }
                                    } else {
                                        Log.e("outlier group \(name) has no shouldPaint value")
                                    }
                                }
                            } else {
                                Log.e("cannot get outlier groups for frame \(frame.frame_index)")
                            }
                        }
                    } else {
                        Log.e("couldn't read image height and/or width")
                    }
                } catch {
                    Log.w("couldn't get config from \(json_config_file_name)")
                    Log.e("\(error)")
                }
            }
            Log.i("Calculating decision tree with \(should_paint_test_data.count) should paint \(should_not_paint_test_data.count) should not paint test data outlier groups")
            
            writeTree(should_paint_test_data: should_paint_test_data,
                      should_not_paint_test_data: should_not_paint_test_data)

            dispatch_group.leave()
        }
        dispatch_group.wait()
    }

    func writeTree(should_paint_test_data: [OutlierGroupValues],
                   should_not_paint_test_data: [OutlierGroupValues])
    {

        let tree = decisionTreeNode(should_paint_test_data: should_paint_test_data,
                                    should_not_paint_test_data: should_not_paint_test_data,
                                    indent: 1)

        print("""
                @available(macOS 10.15, *)
                func shouldPaint(outlier_group: OutlierGroup) async -> Bool {
                \(tree.writeNode())
                }
                """)
    }

    func decisionTreeNode(should_paint_test_data: [OutlierGroupValues],
                          should_not_paint_test_data: [OutlierGroupValues],
                          indent: Int) -> DecisionTree
    {
        Log.i("decisionTreeNode with indent \(indent)")

        if should_paint_test_data.count == 0,
           should_not_paint_test_data.count == 0
        {
            Log.e("FUCK")
            fatalError("two zeros not allowed")
        }
        if should_paint_test_data.count == 0 {
            return ShouldNotPaintDecision(indent: indent)
        }
        if should_not_paint_test_data.count == 0 {
            return ShouldPaintDecision(indent: indent)
        }
        
        // collate should paint and not paint test data by characteristic
        // look for boundries where we can further isolate 

        // raw values for each characteristic
        var should_paint_values: [OutlierGroup.DecisionTreeCharacteristic: [Double]] = [:]
        var should_not_paint_values: [OutlierGroup.DecisionTreeCharacteristic: [Double]] = [:]
        for characteristic in OutlierGroup.DecisionTreeCharacteristic.allCases {
            should_paint_values[characteristic] = []
            should_not_paint_values[characteristic] = []
        }
        
        for characteristic in OutlierGroup.DecisionTreeCharacteristic.allCases {
            for test_data in should_paint_test_data {
                if let value = test_data.values[characteristic] {
                    if var list = should_paint_values[characteristic] {
                        list.append(value)
                        should_paint_values[characteristic] = list
                    } else {
                        should_paint_values[characteristic] = [value]
                    }
                } 
            }
        }

        for characteristic in OutlierGroup.DecisionTreeCharacteristic.allCases {
            for test_data in should_not_paint_test_data {
                if let value = test_data.values[characteristic] {
                    if var list = should_not_paint_values[characteristic] {
                        list.append(value)
                        should_not_paint_values[characteristic] = list
                    } else {
                        should_not_paint_values[characteristic] = [value]
                    }
                }
            }
        }

        // value distributions for each characteristic
        var should_paint_dist: [OutlierGroup.DecisionTreeCharacteristic: ValueDistribution] = [:]
        var should_not_paint_dist: [OutlierGroup.DecisionTreeCharacteristic: ValueDistribution] = [:]
        
        // for each characteristic, calculate a min/max/mean/median for both paint and not
        for characteristic in OutlierGroup.DecisionTreeCharacteristic.allCases {
            var min = Double.greatestFiniteMagnitude
            var max = -Double.greatestFiniteMagnitude
            var sum = 0.0
            if let all_values = should_paint_values[characteristic] {
                Log.d("all values for paint \(characteristic): \(all_values)")
                for value in all_values {
                    if value < min { min = value }
                    if value > max { max = value }
                    sum += value
                }
                sum /= Double(all_values.count)
                let median = all_values.sorted()[all_values.count/2]
                let dist = ValueDistribution(min: min, max: max, mean: sum, median: median)
                should_paint_dist[characteristic] = dist
            } else {
                Log.e("WTF")
            }
        }

        // XXX dupe above for not paint
        for characteristic in OutlierGroup.DecisionTreeCharacteristic.allCases {
            var min = Double.greatestFiniteMagnitude
            var max = -Double.greatestFiniteMagnitude
            var sum = 0.0
            if let all_values = should_not_paint_values[characteristic] {
                Log.d("all values for not paint \(characteristic): \(all_values)")
                for value in all_values {
                    if value < min { min = value }
                    if value > max { max = value }
                    sum += value
                }
                sum /= Double(all_values.count)
                let median = all_values.sorted()[all_values.count/2]
                let dist = ValueDistribution(min: min, max: max, mean: sum, median: median)
                should_not_paint_dist[characteristic] = dist
            } else {
                Log.e("WTF")
            }
        }

        // vars used to construct the next tree node
        var bestCharacteristic: OutlierGroup.DecisionTreeCharacteristic?
        var bestValue: Double = 0
        var less_than_should_paint_test_data: [OutlierGroupValues] = []
        var less_than_should_not_paint_test_data: [OutlierGroupValues] = []
        var greater_than_should_paint_test_data: [OutlierGroupValues] = []
        var greater_than_should_not_paint_test_data: [OutlierGroupValues] = []

        var biggest_split = 0.0

        // iterate ofer all decision tree characteristics to pick the best one
        // that differentiates the test data
        for characteristic in OutlierGroup.DecisionTreeCharacteristic.allCases {
            if let paint_dist = should_paint_dist[characteristic],
               let not_paint_dist = should_not_paint_dist[characteristic]
            {
                Log.d("characteristic \(characteristic)")
                if paint_dist.max < not_paint_dist.min {
                    // we have a clear distinction between all provided test data
                    // this is an end leaf node, both paths after decision lead to a result
                    Log.d("clear distinction \(paint_dist.max) < \(not_paint_dist.min)")
                    return DecisionTreeNode(characteristic: characteristic,
                                            value: (paint_dist.max + not_paint_dist.min) / 2,
                                            lessThan: ShouldPaintDecision(indent: indent + 1),
                                            greaterThan: ShouldNotPaintDecision(indent: indent + 1),
                                            indent: indent)
                } else if not_paint_dist.max < paint_dist.min {
                    Log.d("clear distinction \(not_paint_dist.max) < \(paint_dist.min)")
                    // we have a clear distinction between all provided test data
                    // this is an end leaf node, both paths after decision lead to a result
                    return DecisionTreeNode(characteristic: characteristic,
                                            value: (not_paint_dist.max + paint_dist.min) / 2,
                                            lessThan: ShouldNotPaintDecision(indent: indent + 1),
                                            greaterThan: ShouldPaintDecision(indent: indent + 1),
                                            indent: indent)
                } else {
                    Log.d("no clear distinction, need new node at indent \(indent)")
                    // we do not have a clear distinction between all provided test data
                    // we need to figure out what characteristic is best to segarate
                    // the test data further

                    // test this characteristic to see how much we can split the data based upon it

                    // for now, center between their medians
                    // possible improvement is to decide based upon something else
                    // use this value to split the should_paint_test_data and not paint
                    let decisionValue = (paint_dist.median + not_paint_dist.median) / 2

                    var lessThanShouldPaint: [OutlierGroupValues] = []
                    var lessThanShouldNotPaint: [OutlierGroupValues] = []

                    var greaterThanShouldPaint: [OutlierGroupValues] = []
                    var greaterThanShouldNotPaint: [OutlierGroupValues] = []

                    // calculate how the data would split if we used the above decision value
                    for group_values in should_paint_test_data {
                        if let group_value = group_values.values[characteristic] {
                            if group_value < decisionValue {
                                lessThanShouldPaint.append(group_values)
                            } else {
                                greaterThanShouldPaint.append(group_values)
                            }
                        } else {
                            Log.e("FUCK")
                            fatalError("SHIT")
                        }
                    }
                    
                    for group_values in should_not_paint_test_data {
                        if let group_value = group_values.values[characteristic] {
                            if group_value < decisionValue {
                                lessThanShouldNotPaint.append(group_values)
                            } else {
                                greaterThanShouldNotPaint.append(group_values)
                            }
                        } else {
                            Log.e("FUCK")
                            fatalError("SHIT")
                        }
                    }

                    // this is the 0-1 percentage of should_paint
                    let original_split = Double(should_paint_test_data.count)/Double(should_not_paint_test_data.count)

                    // this is the 0-1 percentage of should_paint on the less than split
                    let less_than_split = Double(lessThanShouldPaint.count)/Double(lessThanShouldNotPaint.count)

                    // this is the 0-1 percentage of should_paint on the greater than split
                    let greater_than_split = Double(greaterThanShouldPaint.count)/Double(greaterThanShouldNotPaint.count)

                    var we_are_best = false
                    
                    // choose the characteristic with the best distribution 
                    // that will generate the shortest tree
                    if less_than_split > original_split,
                       less_than_split - original_split > biggest_split
                    {
                        // the less than split is biggest so far
                        biggest_split = less_than_split - original_split
                        we_are_best = true
                    } else if greater_than_split > original_split,
                              greater_than_split - original_split > biggest_split
                    {
                        // the greater than split is biggest so far
                        biggest_split = greater_than_split - original_split
                        we_are_best = true
                    }
                    if we_are_best {
                        // record this characteristic as best so far
                        bestCharacteristic = characteristic
                        bestValue = decisionValue
                        less_than_should_paint_test_data = lessThanShouldPaint
                        less_than_should_not_paint_test_data = lessThanShouldNotPaint
                        greater_than_should_paint_test_data = greaterThanShouldPaint
                        greater_than_should_not_paint_test_data = greaterThanShouldNotPaint
                    }
                    
                    Log.i("for characteristic \(characteristic) original split is \(original_split) less than split is \(less_than_split) greater than split is \(greater_than_split)")
                }
            } else {
                Log.e("WTF")
                fatalError("no best characteristic")
            }
        }

        if let bestCharacteristic = bestCharacteristic {
            // we've identified the best characteristic to differentiate the test data
            // output a tree node with this characteristic and value

            // first recurse on both sides of the decision tree with differentated test data
            let less_tree = self.decisionTreeNode(should_paint_test_data: less_than_should_paint_test_data,
                                                  should_not_paint_test_data: less_than_should_not_paint_test_data,
                                                  indent: indent + 1)

            let greater_tree = self.decisionTreeNode(should_paint_test_data: greater_than_should_paint_test_data,
                                                     should_not_paint_test_data: greater_than_should_not_paint_test_data,
                                                     indent: indent + 1)

            
            return DecisionTreeNode(characteristic: bestCharacteristic,
                                    value: bestValue,
                                    lessThan: less_tree,
                                    greaterThan: greater_tree,
                                    indent: indent)
        } else {
            Log.e("no best characteristic")
            fatalError("no best characteristic")
        }
        
    }
}

struct ValueDistribution {
    let min: Double
    let max: Double
    let mean: Double
    let median: Double
}

protocol DecisionTree {
    func writeNode() -> String 
}

struct ShouldPaintDecision: DecisionTree {
    let indent: Int
    func writeNode() -> String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return true"
    }
}

struct ShouldNotPaintDecision: DecisionTree {
    let indent: Int
    func writeNode() -> String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return false"
    }
}

@available(macOS 10.15, *) 
struct DecisionTreeNode: DecisionTree {
    let characteristic: OutlierGroup.DecisionTreeCharacteristic
    let value: Double
    let lessThan: DecisionTree
    let greaterThan: DecisionTree
    let indent: Int
    
    // assumes outlier_group variable
    func writeNode() -> String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return """
          \(indentation)if await outlier_group.decisionTreeValue(for: .\(characteristic)) < \(value) {
          \(lessThan.writeNode())
          \(indentation)} else {
          \(greaterThan.writeNode())
          \(indentation)}
          """
    }
}
