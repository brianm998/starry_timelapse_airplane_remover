import Foundation
import NtarCore
import ArgumentParser

@available(macOS 10.15, *) 
struct OutlierGroupValues {
    var values: [OutlierGroup.TreeDecisionType: Double] = [:]
}

var start_time: Date = Date()

@available(macOS 10.15, *) 
struct TreeDecisionTypeResult {
    var decisionResult: DecisionResult?
    var decisionTreeNode: DecisionTree?
}

// use this for with the taskgroup below
@available(macOS 10.15, *) 
struct DecisionResult {
    let type: OutlierGroup.TreeDecisionType
    let value: Double
    let lessThanShouldPaint: [OutlierGroupValues]
    let lessThanShouldNotPaint: [OutlierGroupValues]
    let greaterThanShouldPaint: [OutlierGroupValues]
    let greaterThanShouldNotPaint: [OutlierGroupValues]
    let lessThanSplit: Double
    let greaterThanSplit: Double
    
    public init(type: OutlierGroup.TreeDecisionType,
                value: Double = 0,
                lessThanShouldPaint: [OutlierGroupValues],
                lessThanShouldNotPaint: [OutlierGroupValues],
                greaterThanShouldPaint: [OutlierGroupValues],
                greaterThanShouldNotPaint: [OutlierGroupValues])
    {

        self.type = type
        self.value = value
        self.lessThanShouldPaint = lessThanShouldPaint
        self.lessThanShouldNotPaint = lessThanShouldNotPaint
        self.greaterThanShouldPaint = greaterThanShouldPaint
        self.greaterThanShouldNotPaint = greaterThanShouldNotPaint
        // this is the 0-1 percentage of should_paint on the less than split
        self.lessThanSplit =
          Double(lessThanShouldPaint.count) /
          Double(lessThanShouldNotPaint.count + lessThanShouldPaint.count)

        // this is the 0-1 percentage of should_paint on the greater than split
        self.greaterThanSplit =
          Double(greaterThanShouldPaint.count) /
          Double(greaterThanShouldNotPaint.count + greaterThanShouldPaint.count)
    }
}

@main
@available(macOS 10.15, *) 
struct decision_tree_generator: ParsableCommand {

    @Flag(name: [.customShort("v"), .customLong("verify")],
          help:"""
            Verification mode
            Instead of generating a new decision tree,
            use the existing one to validate one of two things:
              1. how well decision tree matches the test data it came from
              2. how well decision tree matches a known group it was not tested on
            """)
    var verification_mode = false

    @Argument(help: """
        fill this shit in better sometime later
        """)
    var json_config_file_names: [String]
    
    mutating func run() throws {
        Log.name = "decision_tree_generator-log"
        Log.handlers[.console] = ConsoleLogHandler(at: .debug)
        Log.handlers[.file] = try FileLogHandler(at: .verbose) // XXX make this a command line parameter

        start_time = Date()
        Log.i("Starting")

        if verification_mode {
            run_verification()
        } else {
            generate_tree()
        }
    }

