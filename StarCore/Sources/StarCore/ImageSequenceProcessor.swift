import Foundation
import CoreGraphics
import Cocoa

public func mkdir(_ path: String) throws {
    if !file_manager.fileExists(atPath: path) {
        try file_manager.createDirectory(atPath: path,
                                         withIntermediateDirectories: false,
                                         attributes: nil)
    }
}

public class ImageSequenceProcessor<T> {

    // the name of the directory holding the image sequence being processed
    public let imageSequenceDirname: String

    // the name of the directory to write processed images to
    public let output_dirname: String

    // the max number of frames to process at one time
    public let max_concurrent_renders: Int

    public let numberFinalProcessingNeighborsNeeded: Int
    
    // the following properties get included into the output videoname
    
    // actors
    var method_list = MethodList<T>()       // a list of methods to process each frame

    // how many methods are running right now
    let number_running: NumberRunning
    
    public var imageSequence: ImageSequence    // the sequence of images that we're processing

    // concurrent dispatch queue so we can process frames in parallel
    
    public let dispatchGroup = DispatchHandler()

    public var shouldRun = true
    
    var should_process: [Bool] = []       // indexed by frame number
    var existing_output_files: [Bool] = [] // indexed by frame number

    var remaining_images_closure: ((Int) -> Void)?

    // if this is true, outliers are detected, inter-frame processing is done
    // if false, frames are handed back without outliers detected
    let fullyProcess: Bool
    
    init(imageSequenceDirname: String,
         outputDirname output_dirname: String,
         maxConcurrent max_concurrent: Int = 5,
         supportedImageFileTypes: [String],
         numberFinalProcessingNeighborsNeeded: Int,
         processExistingFiles: Bool,
         max_images: Int? = nil,
         fullyProcess: Bool = true) throws
    {
        self.number_running = NumberRunning()
        self.max_concurrent_renders = max_concurrent
        self.imageSequenceDirname = imageSequenceDirname
        self.output_dirname = output_dirname
        self.numberFinalProcessingNeighborsNeeded = numberFinalProcessingNeighborsNeeded
        self.imageSequence = try ImageSequence(dirname: imageSequenceDirname,
                                                supportedImageFileTypes: supportedImageFileTypes,
                                                max_images: max_images)
        self.should_process = [Bool](repeating: processExistingFiles, count: imageSequence.filenames.count)
        self.existing_output_files = [Bool](repeating: false, count: imageSequence.filenames.count)
        self.fullyProcess = fullyProcess
        self.method_list = try assembleMethodList()
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
    
        var _method_list: [Int : () async throws -> T] = [:]
        
        for (index, image_filename) in imageSequence.filenames.enumerated() {
            let basename = remove_path(fromString: image_filename)
            let outputFilename = "\(output_dirname)/\(basename)"
            if file_manager.fileExists(atPath: outputFilename) {
                existing_output_files[index] = true
            }                                  
        }
        
        for (index, output_file_already_exists) in existing_output_files.enumerated() {
            if !output_file_already_exists {
                var start_idx = index - numberFinalProcessingNeighborsNeeded
                var end_idx = index + numberFinalProcessingNeighborsNeeded
                if start_idx < 0 { start_idx = 0 }
                if end_idx >= existing_output_files.count {
                    end_idx = existing_output_files.count - 1
                }
                for i in start_idx ... end_idx {
                    should_process[i] = true
                }
            }
        }
        
        for (index, image_filename) in self.imageSequence.filenames.enumerated() {
            let filename = self.imageSequence.filenames[index]
            let basename = remove_path(fromString: filename)
            let outputFilename = "\(output_dirname)/\(basename)"
            if should_process[index] {
                _method_list[index] = {
                    // this method is run async later                                           
                    Log.i("loading \(image_filename)")
                    //let image = await self.imageSequence.getImage(withName: image_filename)
                    if let result = try await self.processFrame(number: index,
                                                                outputFilename: outputFilename,
                                                                baseName: basename) {
                        await self.number_running.decrement()
                        return result
                    }
                    throw "could't load image for \(image_filename)"
                }
            } else {
                Log.i("not processing existing file \(filename)")
            }
        }

        return MethodList<T>(list: _method_list, removeClosure: remaining_images_closure)
    }

    func startup_hook() async throws {
        // can be overridden
    }
    
    func finished_hook() {
        // can be overridden
    }
    
    func result_hook(with result: T) async { 
        // can be overridden
    }
    
    public func run() async throws {
        Log.d("run")
        let task = Task { try await startup_hook() }
        try await task.value

        Log.d("done with startup hook")
        
        try mkdir(output_dirname)

        // each of these methods removes the airplanes from a particular frame
        Log.i("processing a total of \(await method_list.list.count) frames")
        
        try await withLimitedThrowingTaskGroup(of: T.self) { group in
            while(await method_list.list.count > 0) {
                Log.d("we have \(await method_list.list.count) more frames to process")
                Log.d("processing new frame")
                
                // sort the keys and take the smallest one first
                if let next_method_key = await method_list.nextKey,
                   let next_method = await method_list.list[next_method_key]
                {
                    await method_list.removeValue(forKey: next_method_key)
                    await self.number_running.increment()
                    try await group.addTask() {
                        let ret = try await next_method()
                        await self.result_hook(with: ret)
                        return ret
                    }
                } else {
                    Log.e("FUCK") 
                    fatalError("FUCK")
                }
            }
            try await group.waitForAll()
            
            Log.d("finished hook")
            self.finished_hook()
        }
        Log.d("DONE")
        
        Log.d("DONE WAITING")
        let rename_me = self.dispatchGroup.dispatch_group
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
func remove_path(fromString string: String) -> String {
    let components = string.components(separatedBy: "/")
    let ret = components[components.count-1]
    return ret
}


fileprivate let file_manager = FileManager.default
