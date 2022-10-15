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
    
    // concurrent dispatch queue so we can process frames in parallel
    let dispatchQueue = DispatchQueue(label: "image_sequence_processor",
                                      qos: .unspecified,
                                      attributes: [.concurrent],
                                      autoreleaseFrequency: .inherit,
                                      target: nil)
    
    let dispatchGroup = DispatchGroup()
    
    init(imageSequenceDirname: String,
         outputDirnameSuffix output_suffix: String = "-processed",
         maxConcurrent max_concurrent: UInt = 5)
    {
        self.max_concurrent_renders = max_concurrent
        image_sequence_dirname = imageSequenceDirname
        output_dirname = "\(image_sequence_dirname)-\(output_suffix)"
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
                      dirname: String,
                      filename image_filename: String) async
    {
        Log.e("should be overrideen")
    }

    func assembleMethodList() async {
        if let image_sequence = image_sequence {
            for (index, image_filename) in image_sequence.filenames.enumerated() {
                let filename = image_sequence.filenames[index]
                //let test_paint_filename = "\(self.test_paint_output_dirname)/\(filename).tif"
                
                if FileManager.default.fileExists(atPath: "\(self.output_dirname)/\(filename)") {
                    Log.i("skipping already existing file \(filename)")
                } else {
                    await method_list.add(atIndex: index, method: {
                        self.dispatchGroup.enter() 
                        await self.processFrame(number: index,
                                                dirname: self.output_dirname,
                                                filename: filename)
                        await self.number_running.decrement()
                        self.dispatchGroup.leave()
                    })
                }
            }
        }
    }

    private func assembleImageSequence() {
        var image_files = list_image_files___RENAME_XXX(atPath: image_sequence_dirname)
        // make sure the image list is in the same order as the video
        image_files.sort { (lhs: String, rhs: String) -> Bool in
            let lh = remove_suffix_XXX_RENAME(fromString: lhs)
            let rh = remove_suffix_XXX_RENAME(fromString: rhs)
            return lh < rh
        }

        image_sequence = ImageSequence(filenames: image_files)
    }

    func startup_hook() {
        //if test_paint { mkdir(test_paint_output_dirname) }
    }
    
    func run() {
        assembleImageSequence()
        if let image_sequence = image_sequence {
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

                self.dispatchGroup.leave()
            }
            self.dispatchGroup.wait()
            Log.d("done")
        }
    }
}


// removes suffix and path
func remove_suffix_XXX_RENAME(fromString string: String) -> String {
    let imageURL = NSURL(fileURLWithPath: string, isDirectory: false) as URL
    let full_path = imageURL.deletingPathExtension().absoluteString
    let components = full_path.components(separatedBy: "/")
    return components[components.count-1]
}

func list_image_files___RENAME_XXX(atPath path: String) -> [String] {
    var image_files: [String] = []
    
    do {
        let contents = try FileManager.default.contentsOfDirectory(atPath: path)
        contents.forEach { file in
            if file.hasSuffix(".tif") || file.hasSuffix(".tiff") {
                image_files.append("\(path)/\(file)")
                Log.d("going to read \(file)")
            }
        }
    } catch {
        Log.d("OH FUCK \(error)")
    }
    return image_files
}

