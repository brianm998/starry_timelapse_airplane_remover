import Foundation
import NtarCore
import ArgumentParser
import BinaryCodable
import CryptoKit

var start_time: Date = Date()

@available(macOS 10.15, *) 
struct TreeDecisionTypeResult {
    init(type: OutlierGroup.TreeDecisionType) {
        self.type = type
    }
    let type: OutlierGroup.TreeDecisionType
    var decisionResult: DecisionResult?
    var decisionTreeNode: DecisionTree?
    var should_paint_dist: ValueDistribution?
    var should_not_paint_dist: ValueDistribution?
}

@available(macOS 10.15, *) 
struct DecisionTypeValuesResult {
    let type: OutlierGroup.TreeDecisionType
    let values: [Double]
}

@available(macOS 10.15, *) 
struct OutlierGroupValueMapResult {
    let should_paint_test_data: [OutlierGroupValueMap]
    let should_not_paint_test_data: [OutlierGroupValueMap]
}

struct TreeTestResults {
    let numberGood: Int
    let numberBad: Int
}

struct RankedResult<T> {
    let rank: Double
    let result: T
}

// how much do we truncate the sha256 hash when embedding it into code
let sha_suffix_size = 8

// use this for with the taskgroup below
@available(macOS 10.15, *) 
struct DecisionResult {
    let type: OutlierGroup.TreeDecisionType
    let value: Double
    let lessThanShouldPaint: [OutlierGroupValueMap]
    let lessThanShouldNotPaint: [OutlierGroupValueMap]
    let greaterThanShouldPaint: [OutlierGroupValueMap]
    let greaterThanShouldNotPaint: [OutlierGroupValueMap]
    let lessThanSplit: Double
    let greaterThanSplit: Double
    
