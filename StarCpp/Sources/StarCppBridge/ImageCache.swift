// ImageCache.swift — Swift wrapper for image loading cache
import Foundation
import StarCpp

// Global storage for the loader box pointer — must be outside the closure for C function pointer compatibility
private nonisolated(unsafe) var _imageCacheLoaderBox: UnsafeMutableRawPointer?

private class LoaderBox {
    var loader: (String) -> MatWrapper?
    init(_ l: @escaping (String) -> MatWrapper?) { loader = l }
}

public enum ImageCache {
    /// Set the image loader callback. The loader receives a filename and must return a MatWrapper.
    public static func setLoader(_ loader: @escaping (String) -> MatWrapper?) {
        // We intentionally leak the box — the loader is expected to be set once and live forever
        let box = LoaderBox(loader)
        _imageCacheLoaderBox = Unmanaged.passRetained(box).toOpaque()

        image_cache_set_loader { filename, completion, completionCtx in
            guard let filename, let boxPtr = _imageCacheLoaderBox else {
                completion?(nil, completionCtx)
                return
            }
            let b = Unmanaged<LoaderBox>.fromOpaque(boxPtr).takeUnretainedValue()
            let name = String(cString: filename)
            if let mat = b.loader(name) {
                // Hand the C side its own ref sharing the same pixels. `mat` deinits
                // as this closure returns, releasing its ref; the shared buffer
                // survives on OpenCV's refcount. Loaded images are read-only
                // downstream, so sharing is safe — and a full-frame copy here cost
                // 241 MB and ~138 ms per 42MP neighbour load.
                let shared = mat_wrapper_alias(mat.ref)
                completion?(shared, completionCtx)
            } else {
                completion?(nil, completionCtx)
            }
        }
    }

    /// Load an image synchronously using the registered loader.
    public static func load(_ filename: String) -> MatWrapper? {
        guard let r = image_cache_load(filename) else { return nil }
        return MatWrapper(ref: r)
    }
}
