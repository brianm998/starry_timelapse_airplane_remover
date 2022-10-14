import Foundation
import CoreGraphics
import Cocoa

// support lazy loading of images from the sequence using reference counting
@available(macOS 10.15, *)
actor ImageSequence {

    init(filenames: [String]) {
        self.filenames = filenames
    }
    
    let filenames: [String]

    private var images: [String: WeakRef<CGImage>] = [:]
    
    func getImage(withName filename: String) -> CGImage? {
        if let image = images[filename]?.value {
            return image
        }
        Log.d("Loading image from \(filename)")
        let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)
        do {
            let data = try Data(contentsOf: imageURL as URL)
            if let image = NSImage(data: data),
               let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            {
                images[filename] = WeakRef(value: cgImage)
                return cgImage
            }
        } catch {
            Log.e("\(error)")
        }
        return nil
    }
}

class WeakRef<T> where T: AnyObject {

    private(set) weak var value: T?

    init(value: T?) {
        self.value = value
    }
}
