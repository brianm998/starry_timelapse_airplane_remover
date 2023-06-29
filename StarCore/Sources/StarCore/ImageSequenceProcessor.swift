import Foundation
import CoreGraphics
import Cocoa

public func mkdir(_ path: String) throws {
    if !fileManager.fileExists(atPath: path) {
        try fileManager.createDirectory(atPath: path,
                                         withIntermediateDirectories: false,
                                         attributes: nil)
    }
}

public class ImageSequenceProcessor<T> {

    // the name of the directory holding the image sequence being processed
    public let imageSequenceDirname: String

    // the name of the directory to write processed images to
    public let outputDirname: String

    // the max number of frames to process at one time
    public let maxConcurrentRenders: Int

    public let numberFinalProcessingNeighborsNeeded: Int
    
    // the following properties get included into the output videoname
    
    // actors
    var methodList = MethodList<T>()       // a list of methods to process each frame

    // how many methods are running right now
    let numberRunning: NumberRunning
    
    public var imageSequence: ImageSequence    // the sequence of images that we're processing

    // concurrent dispatch queue so we can process frames in parallel
    
    public let dispatchGroup = DispatchHandler()

    public var shouldRun = true
    
    var shouldProcess: [Bool] = []       // indexed by frame number
    var existingOutputFiles: [Bool] = [] // indexed by frame number

    var remainingImagesClosure: ((Int) -> Void)?

    // if this is true, outliers are detected, inter-frame processing is done
    // if false, frames are handed back without outliers detected
    let fullyProcess: Bool
    
    init(imageSequenceDirname: String,
         outputDirname: String,
         maxConcurrent: Int = 5,
         supportedImageFileTypes: [String],
         numberFinalProcessingNeighborsNeeded: Int,
         processExistingFiles: Bool,
         maxImages: Int? = nil,
         fullyProcess: Bool = true) throws
    {
        self.numberRunning = NumberRunning()
        self.maxConcurrentRenders = maxConcurrent
        self.imageSequenceDirname = imageSequenceDirname
        self.outputDirname = outputDirname
        self.numberFinalProcessingNeighborsNeeded = numberFinalProcessingNeighborsNeeded
        self.imageSequence = try ImageSequence(dirname: imageSequenceDirname,
                                                supportedImageFileTypes: supportedImageFileTypes,
                                                maxImages: maxImages)
        self.shouldProcess = [Bool](repeating: processExistingFiles, count: imageSequence.filenames.count)
        self.existingOutputFiles = [Bool](repeating: false, count: imageSequence.filenames.count)
        self.fullyProcess = fullyProcess
        self.methodList = try assembleMethodList()
    }

    func processFrame(number index: Int,
                      outputFilename: String,
                      baseName: String) async throws -> T? 
    {
        Log.e("should be overridden")
        fatalError("should be overridden")
    }

    func assembleMethodList() throws -> MethodList<T> {
        /*
           read all existing output files 
           sort them into frame order
           remove ones within numberFinalProcessingNeighborsNeeded frames of holes
           make sure these re-runs doesn't bork on existing files later
           only process below based upon this info
        */
    
        var _methodList: [Int : () async throws -> T] = [:]
        
        for (index, imageFilename) in imageSequence.filenames.enumerated() {
            let basename = removePath(fromString: imageFilename)
            let outputFilename = "\(outputDirname)/\(basename)"
            if fileManager.fileExists(atPath: outputFilename) {
                existingOutputFiles[index] = true
            }                                  
        }
        
        for (index, outputFileAlreadyExists) in existingOutputFiles.enumerated() {
            if !outputFileAlreadyExists {
                var startIdx = index - numberFinalProcessingNeighborsNeeded
                var endIdx = index + numberFinalProcessingNeighborsNeeded
                if startIdx < 0 { startIdx = 0 }
                if endIdx >= existingOutputFiles.count {
                    endIdx = existingOutputFiles.count - 1
                }
                for i in startIdx ... endIdx {
                    shouldProcess[i] = true
                }
            }
        }
        
        for (index, imageFilename) in self.imageSequence.filenames.enumerated() {
            let filename = self.imageSequence.filenames[index]
            let basename = removePath(fromString: filename)
            let outputFilename = "\(outputDirname)/\(basename)"
            if shouldProcess[index] {
                _methodList[index] = {
                    // this method is run async later                                           
                    Log.i("loading \(imageFilename)")
                    //let image = await self.imageSequence.getImage(withName: imageFilename)
                    if let result = try await self.processFrame(number: index,
                                                                outputFilename: outputFilename,
                                                                baseName: basename) {
                        await self.numberRunning.decrement()
                        return result
                    }
                    throw "could't load image for \(imageFilename)"
                }
            } else {
                Log.i("not processing existing file \(filename)")
            }
        }

        return MethodList<T>(list: _methodList, removeClosure: remainingImagesClosure)
    }

    func startupHook() async throws {
        // can be overridden
    }
    
    func finishedHook() {
        // can be overridden
    }
    
    func resultHook(with result: T) async { 
        // can be overridden
    }
    
    public func run() async throws {
        Log.d("run")
        let task = Task { try await startupHook() }
        try await task.value

        Log.d("done with startup hook")
        
        try mkdir(outputDirname)

        // each of these methods removes the airplanes from a particular frame
        Log.i("processing a total of \(await methodList.list.count) frames")
        
        try await withLimitedThrowingTaskGroup(of: T.self) { group in
            while(await methodList.list.count > 0) {
                Log.d("we have \(await methodList.list.count) more frames to process")
                Log.d("processing new frame")
                
                // sort the keys and take the smallest one first
                if let nextMethodKey = await methodList.nextKey,
                   let nextMethod = await methodList.list[nextMethodKey]
                {
                    await methodList.removeValue(forKey: nextMethodKey)
                    await self.numberRunning.increment()
                    try await group.addTask() {
                        let ret = try await nextMethod()
                        await self.resultHook(with: ret)
                        return ret
                    }
                } else {
                    Log.e("FUCK") 
                    fatalError("FUCK")
                }
            }
            try await group.waitForAll()
            
            Log.d("finished hook")
            self.finishedHook()
        }
        Log.d("DONE")
        
        Log.d("DONE WAITING")
        let rename_me = self.dispatchGroup.dispatchGroup
        while (shouldRun && rename_me.wait(timeout: DispatchTime.now().advanced(by: .seconds(3))) == .timedOut) {
            Task {
                let count = await self.dispatchGroup.count
                if count < 8 {      // XXX hardcoded constant
                    for (name, _) in await self.dispatchGroup.running {
                        Log.d("waiting on \(name)")
                    }
                }
            } 
        }

        Log.i("done")
    }
}

// removes path from filename
func removePath(fromString string: String) -> String {
    let components = string.components(separatedBy: "/")
    let ret = components[components.count-1]
    return ret
}


fileprivate let fileManager = FileManager.default