    public init(type: OutlierGroup.TreeDecisionType,
                value: Double = 0,
                lessThanShouldPaint: [OutlierGroupValueMap],
                lessThanShouldNotPaint: [OutlierGroupValueMap],
                greaterThanShouldPaint: [OutlierGroupValueMap],
                greaterThanShouldNotPaint: [OutlierGroupValueMap])
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
            generate_tree_from_json_config()
        }
        Log.dispatchGroup.wait()
    }

    func runVerification(basedUpon json_config_file_name: String) async throws {

        var num_similar_outlier_groups = 0
        var num_different_outlier_groups = 0
        let config = try await Config.read(fromJsonFilename: json_config_file_name)
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


        Log.i("loading outliers")
        // after the eraser is done running we should have received all the frames
        // in the frame check callback

        // load the outliers in parallel
        try await withLimitedThrowingTaskGroup(of: Void.self) { taskGroup in
            for frame in frames {
                await taskGroup.addTask(/*priority: .medium*/) {
                    try await frame.loadOutliers()
                }
            }
            try await taskGroup.waitForAll()
        }

        Log.i("checkpoint before loading tree test results")
        await withLimitedTaskGroup(of: TreeTestResults.self) { taskGroup in
            for frame in frames {
                // check all outlier groups
                
                await taskGroup.addTask() {
                    var number_good = 0
                    var number_bad = 0
                    //Log.d("should check frame \(frame.frame_index)")
                    if let outlier_group_list = await frame.outlierGroups() {
                        for outlier_group in outlier_group_list {
                            if let numberGood = await outlier_group.shouldPaint {
                                let decisionTreeShouldPaint = await outlier_group.shouldPaintFromDecisionTree
                                if decisionTreeShouldPaint == numberGood.willPaint {
                                    // good
                                    //Log.d("good")
                                    number_good += 1
                                } else {
                                    // bad
                                    //Log.w("outlier group \(outlier_group) decisionTreeShouldPaint \(decisionTreeShouldPaint) != numberGood.willPaint \(numberGood.willPaint)")
                                    number_bad += 1
                                }
                            } else {
                                //Log.e("WTF")
                                //fatalError("DIED")
                            }
                        }
                    } else {
                        //Log.e("WTF")
                        //fatalError("DIED HERE")
                    }
                    //Log.d("number_good \(number_good) number_bad \(number_bad)")
                    return TreeTestResults(numberGood: number_good,
                                           numberBad: number_bad)
                }
            }
            Log.d("waiting for all")
            while let response = await taskGroup.next() {
                Log.d("got response response.numberGood \(response.numberGood) response.numberBad \(response.numberBad) ")
                num_similar_outlier_groups += response.numberGood
                num_different_outlier_groups += response.numberBad
            }
        }
        Log.d("checkpoint at end")
        let total = num_similar_outlier_groups + num_different_outlier_groups
        let percentage_good = Double(num_similar_outlier_groups)/Double(total)*100
        Log.i("for \(json_config_file_name), out of \(total) \(percentage_good)% success")
    }
    
    // use an exising decision tree to see how well it does against a given sample
    func run_verification() {
        let dispatch_group = DispatchGroup()
        dispatch_group.enter()
        Task {
            for json_config_file_name in json_config_file_names {
                if json_config_file_name.hasSuffix("config.json") {
                    do {
                        try await runVerification(basedUpon: json_config_file_name)
                    } catch {
                        Log.e("\(error)")
                    }
                } else {
                    if file_manager.fileExists(atPath: json_config_file_name) {
                        var number_good = 0
                        var number_bad = 0
                        
                        // load a list of OutlierGroupValueMatrix
                        // and get outlierGroupValues from them
                        let contents = try file_manager.contentsOfDirectory(atPath: json_config_file_name)
                        for file in contents {
                            if file.hasSuffix("_outlier_values.bin") {
                                let filename = "\(json_config_file_name)/\(file)"
                                do {
                                    // load data
                                    // process a frames worth of outlier data
                                    let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)
                                    
                                    let (data, _) = try await URLSession.shared.data(for: URLRequest(url: imageURL as URL))

                                    let decoder = BinaryDecoder()
                                    let matrix = try decoder.decode(OutlierGroupValueMatrix.self, from: data)

                                    for values in matrix.values {
                                        // XXX how to reference hash properly here ???
                                        // could search for classes that conform to a new protocol
                                        // that defines this specific method, but it's static :(
                                        let decisionTreeShouldPaint =  
                                          OutlierGroup.decisionTree_2db488e9(types: matrix.types,
                                                                             values: values.values)
                                        if decisionTreeShouldPaint == values.shouldPaint {
                                            number_good += 1
                                        } else {
                                            number_bad += 1
                                        }
                                    }
                                } catch {
                                    Log.e("\(error)")
                                }
                            }
                        }

                        let total = number_good + number_bad
                        let percentage_good = Double(number_good)/Double(total)*100
                        Log.i("for \(json_config_file_name), out of \(total) \(percentage_good)% success")
                    }
                }
            }
            dispatch_group.leave()
        }
        dispatch_group.wait()
    }

    // read outlier group values from a stored set of files listed by a config.json
    // the reads the full outliers from file, and can be slow
    private func read(fromConfig json_config_file_name: String) async throws
      -> ([OutlierGroupValueMap], // should paint
          [OutlierGroupValueMap]) // should not paint
    {
        var should_paint_test_data: [OutlierGroupValueMap] = []
        var should_not_paint_test_data: [OutlierGroupValueMap] = []
        let config = try await Config.read(fromJsonFilename: json_config_file_name)
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
        
        Log.d("got \(sequence_size) frames")
        // XXX run it and get the outlier groups

        try eraser.run()

        Log.d("eraser done running")
        
        // after the eraser is done running we should have received all the frames
        // in the frame check callback

        // load the outliers in parallel
        try await withLimitedThrowingTaskGroup(of: Void.self) { taskGroup in
            for frame in frames {
                await taskGroup.addTask() {
                    try await frame.loadOutliers()
                }
            }
            try await taskGroup.waitForAll()
        }
        Log.d("outliers loaded")

        await withLimitedTaskGroup(of: OutlierGroupValueMapResult.self) { taskGroup in
            for frame in frames {
                await taskGroup.addTask() {
                    
                    var local_should_paint_test_data: [OutlierGroupValueMap] = []
                    var local_should_not_paint_test_data: [OutlierGroupValueMap] = []
                    if let outlier_groups = await frame.outlierGroups() {
                        for outlier_group in outlier_groups {
                            let name = await outlier_group.name
                            if let should_paint = await outlier_group.shouldPaint {
                                let will_paint = should_paint.willPaint

                                let values = await outlier_group.decisionTreeGroupValues

                                if will_paint {
                                    local_should_paint_test_data.append(values)
                                } else {
                                    local_should_not_paint_test_data.append(values)
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
                    return OutlierGroupValueMapResult(
                      should_paint_test_data: local_should_paint_test_data,
                      should_not_paint_test_data: local_should_not_paint_test_data)
                }
            }

            while let response = await taskGroup.next() {
                should_paint_test_data += response.should_paint_test_data
                should_not_paint_test_data += response.should_not_paint_test_data
            }
        }    

        return (should_paint_test_data, should_not_paint_test_data)
    }

    // actually generate a decision tree
    func generate_tree_from_json_config() {
        let dispatch_group = DispatchGroup()
        dispatch_group.enter()
        Task {
            // test data gathered from all inputs
            var should_paint_test_data: [OutlierGroupValueMap] = []
            var should_not_paint_test_data: [OutlierGroupValueMap] = []
            
            for json_config_file_name in json_config_file_names {
                if json_config_file_name.hasSuffix("config.json") {
                    // here we are loading the full outlier groups and analyzing based upon that
                    // comprehensive, but slow
                    Log.d("should read \(json_config_file_name)")

                    do {
                        let (more_should_paint, more_should_not_paint) =
                          try await read(fromConfig: json_config_file_name)
                        
                        should_paint_test_data += more_should_paint
                        should_not_paint_test_data += more_should_not_paint
                    } catch {
                        Log.w("couldn't get config from \(json_config_file_name)")
                        Log.e("\(error)")
                        fatalError("couldn't get config from \(json_config_file_name)")
                    }
                } else {
                    // check to see if it's a dir
                    if file_manager.fileExists(atPath: json_config_file_name/*, isDirecotry: &isDir*/) {

                        try await withThrowingLimitedTaskGroup(of: OutlierGroupValueMapResult.self) { taskGroup in
                            
                            // load a list of OutlierGroupValueMatrix
                            // and get outlierGroupValues from them
                            let contents = try file_manager.contentsOfDirectory(atPath: json_config_file_name)
                            for file in contents {
                                if file.hasSuffix("_outlier_values.bin") {
                                    let filename = "\(json_config_file_name)/\(file)"
                                    
                                    try await taskGroup.addTask() {
                                        var local_should_paint_test_data: [OutlierGroupValueMap] = []
                                        var local_should_not_paint_test_data: [OutlierGroupValueMap] = []
                                        

                                        // load data
                                        // process a frames worth of outlier data
                                        let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)
                                        
                                        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: imageURL as URL))
                                        
                                        let decoder = BinaryDecoder()
                                        let matrix = try decoder.decode(OutlierGroupValueMatrix.self, from: data)
                                        //if let json = matrix.prettyJson { print(json) }
                                        //Log.d("frame \(frame_index) matrix \(matrix)")
                                        for values in matrix.values {
                                            var valueMap = OutlierGroupValueMap()
                                            for (index, type) in matrix.types.enumerated() {
                                                valueMap.values[type] = values.values[index]
                                            }
                                            if values.shouldPaint {
                                                local_should_paint_test_data.append(valueMap)
                                            } else {
                                                local_should_not_paint_test_data.append(valueMap)
                                            }
                                        }
                                        
                                        return OutlierGroupValueMapResult(
                                          should_paint_test_data: local_should_paint_test_data,
                                          should_not_paint_test_data: local_should_not_paint_test_data)
                                    }
                                }
                            }
                            while let response = try await taskGroup.next() {
                                should_paint_test_data += response.should_paint_test_data
                                should_not_paint_test_data += response.should_not_paint_test_data
                            }
                        }
                    }
                }
            }
            
            Log.i("Calculating decision tree with \(should_paint_test_data.count) should paint \(should_not_paint_test_data.count) should not paint test data outlier groups")

            // XXX these are the same, but in different orders, not sure if that matters
            //Log.d("should paint")
            //log(valueMaps: should_paint_test_data)
            //Log.d("should NOT paint")
            //log(valueMaps: should_not_paint_test_data)
            
            let (tree_swift_code, sha_hash) = await generateTree(with: should_paint_test_data,
                                                                 and: should_not_paint_test_data)

            // save this generated swift code to a file

            // XXX make this better
            let filename = "../NtarCore/Sources/NtarCore/OutlierGroupDecisionTree_\(sha_hash.suffix(sha_suffix_size)).swift"
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

    func log(valueMaps: [OutlierGroupValueMap]) {
        for (index, valueMap) in valueMaps.enumerated() {
            var log = "\(index) - "
            for type in OutlierGroup.TreeDecisionType.allCases {
                let value = valueMap.values[type]!
                log += "\(String(format: "%.3g", value)) "
            }
            Log.d(log)
        }
    }
    
    // top level func that writes a compilable wrapper around the root tree node
    func generateTree(with should_paint_test_data: [OutlierGroupValueMap],
                      and should_not_paint_test_data: [OutlierGroupValueMap]) async -> (String, String)
    {
        // the root tree node with all of the test data 
        let tree = await decisionTreeNode(with: should_paint_test_data,
                                          and: should_not_paint_test_data,
                                          indent: 2)

        let generated_swift_code = tree.swiftCode

        let end_time = Date()

        let formatter = DateComponentsFormatter()
        formatter.calendar = Calendar.current
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .full
        let duration_string = formatter.string(from: start_time, to: end_time) ?? "??"

        let indentation = "        "
        var digest = SHA256()
        
        var input_files_string = ""
        var input_files_array = "\(indentation)["
        for json_config_file_name in json_config_file_names {
            input_files_string += "     - \(json_config_file_name)\n"
            input_files_array += "\n\(indentation)    \"\(json_config_file_name)\","
            if let data = json_config_file_name.data(using: .utf8) {
                digest.update(data: data)
            } else {
                Log.e("FUCK")
                fatalError("SHIT")
            }
        }
        input_files_array.removeLast()
        input_files_array += "\n\(indentation)]"

        let generation_date = Date()

        if let data = "\(generation_date)".data(using: .utf8) {
            digest.update(data: data)
        } else {
            Log.e("FUCK")
            fatalError("SHIT")
        }

        let tree_hash = digest.finalize()
        let tree_hash_string = tree_hash.compactMap { String(format: "%02x", $0) }.joined()
        let generation_date_since_1970 = generation_date.timeIntervalSince1970

        var function_signature = ""
        var function_parameters = ""
        var function2_parameters = ""
        
        for type in OutlierGroup.TreeDecisionType.allCases {
            if type.needsAsync { 
                function_parameters += "                   \(type): await self.decisionTreeValue(for: .\(type)),\n"
            } else {
                function_parameters += "                   \(type): self.nonAsyncDecisionTreeValue(for: .\(type)),\n"
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

        let hash_prefix = tree_hash_string.prefix(sha_suffix_size)
        
        let swift_string = """
          /*
             auto generated by decision_tree_generator on \(generation_date) in \(duration_string)

             with test data consisting of:
               - \(should_paint_test_data.count) groups known to be paintable
               - \(should_not_paint_test_data.count) groups known to not be paintable

             from input data described by:
          \(input_files_string)
          */
          
          // DO NOT EDIT THIS FILE
          // DO NOT EDIT THIS FILE
          // DO NOT EDIT THIS FILE

          public struct OutlierGroupDecisionTree_\(hash_prefix) {
              public let sha256 = "\(tree_hash_string)"

              public let sha256Prefix = "\(hash_prefix)"
              
              public let generationSecondsSince1970 = \(generation_date_since_1970)

              public let inputSequences =
          \(input_files_array)
          }
          
          @available(macOS 10.15, *)
          public extension OutlierGroup {
          
              // decide the paintability of this OutlierGroup with a decision tree
              var shouldPaintFromDecisionTree_\(hash_prefix): Bool {
                  get async {

                      return OutlierGroup.decisionTree_\(hash_prefix)(
          \(function_parameters)
                          )
                   }

               }

              // a way to call into the decision tree without an OutlierGroup object
              static func decisionTree_\(hash_prefix) (
                 types: [OutlierGroup.TreeDecisionType], // parallel
                 values: [Double]                        // arrays
                ) -> Bool
              {
                var map: [OutlierGroup.TreeDecisionType:Double] = [:]
                for (index, type) in types.enumerated() {
                    let value = values[index]
                    map[type] = value
                }
                return OutlierGroup.decisionTree_\(hash_prefix)(
          \(function2_parameters)
                )
              }

              // the actual tree resides here
              static func decisionTree_\(hash_prefix)(
          \(function_signature)
                    ) -> Bool
              {
          \(generated_swift_code)
              }
          }
          """

        return (swift_string, tree_hash_string)
    }

    // recursively return a decision tree that differentiates the test data
    func decisionTreeNode(with should_paint_test_data: [OutlierGroupValueMap],
                          and should_not_paint_test_data: [OutlierGroupValueMap],
                          indent: Int) async -> DecisionTree
    {
        //Log.i("decisionTreeNode with indent \(indent) should_paint_test_data.count \(should_paint_test_data.count) should_not_paint_test_data.count \(should_not_paint_test_data.count)")

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
        
        await withTaskGroup(of: DecisionTypeValuesResult.self) { taskGroup in
            for type in OutlierGroup.TreeDecisionType.allCases {
                taskGroup.addTask() {
                    var list: [Double] = []
                    for test_data in should_paint_test_data {
                        if let value = test_data.values[type] {
                            list.append(value)
                        }
                    }
                    return DecisionTypeValuesResult(type: type, values: list)
                }
            }
            while let response = await taskGroup.next() {
                should_paint_values[response.type] = response.values
            }
        }

        //Log.i("decisionTreeNode checkpoint 0.5 with indent \(indent) should_paint_test_data.count \(should_paint_test_data.count) should_not_paint_test_data.count \(should_not_paint_test_data.count)")

        await withTaskGroup(of: DecisionTypeValuesResult.self) { taskGroup in
            for type in OutlierGroup.TreeDecisionType.allCases {
                taskGroup.addTask() {
                    var list: [Double] = []
                    for test_data in should_not_paint_test_data {
                        if let value = test_data.values[type] {
                            list.append(value)
                        }
                    }
                    return DecisionTypeValuesResult(type: type, values: list)
                }
            }
            while let response = await taskGroup.next() {
                should_not_paint_values[response.type] = response.values
            }
        }

        //Log.i("decisionTreeNode checkpoint 1 with indent \(indent) should_paint_test_data.count \(should_paint_test_data.count) should_not_paint_test_data.count \(should_not_paint_test_data.count)")

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

        //Log.i("decisionTreeNode checkpoint 1.5 with indent \(indent) should_paint_test_data.count \(should_paint_test_data.count) should_not_paint_test_data.count \(should_not_paint_test_data.count)")

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

        //Log.i("decisionTreeNode checkpoint 2 with indent \(indent) should_paint_test_data.count \(should_paint_test_data.count) should_not_paint_test_data.count \(should_not_paint_test_data.count)")

        // iterate ofer all decision tree types to pick the best one
        // that differentiates the test data
        var rankedDecisionResults: [RankedResult<DecisionResult>] = []
        var bestTreeNodes: [RankedResult<DecisionTree>] = []

        await withTaskGroup(of: TreeDecisionTypeResult.self) { taskGroup in
        
            for type in OutlierGroup.TreeDecisionType.allCases {
                if let paint_dist = should_paint_dist[type],
                   let not_paint_dist = should_not_paint_dist[type]
                {
                    taskGroup.addTask() {
                        //Log.d("type \(type)")
                        if paint_dist.max < not_paint_dist.min {
                            // we have a clear distinction between all provided test data
                            // this is an end leaf node, both paths after decision lead to a result
                            //Log.d("clear distinction \(paint_dist.max) < \(not_paint_dist.min)")

                            var ret = TreeDecisionTypeResult(type: type)
                            ret.decisionTreeNode =
                              DecisionTreeNode(realType: type,
                                               value: (paint_dist.max + not_paint_dist.min) / 2,
                                               lessThan: ShouldPaintDecision(indent: indent + 1),
                                               greaterThan: ShouldNotPaintDecision(indent: indent + 1),
                                               indent: indent)
                            ret.should_paint_dist = paint_dist
                            ret.should_not_paint_dist = not_paint_dist
                            return ret
                        } else if not_paint_dist.max < paint_dist.min {
                            //Log.d("clear distinction \(not_paint_dist.max) < \(paint_dist.min)")
                            // we have a clear distinction between all provided test data
                            // this is an end leaf node, both paths after decision lead to a result
                            var ret = TreeDecisionTypeResult(type: type)
                            ret.decisionTreeNode =
                              DecisionTreeNode(realType: type,
                                               value: (not_paint_dist.max + paint_dist.min) / 2,
                                               lessThan: ShouldNotPaintDecision(indent: indent + 1),
                                               greaterThan: ShouldPaintDecision(indent: indent + 1),
                                               indent: indent)
                            ret.should_paint_dist = paint_dist
                            ret.should_not_paint_dist = not_paint_dist
                            return ret
                        } else {
                            //Log.d("no clear distinction, need new node at indent \(indent)")
                            // we do not have a clear distinction between all provided test data
                            // we need to figure out what type is best to segarate
                            // the test data further
                            
                            // test this type to see how much we can split the data based upon it
                            
                            // for now, center between their medians
                            // possible improvement is to decide based upon something else
                            // use this value to split the should_paint_test_data and not paint
                            let decisionValue = (paint_dist.median + not_paint_dist.median) / 2
                            
                            var lessThanShouldPaint: [OutlierGroupValueMap] = []
                            var lessThanShouldNotPaint: [OutlierGroupValueMap] = []
                            
                            var greaterThanShouldPaint: [OutlierGroupValueMap] = []
                            var greaterThanShouldNotPaint: [OutlierGroupValueMap] = []
                            
                            // calculate how the data would split if we used the above decision value
                            for group_values in should_paint_test_data {
                                if let group_value = group_values.values[type] {
                                    if group_value < decisionValue {
                                        lessThanShouldPaint.append(group_values)
                                    } else {
                                        greaterThanShouldPaint.append(group_values)
                                    }
                                } else {
                                    Log.e("no value for type \(type)")
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

                            var ret = TreeDecisionTypeResult(type: type)
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

            var decisionResults: [DecisionResult] = []
            var decisionTreeNodes: [TreeDecisionTypeResult] = []

            while let response = await taskGroup.next() {
                if let result = response.decisionResult {
                    decisionResults.append(result)
                }
                if let _ = response.decisionTreeNode,
                   let _ = response.should_paint_dist,
                   let _ = response.should_not_paint_dist
                {
                    decisionTreeNodes.append(response)
                }
            }

            for response in decisionTreeNodes {
                // these are direct splits that evenly cleave the input data into separate groups
                if let decisionTreeNode = response.decisionTreeNode,
                   let paint_dist = response.should_paint_dist,
                   let not_paint_dist = response.should_not_paint_dist
                {
                    // check each direct decision result and choose the best one
                    // based upon the difference between their edges and their means
                    if paint_dist.max < not_paint_dist.min {
                        let split =
                          (not_paint_dist.min - paint_dist.max) /
                          (not_paint_dist.median - paint_dist.median)
                          
                        bestTreeNodes.append(RankedResult(rank: split,
                                                          result: decisionTreeNode))
                    } else if not_paint_dist.max < paint_dist.min {
                        let split =
                          (paint_dist.min - not_paint_dist.max) /
                          (paint_dist.median - not_paint_dist.median)

                        bestTreeNodes.append(RankedResult(rank: split,
                                                          result: decisionTreeNode))
                    }
                }
            }

            for decisionResult in decisionResults {
                // these are tree nodes that require recursion
                
                // choose the type with the best distribution 
                // that will generate the shortest tree
                if decisionResult.lessThanSplit > original_split {
                    // the less than split is biggest so far
                    let split = decisionResult.lessThanSplit - original_split

                    rankedDecisionResults.append(RankedResult(rank: split,
                                                            result: decisionResult)) 

                }
                if decisionResult.greaterThanSplit > original_split {
                    // the greater than split is biggest so far
                    let split = decisionResult.greaterThanSplit - original_split

                    rankedDecisionResults.append(RankedResult(rank: split,
                                                            result: decisionResult)) 
                }
            }
        }

        // return a direct tree node if we have it (no recursion)
        // make sure we choose the best one of theese
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

                var maxList: [RankedResult<DecisionTree>] = [sorted[0]]

                for i in 1..<sorted.count {
                    if sorted[i].rank == sorted[0].rank {
                        maxList.append(sorted[i])
                    }
                }

                if maxList.count == 1 {
                    return maxList[0].result
                } else {
                    // XXX future improvement is to sort by something else here

                    // sort them by type

                    let maxSort = maxList.sorted { lhs, rhs in
                        return
                          // XXX find a better way to deal with optionals below
                          lhs.result.type ?? .numberOfNearbyOutliersInSameFrame <
                          rhs.result.type ?? .adjecentFrameNeighboringOutliersBestTheta
                    }
                    
                    return maxSort[0].result
                }
            }
        }

        // if not, setup to recurse
        if rankedDecisionResults.count != 0 {
            if rankedDecisionResults.count == 1 {
                return await recurseOn(result: rankedDecisionResults[0].result, indent: indent)
            } else {
                // choose the first one somehow
                let sorted = rankedDecisionResults.sorted { lhs, rhs in
                    return lhs.rank > rhs.rank
                }
                
                var maxList: [RankedResult<DecisionResult>] = [sorted[0]]
                
                for i in 1..<sorted.count {
                    if sorted[i].rank == sorted[0].rank {
                        maxList.append(sorted[i])
                    }
                }

                if maxList.count == 1 {
                    // sorting by rank gave us just one
                    return await recurseOn(result: maxList[0].result, indent: indent) // XXX
                } else {
                    // sort them by type next

                    // XXX maybe sort by something else?

                    let maxSort = maxList.sorted { lhs, rhs in
                        return lhs.result.type < rhs.result.type
                    }
                    
                    return await recurseOn(result: maxSort[0].result, indent: indent) // XXX
                }
            }
        } else {
            Log.e("no best type")
            fatalError("no best result")
        }
    }

    func recurseOn(result: DecisionResult, indent: Int) async -> DecisionTreeNode {
        //Log.d("best at indent \(indent) was \(result.type) \(String(format: "%g", result.lessThanSplit)) \(String(format: "%g", result.greaterThanSplit)) \(String(format: "%g", result.value)) < Should \(result.lessThanShouldPaint.count) < ShouldNot \(result.lessThanShouldNotPaint.count) > Should  \(result.lessThanShouldPaint.count) > ShouldNot \(result.greaterThanShouldNotPaint.count)")

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
            return DecisionTreeNode(realType: result.type,
                                    value: result.value,
                                    lessThan: less_response.treeNode,
                                    greaterThan: greater_response.treeNode,
                                    indent: indent)
        } else {
            Log.e("holy fuck")
            fatalError("doh")
        }
    }
}

@available(macOS 10.15, *) 
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
@available(macOS 10.15, *) 
protocol DecisionTree {
    var type: OutlierGroup.TreeDecisionType? { get }
    var swiftCode: String { get }
}

// end leaf node which always returns true
@available(macOS 10.15, *) 
struct ShouldPaintDecision: DecisionTree {
    var type: OutlierGroup.TreeDecisionType?
    let indent: Int
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return "\(indentation)return true"
    }
}

// end leaf node which always returns false
@available(macOS 10.15, *) 
struct ShouldNotPaintDecision: DecisionTree {
    var type: OutlierGroup.TreeDecisionType?
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
    let realType: OutlierGroup.TreeDecisionType
    let value: Double
    let lessThan: DecisionTree
    let greaterThan: DecisionTree
    let indent: Int

    var type: OutlierGroup.TreeDecisionType? { realType }
    
    var swiftCode: String {
        var indentation = ""
        for _ in 0..<indent { indentation += "    " }
        return """
          \(indentation)if \(realType) < \(value) {
          \(lessThan.swiftCode)
          \(indentation)} else {
          \(greaterThan.swiftCode)
          \(indentation)}
          """
    }
}

fileprivate let file_manager = FileManager.default
