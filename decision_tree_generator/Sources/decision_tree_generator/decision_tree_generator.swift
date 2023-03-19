import Foundation
import NtarCore
import ArgumentParser
import BinaryCodable
import CryptoKit

var start_time: Date = Date()

@available(macOS 10.15, *) 
struct OutlierGroupValueMapResult {
    let should_paint_test_data: [OutlierGroupValueMap]
    let should_not_paint_test_data: [OutlierGroupValueMap]
}

struct TreeTestResults {
    let numberGood: [String:Int]
    let numberBad: [String:Int]
}

// how much do we truncate the sha256 hash when embedding it into code
let sha_prefix_size = 8


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

    @Flag(name: [.customShort("a"), .customLong("all")],
          help:"""
            Iterate over all possible combinations of the decision types to generate
            lots of different trees
            """)
    var produce_all_type_combinations = false

    @Option(name: [.customShort("t"), .customLong("types")],
          help:"""
            Specify a comma delimited list of types from this list:
            
            \(OutlierGroup.TreeDecisionType.allCasesString)
            """)
    var decisionTypesString: String = ""
    
    @Argument(help: """
                A list of files, which can be either a reference to a config.json file,
                or a reference to a directory containing files ending with '_outlier_values.bin'
        """)
    var input_filenames: [String]
    
    mutating func run() throws {
        Log.name = "decision_tree_generator-log"
        Log.handlers[.console] = ConsoleLogHandler(at: .debug)
        Log.handlers[.file] = try FileLogHandler(at: .verbose) // XXX make this a command line parameter

        start_time = Date()
        Log.i("Starting")

        if verification_mode {
            run_verification()
        } else {
            generate_tree_from_input_files()
        }
        Log.dispatchGroup.wait()
    }

    func runVerification(basedUpon json_config_file_name: String) async throws -> TreeTestResults {

        var num_similar_outlier_groups:[String:Int] = [:]
        var num_different_outlier_groups:[String:Int] = [:]
        for (treeKey, _) in decisionTrees {
            num_similar_outlier_groups[treeKey] = 0
            num_different_outlier_groups[treeKey] = 0
        }
        
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
                    var number_good: [String: Int] = [:]
                    var number_bad: [String: Int] = [:]
                    for (treeKey, _) in decisionTrees {
                        number_good[treeKey] = 0
                        number_bad[treeKey] = 0
                    }

                    //Log.d("should check frame \(frame.frame_index)")
                    if let outlier_group_list = await frame.outlierGroups() {
                        for outlier_group in outlier_group_list {
                            if let numberGood = await outlier_group.shouldPaint {


                                for (treeKey, tree) in decisionTrees {
                                    let decisionTreeShouldPaint =  
                                      await tree.shouldPaintFromDecisionTree(group: outlier_group)


                                    if decisionTreeShouldPaint == numberGood.willPaint {
                                        number_good[treeKey]! += 1
                                    } else {
                                        number_bad[treeKey]! += 1
                                    }
                                    
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
                for (treeKey, _) in decisionTrees {
                    num_similar_outlier_groups[treeKey]! += response.numberGood[treeKey]!
                    num_different_outlier_groups[treeKey]! += response.numberBad[treeKey]!
                }
            }
        }
        Log.d("checkpoint at end")
        //let total = num_similar_outlier_groups + num_different_outlier_groups
        //let percentage_good = Double(num_similar_outlier_groups)/Double(total)*100
        //Log.i("for \(json_config_file_name), out of \(total) \(percentage_good)% success")
        return TreeTestResults(numberGood: num_similar_outlier_groups,
                               numberBad: num_different_outlier_groups)
    }
    
    // use an exising decision tree to see how well it does against a given sample
    func run_verification() {
        let dispatch_group = DispatchGroup()
        dispatch_group.enter()
        Task {
        try await withThrowingLimitedTaskGroup(of: Optional<TreeTestResults>.self) { taskGroup in
            // XXX could do these all in parallel with a task group
            var allResults: [TreeTestResults] = []
            for json_config_file_name in input_filenames {
                try await taskGroup.addTask() {
                    if json_config_file_name.hasSuffix("config.json") {
                        do {
                            return try await runVerification(basedUpon: json_config_file_name)
                        } catch {
                            Log.e("\(error)")
                        }
                    } else {
                        if file_manager.fileExists(atPath: json_config_file_name) {
                            var number_good: [String: Int] = [:]
                            var number_bad: [String: Int] = [:]
                            for (treeKey, _) in decisionTrees {
                                number_good[treeKey] = 0
                                number_bad[treeKey] = 0
                            }
                            
                            // load a list of OutlierGroupValueMatrix
                            // and get outlierGroupValues from them
                            let contents = try file_manager.contentsOfDirectory(atPath: json_config_file_name)
                            let decoder = BinaryDecoder()
                            for file in contents {
                                if file.hasSuffix("_outlier_values.bin") {
                                    let filename = "\(json_config_file_name)/\(file)"
                                    do {
                                        // load data
                                        // process a frames worth of outlier data
                                        let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)
                                        
                                        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: imageURL as URL))
                                        
                                        let matrix = try decoder.decode(OutlierGroupValueMatrix.self, from: data)
                                        
                                        for values in matrix.values {
                                            // XXX how to reference hash properly here ???
                                            // could search for classes that conform to a new protocol
                                            // that defines this specific method, but it's static :(

                                            for (treeKey, tree) in decisionTrees {
                                                let decisionTreeShouldPaint =  
                                                  tree.shouldPaintFromDecisionTree(types: matrix.types,
                                                                                   values: values.values)
                                                if decisionTreeShouldPaint == values.shouldPaint {
                                                    number_good[treeKey]! += 1
                                                } else {
                                                    number_bad[treeKey]! += 1
                                                }
                                            }
                                        }
                                    } catch {
                                        Log.e("\(error)")
                                    }
                                }
                            }

                            // XXX combine these all
                            
                            //let total = number_good + number_bad
                            //let percentage_good = Double(number_good)/Double(total)*100
                            //Log.i("for \(json_config_file_name), out of \(total) \(percentage_good)% success good \(number_good) vs bad \(number_bad)")
                            
                            return TreeTestResults(numberGood: number_good,
                                                   numberBad: number_bad)
                        }
                    }
                    return nil
                }
            }
            while let response = try await taskGroup.next() {
                if let response = response {
                    allResults.append(response)
                }
            }
            var number_good:[String:Int] = [:]
            var number_bad:[String:Int] = [:]
            for (treeKey, _) in decisionTrees {
                number_good[treeKey] = 0
                number_bad[treeKey] = 0
            }
            
            for result in allResults {
                for (treeKey, _) in decisionTrees {
                    number_good[treeKey]! += result.numberGood[treeKey]!
                    number_bad[treeKey]! += result.numberBad[treeKey]!
                }
            }
            for (treeKey, _) in decisionTrees {
                let total = number_good[treeKey]! + number_bad[treeKey]!
                let percentage_good = Double(number_good[treeKey]!)/Double(total)*100
                Log.i("For decision Tree \(treeKey) out of a total of \(total) outlier groups, \(percentage_good)% success good \(number_good[treeKey]!) vs bad \(number_bad[treeKey]!)")
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
    func generate_tree_from_input_files() {
        
        let dispatch_group = DispatchGroup()
        dispatch_group.enter()
        Task {
            var decisionTypes: [OutlierGroup.TreeDecisionType] = []

            Log.d("decisionTypesString \(decisionTypesString)")
            
            if decisionTypesString == "" {
                // if not specfied, use all types
                decisionTypes = OutlierGroup.TreeDecisionType.allCases
            } else {
                // split out given types
                let rawValues = decisionTypesString.components(separatedBy: ",")
                for rawValue in rawValues {
                    if let enumValue = OutlierGroup.TreeDecisionType(rawValue: rawValue) {
                        decisionTypes.append(enumValue)
                    } else {
                        Log.w("type \(rawValue) is not a member of OutlierGroup.TreeDecisionType")
                    }
                }
            }
            
            // test data gathered from all inputs
            var should_paint_test_data: [OutlierGroupValueMap] = []
            var should_not_paint_test_data: [OutlierGroupValueMap] = []
            
            for json_config_file_name in input_filenames {
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
                    if file_manager.fileExists(atPath: json_config_file_name) {
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
                                        
                                        Log.d("\(file) loading data")

                                        // load data
                                        // process a frames worth of outlier data
                                        let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)
                                        
                                        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: imageURL as URL))
                                        
                                        //Log.d("\(file) data loaded")
                                        let decoder = BinaryDecoder()
                                        do {
                                            let matrix = try decoder.decode(OutlierGroupValueMatrix.self, from: data)
                                            //Log.d("\(file) data decoded")
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
                                            
                                        } catch {
                                            Log.e("\(file): \(error)")
                                        }
                                        //Log.i("got \(local_should_paint_test_data.count)/\(local_should_not_paint_test_data.count) test data from \(file)")
                                        
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

            if produce_all_type_combinations {
                let min = OutlierGroup.TreeDecisionType.allCases.count-1 // XXX make a parameter
                let max = OutlierGroup.TreeDecisionType.allCases.count
                let combinations = decisionTypes.combinations(ofCount: min..<max)
                Log.i("calculating \(combinations.count) different decision trees")
                for (index, types) in combinations.enumerated() {
                    Log.i("calculating tree \(index) with \(types)")
                    await self.writeTree(withTypes: types,
                                         withTrueData: should_paint_test_data,
                                         andFalseData: should_not_paint_test_data,
                                         inputFilenames: input_filenames)
                }
            } else {
                await self.writeTree(withTypes: decisionTypes,
                                     withTrueData: should_paint_test_data,
                                     andFalseData: should_not_paint_test_data,
                                     inputFilenames: input_filenames)
            }
            
            dispatch_group.leave()
        }
        dispatch_group.wait()
    }

    func writeTree(withTypes decisionTypes: [OutlierGroup.TreeDecisionType],
                   withTrueData should_paint_test_data: [OutlierGroupValueMap],
                   andFalseData should_not_paint_test_data: [OutlierGroupValueMap],
                   inputFilenames: [String]) async {
        
        Log.i("Calculating decision tree with \(should_paint_test_data.count) should paint \(should_not_paint_test_data.count) should not paint test data outlier groups")

        let generator = DecisionTreeGenerator(withTypes: decisionTypes)

        let (tree_swift_code, sha_hash) =
          await generator.generateTree(withTrueData: should_paint_test_data,
                                       andFalseData: should_not_paint_test_data,
                                       inputFilenames: input_filenames)

        // save this generated swift code to a file

        // XXX make this better
        let filename = "../NtarCore/Sources/NtarCore/OutlierGroupDecisionTree_\(sha_hash.prefix(sha_prefix_size)).swift"
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
    
}

@available(macOS 10.15, *) 
extension OutlierGroup.TreeDecisionType: ExpressibleByArgument {

    public init?(argument: String) {
        if let me = OutlierGroup.TreeDecisionType(rawValue: argument) {
            self = me
        } else {
            return nil
        }
    }
}

fileprivate let file_manager = FileManager.default
