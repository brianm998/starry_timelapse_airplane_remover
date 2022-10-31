import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

let supported_image_file_types = [".tif", ".tiff"] // XXX move this out
    
// support lazy loading of images from the sequence using reference counting
@available(macOS 10.15, *)
actor ImageSequence {

    init(dirname: String, givenFilenames given_filenames: [String]? = nil) {
        var image_files: [String] = []

        if let given_filenames = given_filenames {
            given_filenames.forEach { filename in
                image_files.append("\(dirname)/\(filename)")
            }
        } else {
            do {
                let contents = try FileManager.default.contentsOfDirectory(atPath: dirname)
                contents.forEach { file in
                    supported_image_file_types.forEach { type in
                        if file.hasSuffix(type) {
                            image_files.append("\(dirname)/\(file)")
                        } 
                    }
                }
            } catch {
                Log.d("OH FUCK \(error)")
            }
    
            image_files.sort { (lhs: String, rhs: String) -> Bool in
                let lh = remove_path_and_suffix(fromString: lhs)
                let rh = remove_path_and_suffix(fromString: rhs)
                return lh < rh
            }
        }
        self.filenames = image_files
    }
    
    let filenames: [String]

    private var images: [String: WeakRef<PixelatedImage>] = [:]

    func getImage(withName filename: String) -> PixelatedImage? {
        if let image = images[filename]?.value {
            return image
        }
        do {
            Log.d("loading \(filename)")
            if let pixelatedImage = try PixelatedImage(fromFile: filename) {
                images[filename] = WeakRef(value: pixelatedImage)
                return pixelatedImage
            }
        } catch {
            Log.e(error)
        }
        Log.w("could not getImage(withName: \(filename)), no image found")
        return nil
    }
}

class WeakRef<T> where T: AnyObject {

    private(set) weak var value: T?

    init(value: T?) {
        self.value = value
    }
}

// removes path and suffix from filename
func remove_path_and_suffix(fromString string: String) -> String {
    let imageURL = NSURL(fileURLWithPath: string, isDirectory: false) as URL
    let full_path = imageURL.deletingPathExtension().absoluteString
    let components = full_path.components(separatedBy: "/")
    return components[components.count-1]
}
