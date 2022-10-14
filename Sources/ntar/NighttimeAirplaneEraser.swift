import Foundation
import CoreGraphics
import Cocoa

@available(macOS 10.15, *) 
class NighttimeAirplaneEraser {
    
    let image_sequence_dirname: String
    let output_dirname: String

    // the max number of frames to process at one time
    let max_concurrent_renders = 40 

    let dispatchQueue = DispatchQueue(label: "ntar",
                                      qos: .unspecified,
                                      attributes: [.concurrent],
                                      autoreleaseFrequency: .inherit,
                                      target: nil)

    
    init(imageSequenceDirname: String) {
        image_sequence_dirname = imageSequenceDirname
        output_dirname = "\(image_sequence_dirname)-no-planes"
    }
    
    func run() {
        var image_files = list_image_files(atPath: image_sequence_dirname)
        image_files.sort { (lhs: String, rhs: String) -> Bool in
            let lh = remove_suffix(fromString: lhs)
            let rh = remove_suffix(fromString: rhs)
            return lh < rh
        }

        let image_sequence = ImageSequence(filenames: image_files)
        //    Log.d("image_files \(image_files)")
        
        do {
            try FileManager.default.createDirectory(atPath: output_dirname, withIntermediateDirectories: false, attributes: nil)
        } catch let error as NSError {
            fatalError("Unable to create directory \(error.debugDescription)")
        }
        
        // each of these methods removes the airplanes from a particular frame
        var methods: [Int : () async -> Void] = [:]
        
        let dispatchGroup = DispatchGroup()
        let number_running = NumberRunning()
    
        for (index, image_filename) in image_sequence.filenames.enumerated() {
            methods[index] = {
                dispatchGroup.enter() 
                do {
                    // load images outside the main thread
                    if let image = await image_sequence.getImage(withName: image_filename) {
                        var otherFrames: [CGImage] = []
                        
                        if index > 0,
                           let image = await image_sequence.getImage(withName: image_sequence.filenames[index-1])
                        {
                            otherFrames.append(image)
                        }
                        if index < image_sequence.filenames.count - 1,
                           let image = await image_sequence.getImage(withName: image_sequence.filenames[index+1])
                        {
                            otherFrames.append(image)
                        }
                        
                        // the other frames that we use to detect outliers and repaint from
                        if let new_image = removeAirplanes(fromImage: image,
                                                           otherFrames: otherFrames,
                                                           minNeighbors: 150,
                                                           withPadding: 0)
                        {
                            // relinquish images here
                            Log.d("new_image \(new_image)")
                            let filename_base = remove_suffix(fromString: image_sequence.filenames[index])
                            let filename = "\(self.output_dirname)/\(filename_base).tif"
                            do {
                                try save(image: new_image, toFile: filename)
                            } catch {
                                Log.e("doh! \(error)")
                            }
                        }
                    } else {
                        Log.d("FUCK")
                        fatalError("doh")
                    }
                } catch {
                    Log.e("doh! \(error)")
                }
                await number_running.decrement()
                dispatchGroup.leave()
            }
        }
        
        Log.d("we have \(methods.count) methods")
        let runner: () async -> Void = {
            while(methods.count > 0) {
                let current_running = await number_running.currentValue()
                if(current_running < self.max_concurrent_renders) {
                    Log.d("\(current_running) frames currently processing")
                    Log.d("we have \(methods.count) more frames to process")
                    Log.d("enquing new method")
                    
                    if let next_method_key = methods.keys.randomElement(),
                       let next_method = methods[next_method_key]
                    {
                        methods.removeValue(forKey: next_method_key)
                        await number_running.increment()
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
                    _ = dispatchGroup.wait(timeout: DispatchTime.now().advanced(by: .seconds(1)))
                }
            }
        }
        dispatchGroup.enter()
        Task {
            Log.d("running")
            await runner()
            dispatchGroup.leave()
        }
        dispatchGroup.wait()
        Log.d("done")
    }
}

