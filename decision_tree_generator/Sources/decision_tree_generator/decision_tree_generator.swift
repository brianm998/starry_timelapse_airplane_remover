import Foundation
import StarCore
import ArgumentParser
import logging
import CryptoKit
import StarDecisionTrees

// XXX WTF
nonisolated(unsafe) var startTime: Date = Date()

// how much do we truncate the sha256 hash when embedding it into code
let shaPrefixSize = 8

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

@main
struct decision_tree_generator: AsyncParsableCommand, @unchecked Sendable {

    @Flag(name: [.customShort("v"), .customLong("verify")],
          help:"""
            Verification mode
            Instead of generating a new decision tree,
            use the existing one to validate one of two things:
              1. how well decision tree matches the test data it came from
              2. how well decision tree matches a known group it was not tested on
            """)
    var verificationMode = false

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
    var produceAllTypeCombinations = false

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
    var testDataDirnames: [String] = []
    
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
    var inputFilenames: [String]
    
    mutating func run() async throws {
        Log.name = "decision_tree_generator-log"
        Log.add(handler: ConsoleLogHandler(at: .verbose), for: .console)
        Log.add(handler: try FileLogHandler(at: .verbose), for: .file)  // XXX make this a command line parameter

        TaskRunner.maxConcurrentTasks = UInt(numConcurrentRenders)
        
        startTime = Date()
        
        Log.i("test-data:  \(testDataDirnames)")
        Log.i("train-data: \(inputFilenames)")
        Log.d("in debug mode")
        if verificationMode {
            try await runVerification()
        } else {
            if let forestSize = forestSize {
                // generate a forest of trees
                // this ignores given test data,
                // instead separating out the input data
                // into train, validate and test segments
                try await generateForestFromTrainingData(with: forestSize)
            } else {
                // generate a single tree
                // this prunes from the give test data
                try await generateTreeFromTrainingData()
            }
        }
        
        await TaskWaiter.shared.finish()
        await logging.gremlin.finishLogging() 
    }

    func runVerification(basedUpon jsonConfigFileName: String) async throws -> TreeTestResults {

        var numSimilarOutlierGroups: [String:Int] = [:]
        var numDifferentOutlierGroups: [String:Int] = [:]
        for (treeKey, _) in decisionTrees {
            numSimilarOutlierGroups[treeKey] = 0
            numDifferentOutlierGroups[treeKey] = 0
        }
        
        let config = try await Config.read(fromJsonFilename: jsonConfigFileName)
        Log.d("got config from \(jsonConfigFileName)")
        
        var callbacks = Callbacks()

        // XXX turn this into an actor that receives tham async

        let newFrames = ArrayActor<FrameAirplaneRemover>()
        
        // called when we should check a frame
        callbacks.frameCheckClosure = { newFrame in
            Task { await newFrames.append(newFrame) }
            Log.d("frameCheckClosure for frame \(newFrame.frameIndex)")
        }
        
        let eraser = try await NighttimeAirplaneRemover(with: config,
                                                        callbacks: callbacks,
                                                        processExistingFiles: true,
                                                        fullyProcess: false)
        let sequenceSize = await eraser.imageSequence.filenames.count
        
        Log.i("got \(sequenceSize) frames")
        // XXX run it and get the outlier groups

        try await eraser.run()

        let frames = await newFrames.elements()
        
        Log.i("loading outliers")
        // after the eraser is done running we should have received all the frames
        // in the frame check callback

        var outlierLoadingTasks: [Task<Void,Error>] = []
        
        // load the outliers in parallel
        for frame in frames {
            let task = try await runThrowingTaskOld() {
                try await frame.loadOutliers()
            }
            outlierLoadingTasks.append(task)
        }
        for task in outlierLoadingTasks { try await task.value }


        var tasks: [Task<TreeTestResults,Never>] = []
        
        Log.i("checkpoint before loading tree test results")
        for frame in frames {
            // check all outlier groups
            
            let task = await runTaskOld() {
                var numberGood: [String: Int] = [:]
                var numberBad: [String: Int] = [:]
                for (treeKey, _) in decisionTrees {
                    numberGood[treeKey] = 0
                    numberBad[treeKey] = 0
                }
                
                //Log.d("should check frame \(frame.frameIndex)")
                if let outlierGroupList = await frame.outlierGroupList() {
                    for outlierGroup in outlierGroupList {
                        if let numberGoodShouldPaint = await outlierGroup.shouldPaint() {
                            await withLimitedTaskGroup(of: (treeKey:String, shouldPaint:Bool).self) { taskGroup in
                                for (treeKey, tree) in decisionTrees {
                                    await taskGroup.addTask() {
                                        let decisionTreeShouldPaint =  
                                          await tree.asyncClassification(of: outlierGroup) > 0
                                        
                                        return (treeKey, decisionTreeShouldPaint == numberGoodShouldPaint.willPaint)
                                    }
                                }
                                await taskGroup.forEach() { result in
                                    if result.shouldPaint {
                                        numberGood[result.treeKey]! += 1
                                    } else {
                                        numberBad[result.treeKey]! += 1
                                    }
                                }
                                
                            }
                        }
                    }
                } else {
                    //Log.e("WTF")
                    //fatalError("DIED HERE")
                }
                //Log.d("numberGood \(numberGood) numberBad \(numberBad)")
                return TreeTestResults(numberGood: numberGood,
                                       numberBad: numberBad)
            }
            tasks.append(task)
        }
        
        for task in tasks {
            let response = await task.value
            
            Log.d("got response response.numberGood \(response.numberGood) response.numberBad \(response.numberBad) ")
            for (treeKey, _) in decisionTrees {
                numSimilarOutlierGroups[treeKey]! += response.numberGood[treeKey]!
                numDifferentOutlierGroups[treeKey]! += response.numberBad[treeKey]!
            }
        }
        
        Log.d("checkpoint at end")
        return TreeTestResults(numberGood: numSimilarOutlierGroups,
                               numberBad: numDifferentOutlierGroups)
    }

