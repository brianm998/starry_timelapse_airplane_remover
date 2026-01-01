import Foundation
import CoreGraphics
import logging
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

public actor ImageLoader {
    let filename: String
    
    init(fromFile filename: String) {
        self.filename = filename
    }

    public func image() async throws -> PixelatedImage {
        if let image = await imageCache.loadImage(filename: filename) {
            return image
        }
        throw "could not load image from \(filename)"
    }
}

public struct ImageInfo: Sendable {
    public let imageWidth: Int
    public let imageHeight: Int
    public let imageBytesPerPixel: Int // XXX bad name
    public let imageBitsPerComponent: Int
    public let componentsPerPixel: Int
    public let fileExtension: String
}

// allows loading and caching of frames of an image sequence
public actor ImageSequence {

    public func getImageInfo() async throws -> ImageInfo {
        if self.filenames.count == 0 { throw "no images found"}
        let filename = self.filenames[0]
        let fileExtension = filename.components(separatedBy: ".").last ?? ".tiff" // XXX
        let testImage = try await self.getImage(withName: filename).image()
        return ImageInfo(imageWidth: testImage.width,
                         imageHeight: testImage.height,
                         imageBytesPerPixel: testImage.bytesPerPixel,
                         imageBitsPerComponent: testImage.bitsPerComponent,
                         componentsPerPixel: testImage.componentsPerPixel,
                         fileExtension: fileExtension)
    }
    
    public init(dirname: String,
                supportedImageFileTypes: [String],
                maxImages: Int? = nil) throws
    {
        self.maxImages = maxImages
        var imageFiles: [String] = []
        if !FileManager.default.fileExists(atPath: dirname) {
            throw "\(dirname) does not exist"
        }
      
        // runs on the main thread and blocks when the SAN is starting
        let contents = try FileManager.default.contentsOfDirectory(atPath: dirname)
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

    // use file access monitor
    public func getImage(withName filename: String) -> ImageLoader {
        self.getImageInt(withName: filename)
    }
    
    private func getImageInt(withName filename: String) -> ImageLoader {
        if Thread.isMainThread { Log.w("ON MAIN THREAD") }
        //Log.d("getImage(withName: \(filename))")
        if let image = images[filename] {
            //Log.d("image was cached")
            return image
        }
        Log.d("loading \(filename)")
        let pixelatedImage = ImageLoader(fromFile: filename) 
        images[filename] = pixelatedImage

        loadedFilenames.insert(filename, at: 0)

        var _maxImages = 0

        if let maxImages = maxImages {
            _maxImages = maxImages
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

