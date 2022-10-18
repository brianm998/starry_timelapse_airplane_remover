import Foundation
import CoreGraphics
import Cocoa

@available(macOS 10.15, *) 
class ImageSequenceProcessor {

    // the name of the directory holding the image sequence being processed
    let image_sequence_dirname: String

    // the name of the directory to write processed images to
    let output_dirname: String

    // the max number of frames to process at one time
    let max_concurrent_renders: UInt

    // used for testing
    var process_only_this_index: Int?
    
    // the following properties get included into the output videoname
    
    // actors
    let method_list = MethodList()       // a list of methods to process each frame
    let number_running = NumberRunning() // how many methods are running right now
    var image_sequence: ImageSequence    // the sequence of images that we're processing

    // concurrent dispatch queue so we can process frames in parallel
    let dispatchQueue = DispatchQueue(label: "image_sequence_processor",
                                      qos: .unspecified,
                                      attributes: [.concurrent],
                                      autoreleaseFrequency: .inherit,
                                      target: nil)
    
    let dispatchGroup = DispatchGroup()
    
    init(imageSequenceDirname image_sequence_dirname: String,
         outputDirname output_dirname: String,
         maxConcurrent max_concurrent: UInt = 5,
         givenFilenames given_filenames: [String]? = nil)
    {
        self.max_concurrent_renders = max_concurrent
        self.image_sequence_dirname = image_sequence_dirname
        self.output_dirname = output_dirname
        Log.e("given_filenames \(given_filenames)")
        self.image_sequence = ImageSequence(dirname: image_sequence_dirname,
                                            givenFilenames: given_filenames)
    }
    
    func mkdir(_ path: String) {
        if !FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.createDirectory(atPath: path,
                                                        withIntermediateDirectories: false,
                                                        attributes: nil)
            } catch let error as NSError {
                fatalError("Unable to create directory \(error.debugDescription)")
            }
        }
    }

    func processFrame(number index: Int,
                      image: PixelatedImage,
                      base_name: String) async -> Data?
    {
        Log.e("should be overrideen")

        return nil
    }

    func assembleMethodList() async {
        for (index, image_filename) in image_sequence.filenames.enumerated() {
            var skip = false
            if let process_only_this_index = process_only_this_index,
               process_only_this_index != index
            {
                Log.w("skipping index \(index)")
                skip = true
            }
            // XXX add ability to skip all but a single index (#1) for the tester

            if !skip {
                let filename = image_sequence.filenames[index]
                let basename = remove_path(fromString: filename)
                let output_filename = "\(output_dirname)/\(basename)"
                if FileManager.default.fileExists(atPath: output_filename) {
                    Log.i("skipping already existing file \(filename)")
                } else {
                    await method_list.add(atIndex: index, method: {
                        self.dispatchGroup.enter() 
    
                        if let image = await self.image_sequence.getImage(withName: image_filename),
                           let data = await self.processFrame(number: index, // XXX 
                                                              image: image,
                                                              base_name: basename)
                        {
                            // write each frame out as a tiff file after processing it
                            if let image = await self.image_sequence.getImage(withName: image_filename) {
                                image.writeTIFFEncoding(ofData: data, toFilename: output_filename)
                            } else {
                                fatalError("FUCK")
                            }
                        } else {
                            Log.e("got no data for \(filename)")
                        }
                        await self.number_running.decrement()
                        self.dispatchGroup.leave()
                    })
                }
            }
        }
    }

    func startup_hook() {
        // can be overridden
    }
    
    func finished_hook() {
        // can be overridden
    }
    
    func run() {
        startup_hook()
        mkdir(output_dirname)
        // enter the dispatch group so we can wait for it at the end 
        self.dispatchGroup.enter()
        
        Task {
            // each of these methods removes the airplanes from a particular frame
            await assembleMethodList()
            Log.d("we have \(await method_list.list.count) total frames")
            
            Log.d("running")
            // atually run it
            
            while(await method_list.list.count > 0) {
                let current_running = await self.number_running.currentValue()
                if(current_running < self.max_concurrent_renders) {
                    Log.d("\(current_running) frames currently processing")
                    Log.d("we have \(await method_list.list.count) more frames to process")
                    Log.d("processing new frame")
                    
                    // sort the keys and take the smallest one first
                    if let next_method_key = await method_list.nextKey,
                       let next_method = await method_list.list[next_method_key]
                    {
                        await method_list.removeValue(forKey: next_method_key)
                        await self.number_running.increment()
                        self.dispatchQueue.async {
                            Task {
                                await next_method()
                            }
                        }
                    } else {
                        Log.e("FUCK")
                        fatalError("FUCK")
                    }
                } else {
                    _ = self.dispatchGroup.wait(timeout: DispatchTime.now().advanced(by: .seconds(1)))
                }
            }
            
            self.finished_hook()
            self.dispatchGroup.leave()
        }
        self.dispatchGroup.wait()
        Log.d("done")
    }
}

// removes path from filename
func remove_path(fromString string: String) -> String {
    let components = string.components(separatedBy: "/")
    let ret = components[components.count-1]
    return ret
}


