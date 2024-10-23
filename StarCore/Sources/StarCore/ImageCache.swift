import Foundation
import CoreGraphics
import logging
import Cocoa
import Semaphore

public let imageCache = ImageCache()

/*

 Keep a memory cache of NSImages with with NSCache, keyed by filename.
 
 Can't be an actor because NSImage isn't sendable.

 Uses a semaphore instead.
 
 */
public class ImageCache: @unchecked Sendable {
    let cache = NSCache<NSString, NSImage>()
    let semaphore = AsyncSemaphore(value: 1)

    public func loadImage(filename: String) async throws -> NSImage? {
        await semaphore.wait()
        var ret: NSImage? = nil
        let key = NSString(string: filename)
        if let cachedImage = cache.object(forKey: key) {
            ret = cachedImage
            semaphore.signal()
            return ret
        } else {
            semaphore.signal()
            if let value = try await loadImageInt(filename: filename) {
                await semaphore.wait()
                cache.setObject(value, forKey: key)
                ret = value
                semaphore.signal()
            }
        }
        return ret
    }
}

fileprivate func loadImageInt(filename: String) async throws -> NSImage? {
    let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)
    let request = URLRequest(url: imageURL as URL)
    let (data, _) = try await URLSession.shared.data(for: request)
    return NSImage(data: data)
}
