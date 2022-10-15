import Foundation
import CoreGraphics
import Cocoa



@available(macOS 10.15, *) 
class ImageSequenceProcessor {
    
    let image_sequence_dirname: String
    let output_dirname: String

    // the max number of frames to process at one time
    let max_concurrent_renders: UInt

    // the following properties get included into the output videoname
    
    // actors
    let method_list = MethodList()
    let number_running = NumberRunning()
    var image_sequence: ImageSequence?

    let supported_image_file_types = [".tif", ".tiff"]
    
    // concurrent dispatch queue so we can process frames in parallel
    let dispatchQueue = DispatchQueue(label: "image_sequence_processor",
                                      qos: .unspecified,
                                      attributes: [.concurrent],
                                      autoreleaseFrequency: .inherit,
                                      target: nil)
    
    let dispatchGroup = DispatchGroup()
    
    init(imageSequenceDirname: String,
         outputDirname output_dirname: String,
         maxConcurrent max_concurrent: UInt = 5)
    {
        self.max_concurrent_renders = max_concurrent
        self.image_sequence_dirname = imageSequenceDirname
        self.output_dirname = output_dirname
    }
    
    func list_image_files(atPath path: String) -> [String] {
        var image_files: [String] = []
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            contents.forEach { file in
                supported_image_file_types.forEach { type in
                    if file.hasSuffix(type) {
                        image_files.append("\(path)/\(file)")
                    } 
                }
            }
        } catch {
            Log.d("OH FUCK \(error)")
        }
        return image_files
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
                      filename: String,
                      base_name: String) async -> Data?
    {
        Log.e("should be overrideen")

        return nil
    }

    func assembleMethodList() async {
        if let image_sequence = image_sequence {
            for (index, image_filename) in image_sequence.filenames.enumerated() {
                let filename = image_sequence.filenames[index]
                let basename = remove_path(fromString: filename)
                let output_filename = "\(output_dirname)/\(basename)"
                if FileManager.default.fileExists(atPath: output_filename) {
                    Log.i("skipping already existing file \(filename)")
                } else {
                    await method_list.add(atIndex: index, method: {
                        self.dispatchGroup.enter() 
                        if let data = await self.processFrame(number: index,
                                                              filename: image_filename,
                                                              base_name: basename)
                        {
                            // write each frame out as a tiff file after processing it
                            if let image = await image_sequence.getImage(withName: image_filename) {
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

    private func assembleImageSequence() {
        var image_files = list_image_files(atPath: image_sequence_dirname)
        // make sure the image list is in the same order as the video
        image_files.sort { (lhs: String, rhs: String) -> Bool in
            let lh = remove_path_and_suffix(fromString: lhs)
            let rh = remove_path_and_suffix(fromString: rhs)
            return lh < rh
        }

        image_sequence = ImageSequence(filenames: image_files)
    }

    func startup_hook() {
        // can be overridden
    }
    
    func run() {
        assembleImageSequence()
        mkdir(output_dirname)
        startup_hook()
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

// removes path and suffix from filename
func remove_path_and_suffix(fromString string: String) -> String {
    let imageURL = NSURL(fileURLWithPath: string, isDirectory: false) as URL
    let full_path = imageURL.deletingPathExtension().absoluteString
    let components = full_path.components(separatedBy: "/")
    return components[components.count-1]
}

