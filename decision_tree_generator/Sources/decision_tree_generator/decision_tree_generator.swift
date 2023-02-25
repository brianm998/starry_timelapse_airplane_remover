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
        Log.handlers[.console] = ConsoleLogHandler(at: .verbose)

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
                        for frame in frames {
                            try await frame.loadOutliers()
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
            Log.d("we have \(should_paint_test_data.count) should paint test data outlier groups")
            Log.d("we have \(should_not_paint_test_data.count) should not paint test data outlier groups")
            
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
        if should_paint_test_data.count == 0 {
            return ShouldNotPaintDecision(indent: indent+1)
        }
        // XXX what if they're both zero?
        if should_not_paint_test_data.count == 0 {
            return ShouldPaintDecision(indent: indent+1)
        }
        
        // collate should paint and not paint test data by characteristic
        // look for boundries where we can further isolate 

        // raw values for each characteristic
        var should_paint_values: [OutlierGroup.DecisionTreeCharacteristic: [Double]] = [:]
        var should_not_paint_values: [OutlierGroup.DecisionTreeCharacteristic: [Double]] = [:]
        
        for characteristic in OutlierGroup.DecisionTreeCharacteristic.allCases {
            for test_data in should_paint_test_data {
                if let value = test_data.values[characteristic] {
                    if var list = should_paint_values[characteristic] {
                        list.append(value)
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

        var bestCharacteristic: OutlierGroup.DecisionTreeCharacteristic = .size
        var bestValue: Double = 0
        var lessThanTree: DecisionTree = ShouldNotPaintDecision(indent: 0)
        var greaterThanTree: DecisionTree = ShouldNotPaintDecision(indent: 0)
        
        for characteristic in OutlierGroup.DecisionTreeCharacteristic.allCases {
            //if characteristic == bestCharacteristic { continue }
            if let paint_dist = should_paint_dist[characteristic],
               let not_paint_dist = should_not_paint_dist[characteristic]
            {
                if paint_dist.max < not_paint_dist.min {
                    bestCharacteristic = characteristic
                    bestValue = (paint_dist.max + not_paint_dist.min) / 2
                    lessThanTree = ShouldPaintDecision(indent: indent + 1)
                    greaterThanTree = ShouldNotPaintDecision(indent: indent + 1)
                    break
                } else if not_paint_dist.max < paint_dist.min {
                    bestCharacteristic = characteristic
                    bestValue = (paint_dist.max + not_paint_dist.min) / 2
                    lessThanTree = ShouldNotPaintDecision(indent: indent + 1)
                    greaterThanTree = ShouldPaintDecision(indent: indent + 1)
                    break
                } else {
                    
                    Log.e("FUCK, IMPLEMENT THIS")


                    /*
                     here we need to keep track of how good a match this would have been,
                     then decide upon the best one
                     */
                }
            } else {
                Log.e("WTF")
            }
        }
        // choose the characteristic with the best distribution 
        // that will generate the shortest tree
        
        let tree = DecisionTreeNode(characteristic: bestCharacteristic,
                                    value: bestValue,
                                    lessThan: lessThanTree,
                                    greaterThan: greaterThanTree,
                                    indent: indent)
        return tree
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
