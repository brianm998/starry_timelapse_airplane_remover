import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

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
public actor ImageSequence {

    init(dirname: String,
         supportedImageFileTypes: [String],
         maxImages: Int? = nil) throws
    {
        self.maxImages = maxImages
        var imageFiles: [String] = []
        if !fileManager.fileExists(atPath: dirname) {
            throw "\(dirname) does not exist"
        }
        let contents = try fileManager.contentsOfDirectory(atPath: dirname)
        contents.forEach { file in
            supportedImageFileTypes.forEach { type in
                if file.hasSuffix(type) {
                    imageFiles.append("\(dirname)/\(file)")
                } 
            }
        }
        
        imageFiles.sort { (lhs: String, rhs: String) -> Bool in
            let lh = removePathAndSuffix(fromString: lhs)
            let rh = removePathAndSuffix(fromString: rhs)
            return lh < rh
        }

        self.filenames = imageFiles
    }

    static var imageWidth: Int = 0
    static var imageHeight: Int = 0
    
    public let filenames: [String]

    private var images: [String: ImageLoader] = [:]

    func removeValue(forKey key: String) {
        self.images.removeValue(forKey: key)
    }
    
    // how many images are in ram right now
    var numberOfResidentImages: Int {
        return images.count
    }

    private var loadedFilenames: [String] = []

    private var maxImages: Int? // XXX set this low for gui, eating more ram than necessary
    
    func getImage(withName filename: String) -> ImageLoader {
        Log.d("getImage(withName: \(filename))")
        if let image = images[filename] {
            Log.d("image was cached")
            return image
        }
        Log.d("loading \(filename)")
        let pixelatedImage = ImageLoader(fromFile: filename) 
        images[filename] = pixelatedImage

        loadedFilenames.insert(filename, at: 0)

        var _maxImages = 0

        if let maxImages = maxImages {
            _maxImages = maxImages
        } else if ImageSequence.imageWidth != 0,
                 ImageSequence.imageHeight != 0
        {
            // calculate the max number of images to keep in ram at once
            // use the amount of physical ram / size of images
            let memorySizeBytes = ProcessInfo.processInfo.physicalMemory

            // this is a rough guess, 16 bits per pixel, 4 components per pixel
            let bytesPerImage = ImageSequence.imageWidth*ImageSequence.imageHeight*8

            // this is a rule of thumb, not exact
            _maxImages = Int(memorySizeBytes / UInt64(bytesPerImage)) / 5 // XXX hardcoded constant

            let neverGoOverMax = 100 // XXX hardcoded max
            if _maxImages > neverGoOverMax { _maxImages = neverGoOverMax }
            
            maxImages = _maxImages
            Log.i("calculated maxImages \(_maxImages)")
        } else {
            _maxImages = 10    // initial default
        }
        
        while loadedFilenames.count > _maxImages { 
            self.removeValue(forKey: loadedFilenames.removeLast())
        }
        
        Log.d("loaded \(filename)")
        return pixelatedImage
    }
}

// removes path and suffix from filename
func removePathAndSuffix(fromString string: String) -> String {
    let imageURL = NSURL(fileURLWithPath: string, isDirectory: false) as URL
    let full_path = imageURL.deletingPathExtension().absoluteString
    let components = full_path.components(separatedBy: "/")
    return components[components.count-1]
}

fileprivate let fileManager = FileManager.default