    func runVerification() async throws {
        Log.d("runVerification start")
        let classifiedData = ClassifiedData()
        for inputDirname in inputFilenames {
            Log.d("runVerification inputDirname \(inputDirname)")
            if FileManager.default.fileExists(atPath: inputDirname) {
                Log.d("runVerification inputDirname exists \(inputDirname)")
                classifiedData += try await loadDataFrom(dirname: inputDirname)
                Log.d("runVerification inputDirname loaded \(inputDirname)")
            }
        }

        // we've loaded all the classified data
        Log.d("runVerification f1 WTF")

        let results = TreeTestResults()

        let chunkedTestData = classifiedData.split(into: ProcessInfo.processInfo.activeProcessorCount)
        
        for (_, tree) in decisionTrees {
            Log.d("running test on tree \(tree)")
            let (numGood, numBad) = await runTest(of: tree, onChunks: chunkedTestData)
            results.numberGood[tree.name] = numGood
            results.numberBad[tree.name] = numBad
        }
        Log.d("runVerification mid decisionTrees \(decisionTrees)")

        var outputResults: [DecisionTreeResult] = []
        for (treeKey, _) in decisionTrees {
            let total = results.numberGood[treeKey]! + results.numberBad[treeKey]!
            let percentageGood = Double(results.numberGood[treeKey]!)/Double(total)*100
            let message = "For decision Tree \(treeKey) out of a total of \(total) outlier groups, \(percentageGood)% success good \(results.numberGood[treeKey]!) vs bad \(results.numberBad[treeKey]!)"
            outputResults.append(DecisionTreeResult(score: percentageGood,
                                                    message: message))
            Log.d("output results: \(message)")
        }
        // sort these on output by percentageGood
        for result in outputResults.sorted() {
            Log.i(result.message)
        }
        Log.d("runVerification done")
    }

