import Foundation
import StarCore
import ArgumentParser
import CryptoKit

var start_time: Date = Date()

// how much do we truncate the sha256 hash when embedding it into code
let sha_prefix_size = 8

func hostCPULoadInfo() -> host_cpu_load_info? {
    let HOST_CPU_LOAD_INFO_COUNT = MemoryLayout<host_cpu_load_info>.stride/MemoryLayout<integer_t>.stride
    var size = mach_msg_type_number_t(HOST_CPU_LOAD_INFO_COUNT)
    var cpuLoadInfo = host_cpu_load_info()

    let result = withUnsafeMutablePointer(to: &cpuLoadInfo) {
        $0.withMemoryRebound(to: integer_t.self, capacity: HOST_CPU_LOAD_INFO_COUNT) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
        }
    }
    if result != KERN_SUCCESS{
        print("Error  - \(#file): \(#function) - kern_result_t = \(result)")
        return nil
    }
    return cpuLoadInfo
}

func cpuUsage() -> Double {
    var totalUsageOfCPU: Double = 0.0
    var threadsList = UnsafeMutablePointer(mutating: [thread_act_t]())
    var threadsCount = mach_msg_type_number_t(0)
    let threadsResult = withUnsafeMutablePointer(to: &threadsList) {
        return $0.withMemoryRebound(to: thread_act_array_t?.self, capacity: 1) {
            task_threads(mach_task_self_, $0, &threadsCount)
        }
    }
    
    if threadsResult == KERN_SUCCESS {
        for index in 0..<threadsCount {
            var threadInfo = thread_basic_info()
            var threadInfoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let infoResult = withUnsafeMutablePointer(to: &threadInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                    thread_info(threadsList[Int(index)], thread_flavor_t(THREAD_BASIC_INFO), $0, &threadInfoCount)
                }
            }
            
            guard infoResult == KERN_SUCCESS else {
                break
            }
            
            let threadBasicInfo = threadInfo as thread_basic_info
            if threadBasicInfo.flags & TH_FLAGS_IDLE == 0 {
                totalUsageOfCPU = (totalUsageOfCPU + (Double(threadBasicInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0))
            }
        }
    }
    
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadsList)), vm_size_t(Int(threadsCount) * MemoryLayout<thread_t>.stride))
    return totalUsageOfCPU
}

