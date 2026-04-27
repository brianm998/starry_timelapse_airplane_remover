import Foundation
import logging
import KHTSwift


public let imageCache = ImageCache()

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T?) {
        self.value = value
    }
}

final class CompletionBox: @unchecked Sendable {
    let completion: (MatWrapper?) -> Void
    init(_ completion: @escaping (MatWrapper?) -> Void) {
        self.completion = completion
    }
}


public actor ImageCache {

    // Weak cache (reference-count–driven eviction)
    private var cache: [String: WeakBox<MatWrapper>] = [:]

    // Strong in-flight loads (deduplication)
    private var inFlight: [String: Task<MatWrapper?, Never>] = [:]

    private var cacheHits: UInt = 0
    private var cacheMisses: UInt = 0
    private var imageLoadSuccess: UInt = 0
    private var imageLoadFailures: UInt = 0

    init() {
        // Register our loader with the C++ image cache
        KHTSwift.ImageCache.setLoader { filename in
            MatWrapper.load(fromFilename: filename)
        }
    }

    public func add(image: PixelatedImage, named filename: String) {
        cache[filename] = WeakBox(image.mat)
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
    
    public func loadImage(filename: String) async -> PixelatedImage? {

        // 1️⃣ Weak cache hit
        if let box = cache[filename],
           let mat = box.value {

            cacheHits += 1
            return PixelatedImage(mat: mat)
        }

        // Clean up dead weak entry
        cache[filename] = nil

        // 2️⃣ In-flight deduplication
        if let task = inFlight[filename] {
            cacheMisses += 1
            if let mat = await task.value {
                return PixelatedImage(mat: mat)
            } else {
                return nil
            }
        }

        cacheMisses += 1

        // 3️⃣ Start new load (strong ownership inside task)
        let task: Task<MatWrapper?, Never> =
          Task.detached(priority: .userInitiated) { [filename] in
              if let mat = MatWrapper.load(fromFilename: filename),
                 !mat.isEmpty { mat }
              else { nil }
          }

        inFlight[filename] = task

        // 4️⃣ Await load
        let mat = await task.value

        // 5️⃣ Commit result (weakly)
        inFlight[filename] = nil

        if let mat {
            cache[filename] = WeakBox(mat)
            imageLoadSuccess += 1
            return PixelatedImage(mat: mat)
        } else {
            imageLoadFailures += 1
            return nil
        }
    }

}
