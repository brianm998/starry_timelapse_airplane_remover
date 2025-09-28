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

public final class TimeoutRef<T: AnyObject> {
    private var timer: DispatchSourceTimer?
    private let timeout: TimeInterval = 20
    
    private var _value: T?
    
    public var value: T? {
        get {
            resetTimer()
            return _value
        }
    }

    internal var valueInt: T? { _value }
    
    public init(_ value: T?) {
        self._value = value
        if value != nil {
            resetTimer()
        }
    }
    
    private func resetTimer() {
        cancelTimer()
        
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        Log.d("FUCKING setting timeout for 20 seconds from now")
        t.schedule(deadline: .now() + timeout)
        t.setEventHandler { [weak self] in
            Log.e("FUCKING CLEARING CACHE VALUE")
            self?.clearValue()
        }
        t.resume()
        timer = t
    }
    
    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
    
    public func clearValue() {
        _value = nil
    }
    
    deinit {
        cancelTimer()
    }
}

public actor ImageCache {

    // images indexed by filename
    var cache: [String : TimeoutRef<PixelatedImage>] = [:]

    var cacheHits: UInt = 0
    var cacheMisses: UInt = 0
    var imageLoadSuccess: UInt = 0
    var imageLoadFailures: UInt = 0

    var pendingLoads: [String:AsyncSemaphore] = [:]
    
    
    init() { }

    public func add(image: PixelatedImage, named filename: String) {
        if image.isEmpty { Log.w("adding empty image to cache") }
        cache[filename] = TimeoutRef(image)
    }
    
    public func prepareUpdate() -> (UInt, UInt, [Int: Int]) {
         
        var imageSizeToCountMap: [Int:Int] = [:]

        for (key, weakRef) in cache {
            if let cachedImage = weakRef.valueInt {
                if let count = imageSizeToCountMap[cachedImage.byteCount] {
                    imageSizeToCountMap[cachedImage.byteCount] = count + 1
                } else {
                    imageSizeToCountMap[cachedImage.byteCount] = 1
                }
            } else {
                // weak ref in the cache was nil, remove TimeoutRef holder
                cache[key] = nil
            }
        }

        return (cacheHits, cacheMisses, imageSizeToCountMap)
    }
    
    public func loadImage(filename: String) async throws -> PixelatedImage? {

        Log.d("FUCKING loadImage(\(filename))")
        
        // if there is a pending load for this filename,
        // we will expect a semaphore for it
        let semaphore = pendingLoads[filename]

        // if we got a semaphore, wait for it,
        // instead of loading the same image in parallel
        if let semaphore { await semaphore.wait() }

        
        // first look in the cache
        if //false,               // XXX disable caching XXX
           let cachedImageRef = cache[filename] {
            if let cachedImage = cachedImageRef.value {

                if cachedImage.isEmpty {
                    Log.w("CACHED IMAGE WAS EMPTY")
                }
                
                // cache hit, return cached value
                Log.d("returning cachedImage \(cachedImage.description)")
                cacheHits += 1
                log()
                if let semaphore { semaphore.signal() }
                return cachedImage.clone // XXX TEST XXX
            } else {
                // weak ref in the cache was nil, remove TimeoutRef holder
                cache[filename] = nil
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
            if ret.isEmpty { Log.w("adding empty image to cache") }
            cache[filename] = TimeoutRef(ret)
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


