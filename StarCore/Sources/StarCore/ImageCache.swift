import Foundation
import CoreGraphics
import logging
import Cocoa
import Semaphore

public let imageCache = ImageCache()

/*

 Keep a memory cache of NSImages with with NSCache, keyed by filename.
 
 Can't be an actor because NSImage isn't Sendable.

 Uses a semaphore instead.
 
 */
public class ImageCache: @unchecked Sendable {
    // this semaphore controls access to all mutable data in this class
    let semaphore = AsyncSemaphore(value: 1)

    // images indexed by filename
    let cache = NSCache<NSString, NSImage>()

    var cacheHits: UInt = 0
    var cacheMisses: UInt = 0
    var imageLoadSuccess: UInt = 0
    var imageLoadFailures: UInt = 0

    public func loadImage(filename: String) async throws -> NSImage? {
        let key = NSString(string: filename)
        var ret: NSImage? = nil

        // wait for semaphore before cache lookup
        await semaphore.wait()
        if let cachedImage = cache.object(forKey: key) {
            // cache hit, signal semaphore, return cached value
            ret = cachedImage
            cacheHits += 1
            log()
            semaphore.signal()
            return ret
        } else {
            // cache miss, load image from filename
            // signal semaphore while we load image async,
            // allowing other cache lookups while we load this image
            semaphore.signal()
            
            if let value = try await loadImageInt(filename: filename) {
                // image load success
                // wait for semaphore before putting into the cache
                await semaphore.wait()
                cacheMisses += 1
                imageLoadSuccess += 1
                cache.setObject(value, forKey: key)
                ret = value
                log()
                semaphore.signal()
            } else {
                await semaphore.wait()
                cacheMisses += 1                
                imageLoadFailures += 1
                log()
                semaphore.signal()
            }

            return ret
        }
    }

    // only call when holding the semaphore
    private func log() {
        //print("ImageCache \(cacheHits) cacheHits, \(cacheMisses) cacheMisses \(imageLoadFailures) imageLoadFailures \(imageLoadSuccess) imageLoadSuccess")
    }
}

public func loadImageInt(filename: String) async throws -> NSImage? {
    //print("ImageCache loadImageInt(filename: \(filename))")
    let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)
    let request = URLRequest(url: imageURL as URL)
    let (data, _) = try await URLSession.shared.data(for: request)
    return NSImage(data: data)
}

public func loadImageIntSync(filename: String) throws -> NSImage? {
    NSImage(data: try Data(contentsOf: URL(fileURLWithPath: filename)))
}


