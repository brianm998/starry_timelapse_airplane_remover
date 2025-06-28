import Foundation
import CoreGraphics
import logging
import Cocoa
import Semaphore

public let imageCache = ImageCache(cacheLimit: 10) // XXX guess

/*

 Keep a memory cache of PixelatedImages with with NSCache, keyed by filename.
 
 */
public actor ImageCache {

    // images indexed by filename
    let cache = NSCache<NSString, PixelatedImage>()

    var cacheHits: UInt = 0
    var cacheMisses: UInt = 0
    var imageLoadSuccess: UInt = 0
    var imageLoadFailures: UInt = 0

    var pendingLoads: [String:AsyncSemaphore] = [:]

    init(cacheLimit: Int) {
        cache.countLimit = cacheLimit
    }

    public func loadImage(filename: String) async throws -> PixelatedImage? {
        let key = NSString(string: filename)
        var ret: PixelatedImage? = nil

        // if there is a pending load for this filename,
        // we will expect a semaphore for it
        let semaphore = pendingLoads[filename]

        // if we got a semaphore, wait for it,
        // instead of loading the same image in parallel
        if let semaphore { await semaphore.wait() }

        // first look in the cache
        if let cachedImage = cache.object(forKey: key) {
            // cache hit, return cached value
            ret = cachedImage
            cacheHits += 1
            log()
            if let semaphore { semaphore.signal() }
            return ret
        } else {
            // cache miss, load image from filename
            // allowing other cache lookups while we load this image,
            
            // blocking other requests for this same filename by semaphore
            let loadingSemaphore = AsyncSemaphore(value: 0)
            pendingLoads[filename] = loadingSemaphore
            
            let ret = try await Task.detached(priority: .userInitiated) {
                // load the image in a separate task so other requests to
                // this cache are not blocked during load
                try await loadImageInt(filename: filename)
            }.value

            if let ret {
                cache.setObject(ret, forKey: key)
                cacheMisses += 1
                imageLoadSuccess += 1
                log()
            } else {
                cacheMisses += 1                
                imageLoadFailures += 1
                log()
            }
            pendingLoads[filename] = nil

            // let any other pending requests for this filename proceed
            loadingSemaphore.signal()

            // unlikely to end up here with this semaphore, but signal it if we do have one
            // could happen in case of asking for a missing file
            if let semaphore { semaphore.signal() }
            
            return ret
        }
    }

    private func log() {
        //print("ImageCache \(cacheHits) cacheHits, \(cacheMisses) cacheMisses \(imageLoadFailures) imageLoadFailures \(imageLoadSuccess) imageLoadSuccess")
    }
}

public func loadImageInt(filename: String) async throws -> PixelatedImage? {
    Log.d("ImageCache loadImageInt(filename: \(filename))")
    let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)
    let request = URLRequest(url: imageURL as URL)
    let (data, _) = try await URLSession.shared.data(for: request)
    if let nsImage = NSImage(data: data),
       let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
       let pixelatedImage = PixelatedImage(cgImage)
    {
        return pixelatedImage
    }
    return nil
}

public func loadImageIntSync(filename: String) throws -> NSImage? {
    NSImage(data: try Data(contentsOf: URL(fileURLWithPath: filename)))
}


