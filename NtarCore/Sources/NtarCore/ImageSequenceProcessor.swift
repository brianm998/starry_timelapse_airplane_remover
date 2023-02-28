import Foundation
import CoreGraphics
import Cocoa

@available(macOS 10.15, *) 
public class ImageSequenceProcessor<T> {

    // the name of the directory holding the image sequence being processed
    public let image_sequence_dirname: String

    // the name of the directory to write processed images to
    public let output_dirname: String

    // the max number of frames to process at one time
    public let max_concurrent_renders: Int

    public let number_final_processing_neighbors_needed: Int
    
    // the following properties get included into the output videoname
    
    // actors
    var method_list = MethodList<T>()       // a list of methods to process each frame

    // how many methods are running right now
    let number_running: NumberRunning
    
    public var image_sequence: ImageSequence    // the sequence of images that we're processing

    // concurrent dispatch queue so we can process frames in parallel
    
    public let dispatchGroup = DispatchHandler()

    public var shouldRun = true
    
    var should_process: [Bool] = []       // indexed by frame number
    var existing_output_files: [Bool] = [] // indexed by frame number

    var remaining_images_closure: ((Int) -> Void)?

    // if this is true, outliers are detected, inter-frame processing is done
    // if false, frames are handed back without outliers detected
    let fully_process: Bool
    
    init(imageSequenceDirname image_sequence_dirname: String,
         outputDirname output_dirname: String,
         maxConcurrent max_concurrent: Int = 5,
         supported_image_file_types: [String],
         number_final_processing_neighbors_needed: Int,
         processExistingFiles: Bool,
         max_images: Int? = nil,
         fullyProcess: Bool = true) throws
    {
        self.number_running = NumberRunning()
        self.max_concurrent_renders = max_concurrent
        self.image_sequence_dirname = image_sequence_dirname
        self.output_dirname = output_dirname
        self.number_final_processing_neighbors_needed = number_final_processing_neighbors_needed
        self.image_sequence = try ImageSequence(dirname: image_sequence_dirname,
                                                supported_image_file_types: supported_image_file_types,
                                                max_images: max_images)
        self.should_process = [Bool](repeating: processExistingFiles, count: image_sequence.filenames.count)
        self.existing_output_files = [Bool](repeating: false, count: image_sequence.filenames.count)
        self.fully_process = fullyProcess
        self.method_list = try assembleMethodList()
    }

    func maxConcurrentRenders() async -> Int { max_concurrent_renders }
    
    func mkdir(_ path: String) throws {
        if !file_manager.fileExists(atPath: path) {
            try file_manager.createDirectory(atPath: path,
                                             withIntermediateDirectories: false,
                                             attributes: nil)
        }
    }

    func processFrame(number index: Int,
                      output_filename: String,
                      base_name: String) async throws -> T? 
    {
        Log.e("should be overridden")
        fatalError("should be overridden")
    }

    func assembleMethodList() throws -> MethodList<T> {
        /*
           read all existing output files 
           sort them into frame order
           remove ones within number_final_processing_neighbors_needed frames of holes
           make sure these re-runs doesn't bork on existing files later
           only process below based upon this info
        */
    
        var _method_list: [Int : () async throws -> T] = [:]
        
        for (index, image_filename) in image_sequence.filenames.enumerated() {
            let basename = remove_path(fromString: image_filename)
            let output_filename = "\(output_dirname)/\(basename)"
            if file_manager.fileExists(atPath: output_filename) {
                existing_output_files[index] = true
            }                                  
        }
        
        for (index, output_file_already_exists) in existing_output_files.enumerated() {
            if !output_file_already_exists {
                var start_idx = index - number_final_processing_neighbors_needed
                var end_idx = index + number_final_processing_neighbors_needed
                if start_idx < 0 { start_idx = 0 }
                if end_idx >= existing_output_files.count {
                    end_idx = existing_output_files.count - 1
                }
                for i in start_idx ... end_idx {
                    should_process[i] = true
                }
            }
        }
        
        for (index, image_filename) in self.image_sequence.filenames.enumerated() {
            let filename = self.image_sequence.filenames[index]
            let basename = remove_path(fromString: filename)
            let output_filename = "\(output_dirname)/\(basename)"
            if should_process[index] {
                _method_list[index] = {
                    // this method is run async later                                           
                    Log.i("loading \(image_filename)")
                    //let image = await self.image_sequence.getImage(withName: image_filename)
                    if let result = try await self.processFrame(number: index,
                                                                output_filename: output_filename,
                                                                base_name: basename) {
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
    
    public func run() throws {
        Log.d("run")
        let local_dispatch = DispatchGroup()
        local_dispatch.enter()
        Task {
            try await startup_hook()
            local_dispatch.leave()
        }
        local_dispatch.wait()

        Log.d("done with startup hook")
        
        try mkdir(output_dirname)

        // this dispatch group is only used for this task
        let local_dispatch_group = DispatchGroup()
        local_dispatch_group.enter()

        // XXX use a task group here instead, re-using the method list
        // XXX make MethodList class generic for the task group type?
        
        Task {
            // each of these methods removes the airplanes from a particular frame
            //try await assembleMethodList()
            Log.i("processing a total of \(await method_list.list.count) frames")
            
            try await withThrowingTaskGroup(of: T.self) { group in
                while(await method_list.list.count > 0) {
                    let current_running = await self.number_running.currentValue()
                    let current_max_concurrent = await self.maxConcurrentRenders()
                    //let fuck = await method_list.list.count


                    //Log.d("current_running \(current_running) max concurrent \(current_max_concurrent) method_list.count \(fuck)")
                    if current_running < current_max_concurrent {
                        Log.d("\(current_running) frames currently processing")
                        Log.d("we have \(await method_list.list.count) more frames to process")
                        Log.d("processing new frame")
                        
                        // sort the keys and take the smallest one first
                        if let next_method_key = await method_list.nextKey,
                           let next_method = await method_list.list[next_method_key]
                        {
                            await method_list.removeValue(forKey: next_method_key)
                            await self.number_running.increment()
                            //let name = "image sequence processor foobaz \(next_method_key)"
                            group.addTask(priority: .medium) {
                                return try await next_method()
                            }
                        } else {
                            Log.e("FUCK") 
                            fatalError("FUCK")
                        }
                    } else {
                        //Log.d("waiting for a processed frame")
                        if let processed_frame = try await group.next() {
                            Log.d("got processed_frame \(processed_frame)")
                            await self.result_hook(with: processed_frame)
                        } else {
                            //Log.d("did not get a processed frame")
                        }
                    }
                }
                while let processed_frame = try await group.next() {
                    Log.d("got processed_frame \(processed_frame)")
                    await self.result_hook(with: processed_frame)
                }
                
                Log.d("finished hook")
                self.finished_hook()
                local_dispatch_group.leave()
            }
        }
        Log.d("DONE")
        
        local_dispatch_group.wait()
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