    // read outlier group values from a stored set of files listed by a config.json
    // the reads the full outliers from file, and can be slow
    private func read(fromConfig jsonConfigFileName: String) async throws
      -> ([OutlierFeatureData], // should paint
          [OutlierFeatureData]) // should not paint
    {
        var positiveData: [OutlierFeatureData] = []
        var negativeData: [OutlierFeatureData] = []
        let config = try await Config.read(fromJsonFilename: jsonConfigFileName)
        Log.d("got config from \(jsonConfigFileName)")
        
        var callbacks = Callbacks()

        let newFrames = ArrayActor<FrameAirplaneRemover>()
        
        // called when we should check a frame
        callbacks.frameCheckClosure = { newFrame in
            Task { await newFrames.append(newFrame) }
            Log.d("frameCheckClosure for frame \(newFrame.frameIndex)")
        }
        
        let eraser = try await NighttimeAirplaneRemover(with: config,
                                                        callbacks: callbacks,
                                                        processExistingFiles: true,
                                                        fullyProcess: false)
        let sequenceSize = await eraser.imageSequence.filenames.count
        
        Log.d("got \(sequenceSize) frames")
        // XXX run it and get the outlier groups

        try await eraser.run()

        let frames = await newFrames.elements()
        
        Log.d("eraser done running")
        
        // after the eraser is done running we should have received all the frames
        // in the frame check callback

        // load the outliers in parallel
        var outlierLoadingTasks: [Task<Void,Error>] = []
        
        // load the outliers in parallel
        for frame in frames {
            let task = try await runThrowingTaskOld() {
                try await frame.loadOutliers()
            }
            outlierLoadingTasks.append(task)
        }
        for task in outlierLoadingTasks { try await task.value }

        var tasks: [Task<ClassifiedData,Never>] = []
        
        for frame in frames {
            let task = await runTaskOld() {
                
                var localPositiveData: [OutlierFeatureData] = []
                var localNegativeData: [OutlierFeatureData] = []
                if let outlierGroups = await frame.outlierGroupList() {
                    for outlierGroup in outlierGroups {
                        let name = outlierGroup.id
                        if let shouldPaint = await outlierGroup.shouldPaint() {
                            let willPaint = shouldPaint.willPaint
                            
                            let values = await outlierGroup.decisionTreeGroupValues()
                            
                            if willPaint {
                                localPositiveData.append(values)
                            } else {
                                localNegativeData.append(values)
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
                  positiveData: localPositiveData,
                  negativeData: localNegativeData)
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
    func generateForestFromTrainingData(with forestSize: Int) async throws {

        let generator = DecisionTreeGenerator(withTypes: OutlierGroup.Feature.allCases,
                                              andSplitTypes: [.median],
                                              pruneTree: !noPrune,
                                              maxDepth: maxDepth)

        
        let baseFilename = "../starDecisionTrees/Sources/starDecisionTrees/OutlierGroupDecisionTreeForest_"

        // test data gathered from -t on command line
        let testData = try await loadTestData().split(into: ProcessInfo.processInfo.activeProcessorCount)

        let forest =
          try await generator.generateForest(withInputData: loadTrainingData(),
                                             andTestData: testData,
                                             inputFilenames: inputFilenames,
                                             treeCount: forestSize,
                                             baseFilename: baseFilename) 

        let forestBaseFilename = "../starDecisionTrees/Sources/starDecisionTrees/OutlierGroupForestClassifier_"

        let classifier = try await generator.writeClassifier(with: forest, baseFilename: forestBaseFilename)

        // test classifier and see how well it does on the test data

        let (good, bad) = await runTest(of: classifier, onChunks: testData)
        let score = Double(good)/Double(good + bad)
        Log.i("final forest classifier got score \(score) on test data")

    }

    func loadTestData() async throws -> ClassifiedData {
        let testData = ClassifiedData()
        
        // load testData 
        for dirname in testDataDirnames {
            if FileManager.default.fileExists(atPath: dirname) {
                // load here
                let result = try await loadDataFrom(dirname: dirname)
                testData.positiveData += result.positiveData
                testData.negativeData += result.negativeData
            } else {
                Log.w("cannot load test data from non existant dir \(dirname)")
            }
        }
        return testData
    }

    func loadTrainingData() async throws -> ClassifiedData {
        let trainingData = ClassifiedData()

        for jsonConfigFileName in inputFilenames {
            if jsonConfigFileName.hasSuffix("config.json") {
                // here we are loading the full outlier groups and analyzing based upon that
                // comprehensive, but slow
                Log.d("should read \(jsonConfigFileName)")

                do {
                    let (moreShouldPaint, moreShouldNotPaint) =
                      try await read(fromConfig: jsonConfigFileName)
                    
                    trainingData.positiveData += moreShouldPaint
                    trainingData.negativeData += moreShouldNotPaint
                } catch {
                    Log.w("couldn't get config from \(jsonConfigFileName)")
                    Log.e("\(error)")
                    fatalError("couldn't get config from \(jsonConfigFileName)")
                }
            } else {
                // here we are reading pre-computed values for each data point
                if FileManager.default.fileExists(atPath: jsonConfigFileName) {
                    // load here
                    let result = try await loadDataFrom(dirname: jsonConfigFileName)
                    trainingData.positiveData += result.positiveData
                    trainingData.negativeData += result.negativeData
                }
            }
        }
        return trainingData
    }
    
    // actually generate a decision tree
    func generateTreeFromTrainingData() async throws {
        
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
            if produceAllTypeCombinations {
                let min = OutlierGroup.Feature.allCases.count-1 // XXX make a parameter
                let max = OutlierGroup.Feature.allCases.count
                let combinations = decisionTypes.combinations(ofCount: min..<max)
                Log.i("calculating \(combinations.count) different decision trees")

                var tasks: [Task<Void,Error>] = []
                
                for (index, types) in combinations.enumerated() {
                    Log.i("calculating tree \(index) with \(types)")
                    //let positiveData = trainingData.positiveData.map { $0 } // copy data for each tree generation
                    //let negativeData = trainingData.negativeData.map { $0 }
                    let _inputFilenames = inputFilenames
                    let task = try await runThrowingTaskOld() {
                        _ = try await self.writeTree(withTypes: types,
                                                     withTrainingData: trainingData,
                                                     andTestData: testData,
                                                     inputFilenames: _inputFilenames,
                                                     maxDepth: maxDepth)
                    }
                    tasks.append(task)
                }
                for task in tasks { try await task.value }
            } else {
                _ = try await self.writeTree(withTypes: decisionTypes,
                                             withTrainingData: trainingData,
                                             andTestData: testData,
                                             inputFilenames: inputFilenames,
                                             maxDepth: maxDepth)
            }
        } catch {
            Log.e("\(error)")
        }
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
                        Log.e("@ sort order \(type.sortOrder) \(matrix.types[type.sortOrder]) != \(type), cannot use this data from \(dirname)")
                        usable = false
                        break
                    }
                } else {
                    Log.e("@ sort order \(type.sortOrder) is out of range, cannot use this data from \(dirname)")
                    usable = false
                    break
                }
            }
            
            if usable {
                positiveData = matrix.positiveValues.map { OutlierFeatureData($0) }
                negativeData = matrix.negativeValues.map { OutlierFeatureData($0) }
            } else {
                Log.e("ERROR \(dirname) not usable :(")
            }
        } else {
            throw "Cannot load from \(dirname)"
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

        let baseFilename = "../starDecisionTrees/Sources/starDecisionTrees/OutlierGroupDecisionTree_"

        let treeResponse = 
          try await generator.generateTree(withTrainingData: trainingData,
                                           andTestData: testData,
                                           inputFilenames: inputFilenames,
                                           baseFilename: baseFilename)
        
        let (treeSwiftCode, filename, hashPrefix) = (treeResponse.swiftCode,
                                                     treeResponse.filename,
                                                     treeResponse.name)

        // save this generated swift code to a file
        if FileManager.default.fileExists(atPath: filename) {
            Log.i("overwriting already existing filename \(filename)")
            try FileManager.default.removeItem(atPath: filename)
        }

        // write to file
        FileManager.default.createFile(atPath: filename,
                                       contents: treeSwiftCode.data(using: .utf8),
                                       attributes: nil)
        Log.i("wrote \(filename)")

        return hashPrefix
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
