import Foundation
import NtarCore
import ArgumentParser
import BinaryCodable
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
                or a reference to a directory containing files ending with '_outlier_values.bin'
        """)
    var input_filenames: [String]
    
    mutating func run() throws {
        Log.name = "decision_tree_generator-log"
        Log.handlers[.console] = ConsoleLogHandler(at: .info)
        Log.handlers[.file] = try FileLogHandler(at: .verbose) // XXX make this a command line parameter

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
                
                //Log.d("should check frame \(frame.frame_index)")
                if let outlier_group_list = await frame.outlierGroups() {
                    for outlier_group in outlier_group_list {
                        if let numberGood = await outlier_group.shouldPaint {
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
            var classifiedData = ClassifiedData()
            for input_dirname in input_filenames {
                if file_manager.fileExists(atPath: input_dirname) {
                    classifiedData += try await loadDataFrom(dirname: input_dirname)
                }
            }
            // we've loaded all the classified data

            var results = TreeTestResults()

            let chunked_test_data = classifiedData.split(into: ProcessInfo.processInfo.activeProcessorCount)
            
            for (treeKey, tree) in decisionTrees {
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

    
    // use an exising decision tree to see how well it does against a given sample
    // this works against config.json files (the slow way) as well as raw data
    func run_verification_old() {
        
        let dispatch_group = DispatchGroup()
        dispatch_group.enter()
        Task {
            
            var tasks: [Task<TreeTestResults?,Error>] = []
            
            var allResults: [TreeTestResults] = []
            for json_config_file_name in input_filenames {
                let task: Task<TreeTestResults?,Error> = try await runThrowingTask() {
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
                                            await withLimitedTaskGroup(of: (treeKey:String, shouldPaint:Bool).self) { taskGroup in
                                                for (treeKey, tree) in decisionTrees {
                                                    await taskGroup.addTask() {
                                                        let decisionTreeShouldPaint =  
                                                          tree.classification(of: matrix.types,
                                                                              and: values.values) > 0
                                                        return (treeKey, decisionTreeShouldPaint == values.shouldPaint)
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
                tasks.append(task)
                
                for task in tasks {
                    let response = try await task.value
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
                var outputResults: [DecisionTreeResult] = []
                for (treeKey, _) in decisionTrees {
                    let total = number_good[treeKey]! + number_bad[treeKey]!
                    let percentage_good = Double(number_good[treeKey]!)/Double(total)*100
                    let message = "For decision Tree \(treeKey) out of a total of \(total) outlier groups, \(percentage_good)% success good \(number_good[treeKey]!) vs bad \(number_bad[treeKey]!)"
                    outputResults.append(DecisionTreeResult(score: percentage_good,
                                                            message: message))
                }
                // sort these on output by percentage_good
                for result in outputResults.sorted() {
                    Log.i(result.message)
                }
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
                if let outlier_groups = await frame.outlierGroups() {
                    for outlier_group in outlier_groups {
                        let name = await outlier_group.name
                        if let should_paint = await outlier_group.shouldPaint {
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
                    Log.e("cannot get outlier groups for frame \(frame.frame_index)")
                    fatalError("cannot get outlier groups for frame \(frame.frame_index)")
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
        
        let dispatch_group = DispatchGroup()
        dispatch_group.enter()
        Task {

            let generator = DecisionTreeGenerator(withTypes: OutlierGroup.Feature.allCases,
                                                  andSplitTypes: [.median],
                                                  pruneTree: !noPrune,
                                                  maxDepth: maxDepth)

            let base_filename = "../NtarDecisionTrees/Sources/NtarDecisionTrees/OutlierGroupDecisionTreeForest_"

            
            let (forest, testData) =
              try await generator.generateForest(withInputData: loadTrainingData(),
                                                 inputFilenames: input_filenames,
                                                 treeCount: forestSize,
                                                 baseFilename: base_filename) 

            let forest_base_filename = "../NtarDecisionTrees/Sources/NtarDecisionTrees/OutlierGroupForestClassifier_"

            let classifier = try await generator.writeClassifier(with: forest, baseFilename: forest_base_filename)

            // test classifier and see how well it does on the training data

            var (good, bad) = await runTest(of: classifier, onChunks: testData)
            let score = Double(good)/Double(good + bad)
            Log.i("final forest classifier got score \(score) on test data")

            dispatch_group.leave()
        }
        dispatch_group.wait()
    }

    func loadTestData() async throws -> ClassifiedData {
        var testData = ClassifiedData()
        
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
        var trainingData = ClassifiedData()
        
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
            var trainingData = try await loadTrainingData()

            Log.i("data loaded")

            // test data gathered from -t on command line
            var testData = try await loadTestData()
            
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
                            try await self.writeTree(withTypes: types,
                                                     withTrainingData: trainingData,
                                                     andTestData: testData,
                                                     inputFilenames: _input_filenames,
                                                     maxDepth: maxDepth)
                        }
                        tasks.append(task)
                    }
                    for task in tasks { try await task.value }
                } else {
                    try await self.writeTree(withTypes: decisionTypes,
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

        try await withLimitedThrowingTaskGroup(of: ClassifiedData.self) { taskGroup in
            // load a list of OutlierGroupValueMatrix
            // and get outlierGroupValues from them
            let contents = try file_manager.contentsOfDirectory(atPath: dirname)
            for file in contents {
                if file.hasSuffix("_outlier_values.bin") {
                    let filename = "\(dirname)/\(file)"
                    
                    try await taskGroup.addTask() {
                        return try await loadDataFrom(filename: filename)
                    }
                }
            }
            try await taskGroup.forEach() { response in
                positiveData += response.positiveData
                negativeData += response.negativeData
            }
        }
        return ClassifiedData(
          positiveData: positiveData,
          negativeData: negativeData)
    }
    
    func loadDataFrom(filename: String) async throws -> ClassifiedData {
        var local_positive_data: [OutlierFeatureData] = []
        var local_negative_data: [OutlierFeatureData] = []
        
        Log.d("\(filename) loading data")
        
        // load data
        // process a frames worth of outlier data
        let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)
        
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: imageURL as URL))
        
        //Log.d("\(file) data loaded")
        let decoder = BinaryDecoder()

        let matrix = try decoder.decode(OutlierGroupValueMatrix.self, from: data)

        var usable = true
        
        // XXX make sure the types in the matrix match up with what we expect
        for type in OutlierGroup.Feature.allCases {
            if matrix.types[type.sortOrder] != type {
                Log.e("@ sort order \(type.sortOrder) \(matrix.types[type.sortOrder]) != \(type), cannot use this data")
                usable = false
            }
        }

        if usable {
            for values in matrix.values {
                let valueMap = OutlierFeatureData() { index in
                    return values.values[index]
                }
                if values.shouldPaint {
                    local_positive_data.append(valueMap)
                } else {
                    local_negative_data.append(valueMap)
                }
            }
        }
            
        //Log.i("got \(local_positive_data.count)/\(local_negative_data.count) test data from \(file)")
        
        return ClassifiedData(
          positiveData: local_positive_data,
          negativeData: local_negative_data)

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
        try await self.writeTree(withTypes: decisionTypes,
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

        let generator = DecisionTreeGenerator(withTypes: decisionTypes,
                                              andSplitTypes: splitTypes,
                                              pruneTree: !noPrune,
                                              maxDepth: maxDepth)

        let base_filename = "../NtarDecisionTrees/Sources/NtarDecisionTrees/OutlierGroupDecisionTree_"

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

@available(macOS 10.15, *) 
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
