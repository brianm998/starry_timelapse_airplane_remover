import Foundation
import CoreGraphics
import logging
import Cocoa
import Semaphore

public let imageCache = ImageCache()

/*

 still missing:

  - expose stats about cached images to UI
  - how many
  - what size
  - ram usage of cached image buffers
 */

public final class WeakRef<T> {
    var value: T?

    init(_ value: T?) {
        self.value = value
    }
}

public actor ImageCache {

    // images indexed by filename
    var cache: [String : WeakRef<PixelatedImage>] = [:]

    var cacheHits: UInt = 0
    var cacheMisses: UInt = 0
    var imageLoadSuccess: UInt = 0
    var imageLoadFailures: UInt = 0

    var pendingLoads: [String:AsyncSemaphore] = [:]

    init() { }

    public func loadImage(filename: String) async throws -> PixelatedImage? {
        let key = filename

        // if there is a pending load for this filename,
        // we will expect a semaphore for it
        let semaphore = pendingLoads[filename]

        // if we got a semaphore, wait for it,
        // instead of loading the same image in parallel
        if let semaphore { await semaphore.wait() }

        
        // first look in the cache
        if let cachedImageRef = cache[key] {
            if let cachedImage = cachedImageRef.value {
                // cache hit, return cached value
                cacheHits += 1
                log()
                if let semaphore { semaphore.signal() }
                return cachedImage
            } else {
                // weak ref in the cache was nil, remove WeakRef holder
                cache[key] = nil
            }
        }
        
        // cache miss, load image from filename
        // allowing other cache lookups while we load this image,
        
        // blocking other requests for this same filename by semaphore
        let loadingSemaphore = AsyncSemaphore(value: 0)
        pendingLoads[filename] = loadingSemaphore
        
        let ret = try await Task.detached(priority: .userInitiated) {
            // load the image in a separate task so other requests to
            // this cache are not blocked during load
            PixelatedImage(filename: filename) 
        }.value

        if let ret {
            cache[key] = WeakRef(ret)
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


    private func log() {
        //print("ImageCache \(cacheHits) cacheHits, \(cacheMisses) cacheMisses \(imageLoadFailures) imageLoadFailures \(imageLoadSuccess) imageLoadSuccess")
    }
}


