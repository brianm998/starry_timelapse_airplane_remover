import Foundation
import CoreGraphics
import Cocoa

// XXX exorcise this daemon 
let dispatchQueue = DispatchQueue(label: "image_sequence_processor",
                                  qos: .unspecified,
                                  attributes: [.concurrent],
                                  autoreleaseFrequency: .inherit,
                                  target: nil)


@available(macOS 10.15, *) 
class ImageSequenceProcessor<T> {

    // the name of the directory holding the image sequence being processed
    let image_sequence_dirname: String

    // the name of the directory to write processed images to
    let output_dirname: String

    // the max number of frames to process at one time
    let max_concurrent_renders: UInt

    // the following properties get included into the output videoname
    
    // actors
    let method_list = MethodList<T?>()       // a list of methods to process each frame
    let number_running = NumberRunning() // how many methods are running right now
    var image_sequence: ImageSequence    // the sequence of images that we're processing

    // concurrent dispatch queue so we can process frames in parallel
    
    let dispatchGroup = DispatchHandler()
    
    var should_process: [Bool] = []       // indexed by frame number
    var existing_output_files: [Bool] = [] // indexed by frame number
    
    init(imageSequenceDirname image_sequence_dirname: String,
         outputDirname output_dirname: String,
         maxConcurrent max_concurrent: UInt = 5,
         givenFilenames given_filenames: [String]? = nil)
    {
        self.max_concurrent_renders = max_concurrent
        self.image_sequence_dirname = image_sequence_dirname
        self.output_dirname = output_dirname
        self.image_sequence = ImageSequence(dirname: image_sequence_dirname,
                                            givenFilenames: given_filenames)
    }

    func maxConcurrentRenders() async -> UInt {
        return max_concurrent_renders
    }
    
    func mkdir(_ path: String) {
        if !file_manager.fileExists(atPath: path) {
            do {
                try file_manager.createDirectory(atPath: path,
                                                        withIntermediateDirectories: false,
                                                        attributes: nil)
            } catch let error as NSError {
                fatalError("Unable to create directory \(error.debugDescription)")
            }
        }
    }

    func processFrame(number index: Int,
                      image: PixelatedImage,
                      output_filename: String,
                      base_name: String) async -> T? 
    {
        Log.e("should be overridden")
        fatalError("should be overridden")
    }

    func assembleMethodList() async {
        /*
           read all existing output files 
           sort them into frame order
           remove ones within number_final_processing_neighbors_needed frames of holes
           make sure these re-runs done't bork on existing file later
           only process below based upon this info
        */

        should_process = [Bool](repeating: false, count: image_sequence.filenames.count)
        existing_output_files = [Bool](repeating: false, count: image_sequence.filenames.count)
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

        for (index, image_filename) in image_sequence.filenames.enumerated() {
            let filename = image_sequence.filenames[index]
            let basename = remove_path(fromString: filename)
            let output_filename = "\(output_dirname)/\(basename)"
            if should_process[index] {
                let name = "image sequence processor foobar \(index)"
                await self.dispatchGroup.enter(name) 
                await method_list.add(atIndex: index, method: {
                    // this method is run async later                                           
                    Log.i("loading \(image_filename)")
                    if let image = await self.image_sequence.getImage(withName: image_filename) {
                        if let result = await self.processFrame(number: index,
                                                                image: image,
                                                                output_filename: output_filename,
                                                                base_name: basename) {
                            await self.number_running.decrement()
                            await self.dispatchGroup.leave(name)
                            return result
                        }
                    } else {
                        Log.w("could't get image for \(image_filename)")
                    }
                    await self.number_running.decrement()
                    await self.dispatchGroup.leave(name)
                    return nil
                })
            } else {
                Log.i("not processing existing file \(filename)")
            }
        }
    }

    func method_list_hook() async {
        // can be overridden
    }
    
    func startup_hook() {
        // can be overridden
    }
    
    func finished_hook() {
        // can be overridden
    }
    
    func result_hook(with result: T) async { 
        // can be overridden
    }
    
    func run() {
        Log.d("run")
        startup_hook()

        mkdir(output_dirname)

        // this dispatch group is only used for this task
        let local_dispatch_group = DispatchGroup()
        local_dispatch_group.enter()

        // XXX use a task group here instead, re-using the method list
        // XXX make MethodList class generic for the task group type?
        
        Task {
            // each of these methods removes the airplanes from a particular frame
            await assembleMethodList()
            Log.i("processing a total of \(await method_list.list.count) frames")
            
            await method_list_hook()
            
            Log.d("running")
            // atually run it
            
            while(await method_list.list.count > 0) {
                let current_running = await self.number_running.currentValue()
                let current_max_concurrent = await self.maxConcurrentRenders()
                let fuck = await method_list.list.count
                Log.d("current_running \(current_running) max concurrent \(current_max_concurrent) method_list.count \(fuck)")
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
                        let name = "image sequence processor foobaz \(next_method_key)"
                        await self.dispatchGroup.enter(name)
                        dispatchQueue.async {
                            Task {
                                if let result = await next_method() {
                                    await self.result_hook(with: result)
                                }
                                await self.dispatchGroup.leave(name)
                            }
                        }
                    } else {
                        Log.e("FUCK") 
                        fatalError("FUCK")
                    }
                } else {
                    sleep(1)
                    //_ = self.dispatchGroup.wait(timeout: DispatchTime.now().advanced(by: .seconds(1)))
                }
            }
            Log.d("finished hook")
            self.finished_hook()
            local_dispatch_group.leave()
        }

        local_dispatch_group.wait()
        let rename_me = self.dispatchGroup.dispatch_group
        while (rename_me.wait(timeout: DispatchTime.now().advanced(by: .seconds(3))) == .timedOut) {
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


