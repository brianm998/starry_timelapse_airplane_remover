import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

@available(macOS 10.15, *)
public actor ImageLoader {
    let filename: String
    private var _image: PixelatedImage?
    
    init(fromFile filename: String) {
        self.filename = filename
    }

    func image() async throws -> PixelatedImage {
        if let image = _image { return image }
        if let image = try await PixelatedImage(fromFile: filename) {
            _image = image
            return image
        }
        throw "could not load image from \(filename)"
    }
}

// allows loading and caching of frames of an image sequence
@available(macOS 10.15, *)
public actor ImageSequence {

    init(dirname: String,
         supported_image_file_types: [String],
         max_images: Int? = nil) throws
    {
        self.max_images = max_images
        var image_files: [String] = []
        let contents = try file_manager.contentsOfDirectory(atPath: dirname)
        contents.forEach { file in
            supported_image_file_types.forEach { type in
                if file.hasSuffix(type) {
                    image_files.append("\(dirname)/\(file)")
                } 
            }
        }
        
        image_files.sort { (lhs: String, rhs: String) -> Bool in
            let lh = remove_path_and_suffix(fromString: lhs)
            let rh = remove_path_and_suffix(fromString: rhs)
            return lh < rh
        }

        self.filenames = image_files
    }

    static var image_width: Int = 0
    static var image_height: Int = 0
    
    public let filenames: [String]

    private var images: [String: ImageLoader] = [:]

    func removeValue(forKey key: String) {
        self.images.removeValue(forKey: key)
    }
    
    // how many images are in ram right now
    var numberOfResidentImages: Int {
        return images.count
    }

    private var loaded_filenames: [String] = []

    private var max_images: Int? // XXX set this low for gui, eating more ram than necessary
    
    func getImage(withName filename: String) -> ImageLoader {
        Log.d("getImage(withName: \(filename))")
        if let image = images[filename] {
            Log.d("image was cached")
            return image
        }
        Log.d("loading \(filename)")
        let pixelatedImage = ImageLoader(fromFile: filename) 
        images[filename] = pixelatedImage

        loaded_filenames.insert(filename, at: 0)

        var _max_images = 0

        if let max_images = max_images {
            _max_images = max_images
        } else if ImageSequence.image_width != 0,
                  ImageSequence.image_height != 0
        {
            // calculate the max number of images to keep in ram at once
            // use the amount of physical ram / size of images
            let memory_size_bytes = ProcessInfo.processInfo.physicalMemory

            // this is a rough guess, 16 bits per pixel, 4 components per pixel
            let bytes_per_image = ImageSequence.image_width*ImageSequence.image_height*8

            // this is a rule of thumb, not exact
            _max_images = Int(memory_size_bytes / UInt64(bytes_per_image)) / 5 // XXX hardcoded constant
            if _max_images > 200 { _max_images = 200 } // XXX hardcoded max
            
            max_images = _max_images
            Log.i("calculated max_images \(_max_images)")
        } else {
            _max_images = 10    // initial default
        }
        
        while loaded_filenames.count > _max_images { 
            self.removeValue(forKey: loaded_filenames.removeLast())
        }
        
        Log.d("loaded \(filename)")
        return pixelatedImage
    }
}

// removes path and suffix from filename
func remove_path_and_suffix(fromString string: String) -> String {
    let imageURL = NSURL(fileURLWithPath: string, isDirectory: false) as URL
    let full_path = imageURL.deletingPathExtension().absoluteString
    let components = full_path.components(separatedBy: "/")
    return components[components.count-1]
}

fileprivate let file_manager = FileManager.default
