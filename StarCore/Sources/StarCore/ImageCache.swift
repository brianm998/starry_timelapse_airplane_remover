import Foundation
import CoreGraphics
import logging
import Cocoa
import Semaphore
import kht_bridge

public let imageCache = ImageCache()

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

// A single actor shared by all instances.
private actor TimeoutActor {
    func clear<T: AnyObject>(_ ref: TimeoutRef<T>, afterDelay delay: UInt64) async {
        try? await Task.sleep(nanoseconds: delay)
        ref.strongValue = nil
    }
}

// A single shared instance — allowed because it's non-generic.
fileprivate let globalTimeoutActor = TimeoutActor()

public final class TimeoutRef<T: AnyObject> {

    public var strongValue: T?
    public weak var value: T?

    public init(_ value: T?) {
        self.value = value
        self.strongValue = value

        let boxed = UncheckedBox(value: self) 

        Task {
            await globalTimeoutActor.clear(
              boxed.value,
              afterDelay: 10_000_000_000 // nanoseconds XXX MAKE THIS A PARAMETER
            )
        }
    }
}

final class CompletionBox: @unchecked Sendable {
    let completion: (MatWrapper?) -> Void
    init(_ completion: @escaping (MatWrapper?) -> Void) {
        self.completion = completion
    }
}

public actor ImageCache {

    // images indexed by filename

    var cache: [String : TimeoutRef<MatWrapper>] = [:]

    var cacheHits: UInt = 0
    var cacheMisses: UInt = 0
    var imageLoadSuccess: UInt = 0
    var imageLoadFailures: UInt = 0

    var pendingLoads: [String:AsyncSemaphore] = [:]
    
    init() {
        ObjcImageCache.imageLoader = { [weak self] name, completion in
            guard let self else {
                completion(nil)
                return
            }
            let box = CompletionBox(completion)

            Task { 
                do {
                    let image = try await self.loadImage(filename: name) 
                    box.completion(image?.mat)
                } catch {
                    Log.e("image load error: \(error)")
                    box.completion(nil)
                }
            }
        }
    }

    public func add(image: PixelatedImage, named filename: String) -> PixelatedImage {
        if image.isEmpty { Log.w("adding empty image to cache") }
        Log.d("caching \(filename)") 
        cache[filename] = TimeoutRef(image.mat)
        return image
    }
    
    public func prepareUpdate() -> (UInt, UInt, [Int: Int]) {
         
        var imageSizeToCountMap: [Int:Int] = [:]

        for (key, weakRef) in cache {
            if let cachedMat = weakRef.value,
               let cachedImage = PixelatedImage(mat: cachedMat) {
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

        Log.d("loadImage(filename: \(filename))")
        
        // if there is a pending load for this filename,
        // we will expect a semaphore for it
        let semaphore = pendingLoads[filename]

        // if we got a semaphore, wait for it,
        // instead of loading the same image in parallel
        if let semaphore {
            await semaphore.wait()
        }

        
        // first look in the cache
        if let cachedImageRef = cache[filename] {
            if let cachedImage = cachedImageRef.value {

                if cachedImage.isEmpty {
                    Log.w("CACHED IMAGE WAS EMPTY")
                }
                
                // cache hit, return cached value
                //Log.d("returning cachedImage \(cachedImage.description)")
                cacheHits += 1
                log()
                if let semaphore { semaphore.signal() }

                Log.d("loadImage(filename: \(filename)) returning cached image")
                return PixelatedImage(mat: cachedImage)
            } else {
                // weak ref in the cache was nil, remove TimeoutRef holder
                cache[filename] = nil
            }
        }

        // cache miss, load image from filename
        // allowing other cache lookups while we load this image,
        
        Log.d("loadImage(filename: \(filename)) cache miss")
        // blocking other requests for this same filename by semaphore
        let loadingSemaphore = AsyncSemaphore(value: 0)
        pendingLoads[filename] = loadingSemaphore

        var ret = await Task.detached(priority: .userInitiated) {
            // load the image in a separate task so other requests to
            // this cache are not blocked during load
            PixelatedImage(filename: filename) 
        }.value

        if let preClone = ret {
            if preClone.isEmpty {
                Log.w("NOT adding empty image to cache")
                cacheMisses += 1                
                imageLoadFailures += 1
                log()
            } else {
                Log.d("caching \(filename)") 
                cache[filename] = TimeoutRef(preClone.mat)
                ret = preClone // return the clone so ref goes out of scope sooner
                cacheMisses += 1
                imageLoadSuccess += 1
                log()
            }
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


