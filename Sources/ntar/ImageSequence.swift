import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

// support lazy loading of images from the sequence using reference counting
@available(macOS 10.15, *)
actor ImageSequence {

    init(dirname: String, givenFilenames given_filenames: [String]? = nil) throws {
        var image_files: [String] = []

        if let given_filenames = given_filenames {
            given_filenames.forEach { filename in
                image_files.append("\(dirname)/\(filename)")
            }
        } else {
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
        }
        self.filenames = image_files
    }
    
    let filenames: [String]

    private var images: [String: PixelatedImage] = [:]

    func removeValue(forKey key: String) {
        self.images.removeValue(forKey: key)
    }
    
    // how many images are in ram right now
    var numberOfResidentImages: Int {
        return images.count
    }
    
    func getImage(withName filename: String) async throws -> PixelatedImage? {
        if let image = images[filename] {
            return image
        }
        Log.d("loading \(filename)")
        if let pixelatedImage = try await PixelatedImage(fromFile: filename) {
            // set a timer to purge it
            let _ = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: false) { timer in
                Task {
                    await self.removeValue(forKey: filename)
                    Log.d("purged \(filename)")
                }
            }
            images[filename] = pixelatedImage
            return pixelatedImage
        }
        Log.w("could not getImage(withName: \(filename)), no image found")
        return nil
    }
}

// removes path and suffix from filename
func remove_path_and_suffix(fromString string: String) -> String {
    let imageURL = NSURL(fileURLWithPath: string, isDirectory: false) as URL
    let full_path = imageURL.deletingPathExtension().absoluteString
    let components = full_path.components(separatedBy: "/")
    return components[components.count-1]
}