@main
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

    @Option(name: .shortAndLong, help: """
        Max Number of frames to process at once.
        The default of all cpus works good in most cases.
        May need to be reduced to a lower value if to consume less ram on some machines.
        """)
    var numConcurrentRenders: Int = ProcessInfo.processInfo.activeProcessorCount

    @Flag(name: [.customShort("a"), .customLong("all")],
          help:"""
            Iterate over all possible combinations of the decision types to generate
            lots of different trees
            """)
    var produce_all_type_combinations = false

    @Option(name: [.customShort("f"), .customLong("features")],
          help:"""
            Specify a comma delimited list of features from this list:
            
            \(OutlierGroup.Feature.allCasesString)
            """)
    var decisionTypesString: String = ""

    @Option(name: [.customShort("t"), .customLong("test-data")],
          help:"""
            A list of directories containing test data that is not used for training
            """)
    var test_data_dirnames: [String] = []
    
    @Option(name: [.customShort("m"), .customLong("max-depth")],
          help:"""
            Decision tree max depth parameter.
            After this depth, decision tree will stump based upon remaining data.
            """)
    var maxDepth: Int? = nil
    
    @Option(name: [.customLong("forest")],
          help:"""
            When run in forest mode, the given number of trees are produced based upon
            splitting up the input data with a different validation set that number of times.

            Then a higher level classifier is written to combine them all.
            """)
    var forestSize: Int? = nil

    @Flag(name: [.customLong("no-prune")],
          help:"""
            Turn off pruning of trees, which can be slow
            """)
    var noPrune = false
    
    @Argument(help: """
            A list of files, which can be either a reference to a config.json file,
            or a reference to a directory containing data csv files.
            """)
    var input_filenames: [String]
    
    mutating func run() throws {
        Log.name = "decision_tree_generator-log"
        Log.handlers[.console] = ConsoleLogHandler(at: .verbose)
        Log.handlers[.file] = try FileLogHandler(at: .verbose) // XXX make this a command line parameter

        TaskRunner.maxConcurrentTasks = UInt(numConcurrentRenders)
        
        start_time = Date()
        
        Log.i("Starting with cpuUsage \(cpuUsage())")

        Log.i("test-data:  \(test_data_dirnames)")
        Log.i("train-data: \(input_filenames)")
        Log.d("in debug mode")
        if verification_mode {
            run_verification()
        } else {
            if let forestSize = forestSize {
                // generate a forest of trees
                // this ignores given test data,
                // instead separating out the input data
                // into train, validate and test segments
                generate_forest_from_training_data(with: forestSize)                
            } else {
                // generate a single tree
                // this prunes from the give test data
                generate_tree_from_training_data()
            }
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
            Log.d("frameCheckClosure for frame \(new_frame.frameIndex)")
        }
        
        callbacks.countOfFramesToCheck = { 1 }

        let eraser = try await NighttimeAirplaneRemover(with: config,
                                                  callbacks: callbacks,
                                                  processExistingFiles: true,
                                                  fullyProcess: false)
        let sequence_size = await eraser.imageSequence.filenames.count
        endClosure = {
            if frames.count == sequence_size {
                eraser.shouldRun = false
            }
        }
        
        Log.i("got \(sequence_size) frames")
        // XXX run it and get the outlier groups

        try await eraser.run()
        
        Log.i("loading outliers")
        // after the eraser is done running we should have received all the frames
        // in the frame check callback

        var outlierLoadingTasks: [Task<Void,Error>] = []
        
        // load the outliers in parallel
        for frame in frames {
            let task = try await runThrowingTask() {
                try await frame.loadOutliers()
            }
            outlierLoadingTasks.append(task)
        }
        for task in outlierLoadingTasks { try await task.value }


        var tasks: [Task<TreeTestResults,Never>] = []
        
        Log.i("checkpoint before loading tree test results")
        for frame in frames {
            // check all outlier groups
            
            let task = await runTask() {
                var number_good: [String: Int] = [:]
                var number_bad: [String: Int] = [:]
                for (treeKey, _) in decisionTrees {
                    number_good[treeKey] = 0
                    number_bad[treeKey] = 0
                }
                
                //Log.d("should check frame \(frame.frameIndex)")
                if let outlier_group_list = frame.outlierGroupList() {
                    for outlier_group in outlier_group_list {
                        if let numberGood = outlier_group.shouldPaint {
                            await withLimitedTaskGroup(of: (treeKey:String, shouldPaint:Bool).self) { taskGroup in
                                for (treeKey, tree) in decisionTrees {
                                    await taskGroup.addTask() {
                                        let decisionTreeShouldPaint =  
                                          await tree.classification(of: outlier_group) > 0
                                        
                                        return (treeKey, decisionTreeShouldPaint == numberGood.willPaint)
                                    }
                                }
                                await taskGroup.forEach() { result in
                                    if result.shouldPaint {
                                        number_good[result.treeKey]! += 1
                                    } else {
                                        number_bad[result.treeKey]! += 1
                                    }
                                }
                                
                            }
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
            tasks.append(task)
        }
        
        for task in tasks {
            let response = await task.value
            
            Log.d("got response response.numberGood \(response.numberGood) response.numberBad \(response.numberBad) ")
            for (treeKey, _) in decisionTrees {
                num_similar_outlier_groups[treeKey]! += response.numberGood[treeKey]!
                num_different_outlier_groups[treeKey]! += response.numberBad[treeKey]!
            }
        }
        
        Log.d("checkpoint at end")
        return TreeTestResults(numberGood: num_similar_outlier_groups,
                               numberBad: num_different_outlier_groups)
    }

    func run_verification() {
        let dispatch_group = DispatchGroup()
        dispatch_group.enter()
        Task {
            let classifiedData = ClassifiedData()
            for input_dirname in input_filenames {
                if file_manager.fileExists(atPath: input_dirname) {
                    classifiedData += try await loadDataFrom(dirname: input_dirname)
                }
            }
            // we've loaded all the classified data

            var results = TreeTestResults()

            let chunked_test_data = classifiedData.split(into: ProcessInfo.processInfo.activeProcessorCount)
            
            for (_, tree) in decisionTrees {
                let (num_good, num_bad) = await runTest(of: tree, onChunks: chunked_test_data)
                results.numberGood[tree.name] = num_good
                results.numberBad[tree.name] = num_bad
            }

            var outputResults: [DecisionTreeResult] = []
            for (treeKey, _) in decisionTrees {
                let total = results.numberGood[treeKey]! + results.numberBad[treeKey]!
                let percentage_good = Double(results.numberGood[treeKey]!)/Double(total)*100
                let message = "For decision Tree \(treeKey) out of a total of \(total) outlier groups, \(percentage_good)% success good \(results.numberGood[treeKey]!) vs bad \(results.numberBad[treeKey]!)"
                outputResults.append(DecisionTreeResult(score: percentage_good,
                                                        message: message))
            }
            // sort these on output by percentage_good
            for result in outputResults.sorted() {
                Log.i(result.message)
            }
            
            dispatch_group.leave()
        }
        dispatch_group.wait()
    }

    // read outlier group values from a stored set of files listed by a config.json
    // the reads the full outliers from file, and can be slow
    private func read(fromConfig json_config_file_name: String) async throws
      -> ([OutlierFeatureData], // should paint
          [OutlierFeatureData]) // should not paint
    {
        var positiveData: [OutlierFeatureData] = []
        var negativeData: [OutlierFeatureData] = []
        let config = try await Config.read(fromJsonFilename: json_config_file_name)
        Log.d("got config from \(json_config_file_name)")
        
        let callbacks = Callbacks()

        var frames: [FrameAirplaneRemover] = []
        
        var endClosure: () -> Void = { }
        
        // called when we should check a frame
        callbacks.frameCheckClosure = { new_frame in
            Log.d("frameCheckClosure for frame \(new_frame.frameIndex)")
            frames.append(new_frame)
            endClosure()
        }
        
        callbacks.countOfFramesToCheck = { 1 }

        let eraser = try await NighttimeAirplaneRemover(with: config,
                                                   callbacks: callbacks,
                                                   processExistingFiles: true,
                                                   fullyProcess: false)
        let sequence_size = await eraser.imageSequence.filenames.count
        endClosure = {
            Log.d("end enclosure frames.count \(frames.count) sequence_size \(sequence_size)")
            if frames.count == sequence_size {
                eraser.shouldRun = false
            }
        }
        
        Log.d("got \(sequence_size) frames")
        // XXX run it and get the outlier groups

        try await eraser.run()

        Log.d("eraser done running")
        
        // after the eraser is done running we should have received all the frames
        // in the frame check callback

        // load the outliers in parallel
        var outlierLoadingTasks: [Task<Void,Error>] = []
        
        // load the outliers in parallel
        for frame in frames {
            let task = try await runThrowingTask() {
                try await frame.loadOutliers()
            }
            outlierLoadingTasks.append(task)
        }
        for task in outlierLoadingTasks { try await task.value }

        var tasks: [Task<ClassifiedData,Never>] = []
        
        for frame in frames {
            let task = await runTask() {
                
                var local_positive_data: [OutlierFeatureData] = []
                var local_negative_data: [OutlierFeatureData] = []
                if let outlier_groups = frame.outlierGroupList() {
                    for outlier_group in outlier_groups {
                        let name = outlier_group.name
                        if let should_paint = outlier_group.shouldPaint {
                            let will_paint = should_paint.willPaint
                            
                            let values = await outlier_group.decisionTreeGroupValues
                            
                            if will_paint {
                                local_positive_data.append(values)
                            } else {
                                local_negative_data.append(values)
                            }
                        } else {
                            Log.e("outlier group \(name) has no shouldPaint value")
                            fatalError("outlier group \(name) has no shouldPaint value")
                        }
                    }
                } else {
                    Log.e("cannot get outlier groups for frame \(frame.frameIndex)")
                    fatalError("cannot get outlier groups for frame \(frame.frameIndex)")
                }
                return ClassifiedData(
                  positiveData: local_positive_data,
                  negativeData: local_negative_data)
            }
            tasks.append(task)
        }
        
        for task in tasks {
            let response = await task.value
            positiveData += response.positiveData
            negativeData += response.negativeData
        }

        return (positiveData, negativeData)
    }

    // actually generate a decision tree forest
    func generate_forest_from_training_data(with forestSize: Int) {

        Log.d("generate_forest_from_training_data")
        
        let dispatch_group = DispatchGroup()
        dispatch_group.enter()
        Task {

            let generator = DecisionTreeGenerator(withTypes: OutlierGroup.Feature.allCases,
                                                  andSplitTypes: [.median],
                                                  pruneTree: !noPrune,
                                                  maxDepth: maxDepth)

            
            let base_filename = "../starDecisionTrees/Sources/starDecisionTrees/OutlierGroupDecisionTreeForest_"

            // test data gathered from -t on command line
            let testData = try await loadTestData().split(into: ProcessInfo.processInfo.activeProcessorCount)
            
            let forest =
              try await generator.generateForest(withInputData: loadTrainingData(),
                                                 andTestData: testData,
                                                 inputFilenames: input_filenames,
                                                 treeCount: forestSize,
                                                 baseFilename: base_filename) 

            let forest_base_filename = "../starDecisionTrees/Sources/starDecisionTrees/OutlierGroupForestClassifier_"

            let classifier = try await generator.writeClassifier(with: forest, baseFilename: forest_base_filename)

            // test classifier and see how well it does on the test data

            let (good, bad) = await runTest(of: classifier, onChunks: testData)
            let score = Double(good)/Double(good + bad)
            Log.i("final forest classifier got score \(score) on test data")

            dispatch_group.leave()
        }
        dispatch_group.wait()
    }

    func loadTestData() async throws -> ClassifiedData {
        let testData = ClassifiedData()
        
        // load testData 
        for dirname in test_data_dirnames {
            if file_manager.fileExists(atPath: dirname) {
                // load here
                let result = try await loadDataFrom(dirname: dirname)
                testData.positiveData += result.positiveData
                testData.negativeData += result.negativeData
            }
        }
        return testData
    }

    func loadTrainingData() async throws -> ClassifiedData {
        let trainingData = ClassifiedData()

        for json_config_file_name in input_filenames {
            if json_config_file_name.hasSuffix("config.json") {
                // here we are loading the full outlier groups and analyzing based upon that
                // comprehensive, but slow
                Log.d("should read \(json_config_file_name)")

                do {
                    let (more_should_paint, more_should_not_paint) =
                      try await read(fromConfig: json_config_file_name)
                    
                    trainingData.positiveData += more_should_paint
                    trainingData.negativeData += more_should_not_paint
                } catch {
                    Log.w("couldn't get config from \(json_config_file_name)")
                    Log.e("\(error)")
                    fatalError("couldn't get config from \(json_config_file_name)")
                }
            } else {
                // here we are reading pre-computed values for each data point
                if file_manager.fileExists(atPath: json_config_file_name) {
                    // load here
                    let result = try await loadDataFrom(dirname: json_config_file_name)
                    trainingData.positiveData += result.positiveData
                    trainingData.negativeData += result.negativeData
                }
            }
        }
        return trainingData
    }
    
    // actually generate a decision tree
    func generate_tree_from_training_data() {
        
        let dispatch_group = DispatchGroup()
        dispatch_group.enter()
        Task {
            var decisionTypes: [OutlierGroup.Feature] = []

            Log.d("decisionTypesString \(decisionTypesString)")
            
            if decisionTypesString == "" {
                // if not specfied, use all types
                decisionTypes = OutlierGroup.Feature.allCases
            } else {
                // split out given types
                let rawValues = decisionTypesString.components(separatedBy: ",")
                for rawValue in rawValues {
                    if let enumValue = OutlierGroup.Feature(rawValue: rawValue) {
                        decisionTypes.append(enumValue)
                    } else {
                        Log.w("type \(rawValue) is not a member of OutlierGroup.Feature")
                    }
                }
            }
            
            // training data gathered from all inputs
            let trainingData = try await loadTrainingData()

            Log.i("data loaded")

            // test data gathered from -t on command line
            let testData = try await loadTestData()
            
            do {
                if produce_all_type_combinations {
                    let min = OutlierGroup.Feature.allCases.count-1 // XXX make a parameter
                    let max = OutlierGroup.Feature.allCases.count
                    let combinations = decisionTypes.combinations(ofCount: min..<max)
                    Log.i("calculating \(combinations.count) different decision trees")

                    var tasks: [Task<Void,Error>] = []
                    
                    for (index, types) in combinations.enumerated() {
                        Log.i("calculating tree \(index) with \(types)")
                        //let positiveData = trainingData.positiveData.map { $0 } // copy data for each tree generation
                        //let negativeData = trainingData.negativeData.map { $0 }
                        let _input_filenames = input_filenames
                        let task = try await runThrowingTask() {
                            _ = try await self.writeTree(withTypes: types,
                                                         withTrainingData: trainingData,
                                                         andTestData: testData,
                                                         inputFilenames: _input_filenames,
                                                         maxDepth: maxDepth)
                        }
                        tasks.append(task)
                    }
                    for task in tasks { try await task.value }
                } else {
                    _ = try await self.writeTree(withTypes: decisionTypes,
                                                 withTrainingData: trainingData,
                                                 andTestData: testData,
                                                 inputFilenames: input_filenames,
                                                 maxDepth: maxDepth)
                }
            } catch {
                Log.e("\(error)")
            }
            dispatch_group.leave()
        }
        dispatch_group.wait()
    }

    func loadDataFrom(dirname: String) async throws -> ClassifiedData {
        var positiveData: [OutlierFeatureData] = []
        var negativeData: [OutlierFeatureData] = []

        if let matrix = try await OutlierGroupValueMatrix(from: dirname) {
            // XXX ignoring the types :(

            var usable = true
            
            // XXX make sure the types in the matrix match up with what we expect
            for type in OutlierGroup.Feature.allCases {
                if type.sortOrder < matrix.types.count {
                    if matrix.types[type.sortOrder] != type {
                        Log.e("@ sort order \(type.sortOrder) \(matrix.types[type.sortOrder]) != \(type), cannot use this data")
                        usable = false
                    }
                } else {
                    Log.e("@ sort order \(type.sortOrder) is out of range, cannot use this data")
                    usable = false
                }
            }
            
            if usable {
                positiveData = matrix.positiveValues.map { OutlierFeatureData($0) }
                negativeData = matrix.negativeValues.map { OutlierFeatureData($0) }
            }
        } else {
            throw "fuck"        // XXX un-fuck this
        }
        return ClassifiedData(
          positiveData: positiveData,
          negativeData: negativeData)
    }
    
    func writeTree(withTypes decisionTypes: [OutlierGroup.Feature],
                   withTrainingData trainingData: ClassifiedData,
                   andTestData testData: ClassifiedData,
                   inputFilenames: [String],
                   maxDepth: Int? = nil) async throws {
        /*
        await self.writeTree(withTypes: decisionTypes,
                             andSplitTypes: [.mean],
                             withPositiveData: positive_training_data,
                             andNegativeData: negative_training_data,
                             inputFilenames: inputFilenames)
*/
        // .median seems best, but more exploration possible
        _ = try await self.writeTree(withTypes: decisionTypes,
                                     andSplitTypes: [.median],
                                     withTrainingData: trainingData,
                                     andTestData: testData,
                                     inputFilenames: inputFilenames,
                                     maxDepth: maxDepth)
/*
        await self.writeTree(withTypes: decisionTypes,
                             andSplitTypes: [.mean, .median],
                             withPositiveData: positive_training_data,
                             andNegativeData: negative_training_data,
                             inputFilenames: inputFilenames)
 */
    }
    
    func writeTree(withTypes decisionTypes: [OutlierGroup.Feature],
                   andSplitTypes splitTypes: [DecisionSplitType],
                   withTrainingData trainingData: ClassifiedData,
                   andTestData testData: ClassifiedData,
                   inputFilenames: [String],
                   maxDepth: Int? = nil) async throws -> String {
        
        Log.i("Calculating decision tree with \(trainingData.positiveData.count) should paint \(trainingData.negativeData.count) should not paint test data outlier groups")

        let prune = !noPrune && testData.positiveData.count != 0 && testData.negativeData.count != 0
        
        let generator = DecisionTreeGenerator(withTypes: decisionTypes,
                                              andSplitTypes: splitTypes,
                                              pruneTree: prune,
                                              maxDepth: maxDepth)

        let base_filename = "../starDecisionTrees/Sources/starDecisionTrees/OutlierGroupDecisionTree_"

        let treeResponse = 
          try await generator.generateTree(withTrainingData: trainingData,
                                           andTestData: testData,
                                           inputFilenames: input_filenames,
                                           baseFilename: base_filename)
        
        let (tree_swift_code, filename, hash_prefix) = (treeResponse.swiftCode,
                                                        treeResponse.filename,
                                                        treeResponse.name)

        // save this generated swift code to a file
        if file_manager.fileExists(atPath: filename) {
            Log.i("overwriting already existing filename \(filename)")
            try file_manager.removeItem(atPath: filename)
        }

        // write to file
        file_manager.createFile(atPath: filename,
                                contents: tree_swift_code.data(using: .utf8),
                                attributes: nil)
        Log.i("wrote \(filename)")

        return hash_prefix
    }
    
    func log(valueMaps: [OutlierFeatureData]) async {
        for (index, valueMap) in valueMaps.enumerated() {
            var log = "\(index) - "
            for type in OutlierGroup.Feature.allCases {
                 let value = valueMap.values[type.sortOrder] 
                 log += "\(String(format: "%.3g", value)) "
            }
            Log.d(log)
        }
    }
}

extension OutlierGroup.Feature: ExpressibleByArgument {

    public init?(argument: String) {
        if let me = OutlierGroup.Feature(rawValue: argument) {
            self = me
        } else {
            return nil
        }
    }
}

fileprivate let file_manager = FileManager.default
