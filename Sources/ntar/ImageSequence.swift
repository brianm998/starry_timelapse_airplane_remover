import Foundation
import CoreGraphics
import Cocoa

// support lazy loading of images from the sequence using reference counting
class ImageSequence {

    init(filenames: [String]) {
        self.filenames = filenames
    }
    
    let filenames: [String]

    private var images: [String: CGImage] = [:]
    private var images_refcounts: [String: Int] = [:]
    
    func getImage(withName filename: String) -> CGImage? {
        if let image = images[filename],
           let refcount = images_refcounts[filename]
        {
            images_refcounts[filename] = refcount + 1
            return image
        }
        Log.d("Loading image from \(filename)")
        let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)
        do {
            let data = try Data(contentsOf: imageURL as URL)
            if let image = NSImage(data: data),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            {
                images_refcounts[filename] = 1
                return cgImage
            }
        } catch {
            Log.e("\(error)")
        }
        return nil
    }

    func releaseImage(withName filename: String) {
        if let refcount = images_refcounts[filename] {
            let new_value = refcount - 1
            images_refcounts[filename] = new_value
            if new_value <= 0 {
                images.removeValue(forKey: filename)
                images_refcounts.removeValue(forKey: filename)
            }
        }
    }
}