    // use an exising decision tree to see how well it does against a given sample
    func run_verification() {
        let dispatch_group = DispatchGroup()
        dispatch_group.enter()
        Task {
            for json_config_file_name in json_config_file_names {
                do {
                    var num_similar_outlier_groups = 0
                    var num_different_outlier_groups = 0
                    
                    let config = try await Config.read(fromFilename: json_config_file_name)
                    Log.d("got config from \(json_config_file_name)")
                    
                    let callbacks = Callbacks()

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
                            eraser.shouldRun = false
                        }
                    }
                    
                    Log.i("got \(sequence_size) frames")
                    // XXX run it and get the outlier groups

                    try eraser.run()

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
                        // check all outlier groups 
                        Log.d("should check frame \(frame.frame_index)")
                        if let outlier_group_list = await frame.outlierGroups() {
                            for outlier_group in outlier_group_list {
                                if let shouldPaint = await outlier_group.shouldPaint {

                                    let decisionTreeShouldPaint = await outlier_group.shouldPaintFromDecisionTree
                                    if decisionTreeShouldPaint == shouldPaint.willPaint {
                                        // good
                                        num_similar_outlier_groups += 1
                                    } else {
                                        // bad
                                        Log.w("outlier group \(outlier_group) decisionTreeShouldPaint \(decisionTreeShouldPaint) != shouldPaint.willPaint \(shouldPaint.willPaint)")
                                        num_different_outlier_groups += 1
                                    }
                                } else {
                                    Log.e("WTF")
                                    fatalError("DIED")
                                }
                            }
                        } else {
                            Log.e("WTF")
                            fatalError("DIED HERE")
                        }
                    }
                    let total = num_similar_outlier_groups + num_different_outlier_groups
                    let percentage_good = Double(num_similar_outlier_groups)/Double(total)*100

                    Log.i("for \(json_config_file_name), out of \(total) \(percentage_good)% success")
                } catch {
                    Log.e("\(error)")
                }
            }
            dispatch_group.leave()
        }
        dispatch_group.wait()
    }

    // actually generate a decision tree
    func generate_tree() {
        let dispatch_group = DispatchGroup()
        dispatch_group.enter()
        Task {
            // test data gathered from all inputs
            var should_paint_test_data: [OutlierGroupValues] = []
            var should_not_paint_test_data: [OutlierGroupValues] = []
            
            for json_config_file_name in json_config_file_names {
                Log.d("should read \(json_config_file_name)")
                
                do {
                    let config = try await Config.read(fromFilename: json_config_file_name)
                    Log.d("got config from \(json_config_file_name)")
                    
                    let callbacks = Callbacks()

                    var frames: [FrameAirplaneRemover] = []
                    
                    var endClosure: () -> Void = { }
                    
                    // called when we should check a frame
                    callbacks.frameCheckClosure = { new_frame in
                        Log.d("frameCheckClosure for frame \(new_frame.frame_index)")
                        frames.append(new_frame)
                        endClosure()
                    }
                    
                    // XXX is this VVV obsolete???
                    callbacks.countOfFramesToCheck = { 1 }

                    let eraser = try NighttimeAirplaneRemover(with: config,
                                                              callbacks: callbacks,
                                                              processExistingFiles: true,
                                                              fullyProcess: false)
                    let sequence_size = await eraser.image_sequence.filenames.count
                    endClosure = {
                        Log.d("end enclosure frames.count \(frames.count) sequence_size \(sequence_size)")
                        if frames.count == sequence_size {
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
                                taskGroup.addTask() {
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
                                        
                                        for type in OutlierGroup.TreeDecisionType.allCases {
                                            values.values[type] = await outlier_group.decisionTreeValue(for: type)
                                        }
                                        if will_paint {
                                            should_paint_test_data.append(values)
                                        } else {
                                            should_not_paint_test_data.append(values)
                                        }
                                    } else {
                                        Log.e("outlier group \(name) has no shouldPaint value")
                                        fatalError("outlier group \(name) has no shouldPaint value")
                                    }
                                }
                            } else {
                                Log.e("cannot get outlier groups for frame \(frame.frame_index)")
                                fatalError("cannot get outlier groups for frame \(frame.frame_index)")
                            }
                        }
                    } else {
                        Log.e("couldn't read image height and/or width")
                        fatalError("couldn't read image height and/or width")
                    }
                } catch {
                    Log.w("couldn't get config from \(json_config_file_name)")
                    Log.e("\(error)")
                    fatalError("couldn't get config from \(json_config_file_name)")
                }
            }
            Log.i("Calculating decision tree with \(should_paint_test_data.count) should paint \(should_not_paint_test_data.count) should not paint test data outlier groups")
            
            let tree_swift_code = await generateTree(with: should_paint_test_data,
                                                     and: should_not_paint_test_data)

            // save this generated swift code to a file

            // XXX make this better
            let filename = "../NtarCore/Sources/NtarCore/OutlierGroupDecisionTree.swift"
            do {
                if file_manager.fileExists(atPath: filename) {
                    Log.i("overwriting already existing filename \(filename)")
                    try file_manager.removeItem(atPath: filename)
                }

                // write to file
                file_manager.createFile(atPath: filename,
                                        contents: tree_swift_code.data(using: .utf8),
                                        attributes: nil)
                Log.i("wrote \(filename)")
            } catch {
                Log.e("\(error)")
            }

            
            
            dispatch_group.leave()
        }
        dispatch_group.wait()
    }

    // top level func that writes a compilable wrapper around the root tree node
    // XXX pass in input json configs to put into comments
    func generateTree(with should_paint_test_data: [OutlierGroupValues],
                      and should_not_paint_test_data: [OutlierGroupValues]) async -> String
    {
        // the root tree node with all of the test data 
        let tree = await decisionTreeNode(with: should_paint_test_data,
                                          and: should_not_paint_test_data,
                                          indent: 3)

        let generated_swift_code = tree.swiftCode

        let end_time = Date()

        let formatter = DateComponentsFormatter()
        formatter.calendar = Calendar.current
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .full
        let duration_string = formatter.string(from: start_time, to: end_time) ?? "??"

        var input_files_string = ""
        for json_config_file_name in json_config_file_names {
            input_files_string += "     - \(json_config_file_name)\n"
        }
        
        return """
          /*
             auto generated by decision_tree_generator on \(Date()) in \(duration_string)

             with test data consisting of:
               - \(should_paint_test_data.count) groups known to be paintable
               - \(should_not_paint_test_data.count) groups known to not be paintable

             from input data described by:
          \(input_files_string)
          */
          
          // DO NOT EDIT THIS FILE
          // DO NOT EDIT THIS FILE
          // DO NOT EDIT THIS FILE

          @available(macOS 10.15, *)
          public extension OutlierGroup {
          
              // define a computed property which decides the paintability 
              // of this OutlierGroup with a decision tree
              var shouldPaintFromDecisionTree: Bool {
                  get async {
          \(generated_swift_code)
                  }
              }
          }
          """
    }

    // recursively return a decision tree that differentiates the test data
    func decisionTreeNode(with should_paint_test_data: [OutlierGroupValues],
                          and should_not_paint_test_data: [OutlierGroupValues],
                          indent: Int) async -> DecisionTree
    {
        Log.i("decisionTreeNode with indent \(indent) should_paint_test_data.count \(should_paint_test_data.count) should_not_paint_test_data.count \(should_not_paint_test_data.count)")

        if should_paint_test_data.count == 0,
           should_not_paint_test_data.count == 0
        {
            Log.e("FUCK")
            fatalError("two zeros not allowed")
        }
        if should_paint_test_data.count == 0 {
            // func was called without any data to paint, return don't paint it all
            return ShouldNotPaintDecision(indent: indent)
        }
        if should_not_paint_test_data.count == 0 {
            // func was called without any data to not paint, return paint it all
            return ShouldPaintDecision(indent: indent)
        }

        // this is the 0-1 percentage of should_paint
        let original_split =
          Double(should_paint_test_data.count) /
          Double(should_not_paint_test_data.count + should_paint_test_data.count)

        // we have non zero test data of both kinds
        
        // collate should paint and not paint test data by type
        // look for boundries where we can further isolate 

        // raw values for each type
        var should_paint_values: [OutlierGroup.TreeDecisionType: [Double]] = [:]
        var should_not_paint_values: [OutlierGroup.TreeDecisionType: [Double]] = [:]
        /*
        for type in OutlierGroup.TreeDecisionType.allCases {
            should_paint_values[type] = []
            should_not_paint_values[type] = []
        }*/
        
        for type in OutlierGroup.TreeDecisionType.allCases {
            // XXX task group here
            for test_data in should_paint_test_data {
                if let value = test_data.values[type] {
                    if var list = should_paint_values[type] {
                        list.append(value)
                        should_paint_values[type] = list
                    } else {
                        should_paint_values[type] = [value]
                    }
                } 
            }
        }

        Log.i("decisionTreeNode checkpoint 0.5 with indent \(indent) should_paint_test_data.count \(should_paint_test_data.count) should_not_paint_test_data.count \(should_not_paint_test_data.count)")

        for type in OutlierGroup.TreeDecisionType.allCases {
            // XXX task group here
            for test_data in should_not_paint_test_data {
                if let value = test_data.values[type] {
                    if var list = should_not_paint_values[type] {
                        list.append(value)
                        should_not_paint_values[type] = list
                    } else {
                        should_not_paint_values[type] = [value]
                    }
                }
            }
        }

        Log.i("decisionTreeNode checkpoint 1 with indent \(indent) should_paint_test_data.count \(should_paint_test_data.count) should_not_paint_test_data.count \(should_not_paint_test_data.count)")

        // value distributions for each type
        var should_paint_dist: [OutlierGroup.TreeDecisionType: ValueDistribution] = [:]
        var should_not_paint_dist: [OutlierGroup.TreeDecisionType: ValueDistribution] = [:]

        let _should_paint_values: [OutlierGroup.TreeDecisionType: [Double]] = should_paint_values
        
        await withTaskGroup(of: ValueDistribution.self) { taskGroup in
            // for each type, calculate a min/max/mean/median for both paint and not
            for type in OutlierGroup.TreeDecisionType.allCases {
                taskGroup.addTask() {
                    var min = Double.greatestFiniteMagnitude
                    var max = -Double.greatestFiniteMagnitude
                    var sum = 0.0
                    if let all_values = _should_paint_values[type] {
                        //Log.d("all values for paint \(type): \(all_values)")
                        for value in all_values {
                            if value < min { min = value }
                            if value > max { max = value }
                            sum += value
                        }
                        sum /= Double(all_values.count)
                        let median = all_values.sorted()[all_values.count/2]
                        return ValueDistribution(type: type, min: min, max: max, mean: sum, median: median)
                    } else {
                        Log.e("WTF")
                        fatalError("FUCKED")
                    }
                }
            }
            while let response = await taskGroup.next() {
                should_paint_dist[response.type] = response
            }
        }

        Log.i("decisionTreeNode checkpoint 1.5 with indent \(indent) should_paint_test_data.count \(should_paint_test_data.count) should_not_paint_test_data.count \(should_not_paint_test_data.count)")

        let _should_not_paint_values: [OutlierGroup.TreeDecisionType: [Double]] = should_not_paint_values

        // XXX dupe above for not paint
        await withTaskGroup(of: ValueDistribution.self) { taskGroup in
            for type in OutlierGroup.TreeDecisionType.allCases {
                taskGroup.addTask() {
                    var min = Double.greatestFiniteMagnitude
                    var max = -Double.greatestFiniteMagnitude
                    var sum = 0.0
                    if let all_values = _should_not_paint_values[type] {
                        //Log.d("all values for not paint \(type): \(all_values)")
                        for value in all_values {
                            if value < min { min = value }
                            if value > max { max = value }
                            sum += value
                        }
                        sum /= Double(all_values.count)
                        let median = all_values.sorted()[all_values.count/2]
                        return ValueDistribution(type: type, min: min, max: max, mean: sum, median: median)
                    } else {
                        Log.e("WTF")
                        fatalError("FUCK")
                    }
                }
            }
            while let response: ValueDistribution = await taskGroup.next() {
                should_not_paint_dist[response.type] = response
            }
        }

        Log.i("decisionTreeNode checkpoint 2 with indent \(indent) should_paint_test_data.count \(should_paint_test_data.count) should_not_paint_test_data.count \(should_not_paint_test_data.count)")

        var bestDecisionResult: DecisionResult?
        var bestTreeNode: DecisionTree?
        var biggest_split = 0.0

        // iterate ofer all decision tree types to pick the best one
        // that differentiates the test data

        await withTaskGroup(of: TreeDecisionTypeResult.self) { taskGroup in
        
            for type in OutlierGroup.TreeDecisionType.allCases {
                if let paint_dist = should_paint_dist[type],
                   let not_paint_dist = should_not_paint_dist[type]
                {
                    taskGroup.addTask() {
                        Log.d("type \(type)")
                        if paint_dist.max < not_paint_dist.min {
                            // we have a clear distinction between all provided test data
                            // this is an end leaf node, both paths after decision lead to a result
                            Log.d("clear distinction \(paint_dist.max) < \(not_paint_dist.min)")
                            
                            var ret = TreeDecisionTypeResult()
                            ret.decisionTreeNode =
                              DecisionTreeNode(type: type,
                                               value: (paint_dist.max + not_paint_dist.min) / 2,
                                               lessThan: ShouldPaintDecision(indent: indent + 1),
                                               greaterThan: ShouldNotPaintDecision(indent: indent + 1),
                                               indent: indent)
                            return ret
                        } else if not_paint_dist.max < paint_dist.min {
                            Log.d("clear distinction \(not_paint_dist.max) < \(paint_dist.min)")
                            // we have a clear distinction between all provided test data
                            // this is an end leaf node, both paths after decision lead to a result
                            var ret = TreeDecisionTypeResult()
                            ret.decisionTreeNode =
                              DecisionTreeNode(type: type,
                                               value: (not_paint_dist.max + paint_dist.min) / 2,
                                               lessThan: ShouldNotPaintDecision(indent: indent + 1),
                                               greaterThan: ShouldPaintDecision(indent: indent + 1),
                                               indent: indent)
                            return ret
                        } else {
                            Log.d("no clear distinction, need new node at indent \(indent)")
                            // we do not have a clear distinction between all provided test data
                            // we need to figure out what type is best to segarate
                            // the test data further
                            
                            // test this type to see how much we can split the data based upon it
                            
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
                                if let group_value = group_values.values[type] {
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
                                if let group_value = group_values.values[type] {
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

                            var ret = TreeDecisionTypeResult()
                            ret.decisionResult =
                              DecisionResult(type: type,
                                             value: decisionValue,
                                             lessThanShouldPaint: lessThanShouldPaint,
                                             lessThanShouldNotPaint: lessThanShouldNotPaint,
                                             greaterThanShouldPaint: greaterThanShouldPaint,
                                             greaterThanShouldNotPaint: greaterThanShouldNotPaint)
                            return ret
                        }
                    }
                }
            }
            var responses: [TreeDecisionTypeResult] = []
            while let response = await taskGroup.next() {
                responses.append(response)
            }

            // look through them all
            for response in responses {
                if let decisionTreeNode = response.decisionTreeNode {
                    // these are tree nodes ready to go
                    bestTreeNode = decisionTreeNode
                } else if let decisionResult = response.decisionResult {
                    // these are tree nodes that require recursion
                    var we_are_best = false
                    
                    // choose the type with the best distribution 
                    // that will generate the shortest tree
                    if decisionResult.lessThanSplit > original_split,
                       decisionResult.lessThanSplit - original_split > biggest_split
                    {
                        // the less than split is biggest so far
                        biggest_split = decisionResult.lessThanSplit - original_split
                        we_are_best = true
                    } else if decisionResult.greaterThanSplit > original_split,
                              decisionResult.greaterThanSplit - original_split > biggest_split
                    {
                        // the greater than split is biggest so far
                        biggest_split = decisionResult.greaterThanSplit - original_split
                        we_are_best = true
                    }

                    if we_are_best {
                        bestDecisionResult = decisionResult
                    }
                }
            }
        }

        // return a direct tree node if we have it (no recursion)
        if let decisionTreeNode = bestTreeNode { return decisionTreeNode }

        // if not, setup to recurse
        if let result = bestDecisionResult { 

            // we've identified the best type to differentiate the test data
            // output a tree node with this type and value

            var less_response: TreeResponse?
            var greater_response: TreeResponse?

            // first recurse on both sides of the decision tree with differentated test data
            await withTaskGroup(of: TreeResponse.self) { taskGroup in
                taskGroup.addTask() {
                    let less_tree = await self.decisionTreeNode(with: result.lessThanShouldPaint,
                                                                and: result.lessThanShouldNotPaint,
                                                                indent: indent + 1)
                    return TreeResponse(treeNode: less_tree, position: .less)
                }
                // uncomment this to make it serial (for easier debugging)
                // comment it to make it parallel
/*
                while let response = await taskGroup.next() {
                    switch response.position {
                    case .less:
                        less_response = response
                    case .greater:
                        greater_response = response
                    }
                }
*/
                taskGroup.addTask() {
                    let greater_tree = await self.decisionTreeNode(with: result.greaterThanShouldPaint,
                                                                   and: result.greaterThanShouldNotPaint,
                                                                   indent: indent + 1)
                    return TreeResponse(treeNode: greater_tree, position: .greater)
                }
                while let response = await taskGroup.next() {
                    switch response.position {
                    case .less:
                        less_response = response
                    case .greater:
                        greater_response = response
                    }
                }
            }

            if let less_response = less_response,
               let greater_response = greater_response
            {
                return DecisionTreeNode(type: result.type,
                                        value: result.value,
                                        lessThan: less_response.treeNode,
                                        greaterThan: greater_response.treeNode,
                                        indent: indent)
            } else {
                Log.e("holy fuck")
                fatalError("doh")
            }
        } else {
            Log.e("no best type")
            fatalError("no best result")
        }
    }
}

struct TreeResponse {
    enum Place {
        case less
        case greater
    }
    
    let treeNode: DecisionTree
    let position: Place
}
    
@available(macOS 10.15, *) 
struct ValueDistribution {
    let type: OutlierGroup.TreeDecisionType
    let min: Double
    let max: Double
    let mean: Double
    let median: Double
}

// represents an abstract node in the decision tree
// that knows how to render itself as a String of swift code
protocol DecisionTree {
    var swiftCode: String { get }
}

// end leaf node which always returns true
struct ShouldPaintDecision: DecisionTree {
    let indent: Int
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return true"
    }
}

// end leaf node which always returns false
struct ShouldNotPaintDecision: DecisionTree {
    let indent: Int
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return false"
    }
}

// intermediate node which decides based upon the value of a particular type
@available(macOS 10.15, *) 
struct DecisionTreeNode: DecisionTree {
    let type: OutlierGroup.TreeDecisionType
    let value: Double
    let lessThan: DecisionTree
    let greaterThan: DecisionTree
    let indent: Int

    var swiftCode: String {

        var methodInvocation = ""
        if type.needsAsync {
            methodInvocation = "if await self.decisionTreeValue"
        } else {
            methodInvocation = "if self.nonAsyncDecisionTreeValue"
        }

        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return """
          \(indentation)\(methodInvocation)(for: .\(type)) < \(value) {
          \(lessThan.swiftCode)
          \(indentation)} else {
          \(greaterThan.swiftCode)
          \(indentation)}
          """
    }
}

fileprivate let file_manager = FileManager.default
