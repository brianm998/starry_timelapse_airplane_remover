// GPUOps.swift — the Metal backend for warpInto/medianImageFromMats in
// ImageAligner.cpp. See GPUOps_C.h for the registration contract.
//
// StarCpp (the C++ target) is pure C++, so this lives here in StarCppBridge
// instead — Metal's native API is Swift/Objective-C, not C++, and this
// package already links Metal.framework on macOS (see Package.swift).
import Foundation
import StarCpp
import logging
#if canImport(Metal)
import Metal
#endif
#if canImport(MetalPerformanceShaders)
import MetalPerformanceShaders
#endif

public enum GPUOps {

    /// Registers the Metal backend with the C++ layer if this machine has one, and
    /// reports whether it did. Idempotent and safe to call from every client's
    /// startup path — `StarCore.ImageCache.init()` is where it is actually called,
    /// once, the same place `ImageCache.setLoader` already runs for every client.
    @discardableResult
    public static func registerIfAvailable() -> Bool {
        didRegister
    }

    private static let didRegister: Bool = {
        #if canImport(Metal) && os(macOS)
        guard GPUCapability.isAvailable(), let backend = MetalGPUBackend() else { return false }
        activeBackend = backend

        gpu_ops_set_handlers(
          { src, homography, dst in
              guard let backend = activeBackend, let src, let homography, let dst else { return false }
              return backend.warp(src: src, homography: homography, dst: dst)
          },
          { sources, count, misses, outlierThreshold, includeAll, dst in
              guard let backend = activeBackend, let sources, let dst, count > 0 else { return false }
              return backend.medianMerge(sources: sources, count: Int(count), misses: misses,
                                         outlierThreshold: outlierThreshold, includeAll: includeAll,
                                         dst: dst)
          }
        )
        // Separate registration call, deliberately — see GPUOps_C.h: this backend
        // is gated by its own Config.useGPUForSIFT flag, off by default, not by
        // Config.useGPU above.
        gpu_ops_set_sift_pyramid_handler { base, doubleImageSize, sigma, nOctaves, nOctaveLayers, outPyramid in
            guard let backend = activeBackend, let base, let outPyramid else { return false }
            return backend.buildSiftPyramid(base: base, doubleImageSize: doubleImageSize, sigma: sigma,
                                            nOctaves: Int(nOctaves), nOctaveLayers: Int(nOctaveLayers),
                                            outPyramid: outPyramid)
        }
        Log.i("GPU acceleration registered (\(GPUCapability.deviceName() ?? "unknown device")).")
        return true
        #else
        return false
        #endif
    }()
}

#if canImport(Metal) && os(macOS)

// Written once by `didRegister` above and read only from the C-callable closures
// registered there, which never run concurrently with that write (they can only
// fire after gpu_ops_set_handlers has returned). Global rather than captured,
// for the same reason as ImageCache.swift's loader box: a Swift closure that
// captures only a top-level global, not a local, converts implicitly to the
// `@convention(c)` function pointer GPUWarpFunc/GPUMedianMergeFunc need.
private nonisolated(unsafe) var activeBackend: MetalGPUBackend?

/// Owns the Metal device, queue and compiled pipelines. One instance for the
/// process; StarCppBridge has no build-time Metal toolchain available on this
/// machine (see GPU_IMPLEMENTATION_GUIDE.md), so the kernels are compiled from
/// source at first use rather than shipped as a precompiled .metallib — a
/// build-time step to revisit once that toolchain is available everywhere
/// this ships.
private final class MetalGPUBackend: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let warpU8: MTLComputePipelineState
    let warpU16: MTLComputePipelineState
    let medianU8: MTLComputePipelineState
    let medianU16: MTLComputePipelineState
    let downsampleNearest2xF32: MTLComputePipelineState

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        do {
            let library = try device.makeLibrary(source: MetalGPUBackend.shaderSource, options: nil)
            func pipeline(_ name: String) throws -> MTLComputePipelineState {
                guard let function = library.makeFunction(name: name) else {
                    throw NSError(domain: "GPUOps", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "missing Metal function \(name)"])
                }
                return try device.makeComputePipelineState(function: function)
            }
            self.warpU8 = try pipeline("warp_u8")
            self.warpU16 = try pipeline("warp_u16")
            self.medianU8 = try pipeline("median_merge_u8")
            self.medianU16 = try pipeline("median_merge_u16")
            self.downsampleNearest2xF32 = try pipeline("downsample_nearest_2x_f32")
        } catch {
            Log.e("GPU acceleration unavailable: failed to compile Metal kernels (\(error)).")
            return nil
        }
    }

    // MARK: - Warp

    /// Matches cv::warpPerspective(src, dst, H, src.size(), INTER_LINEAR,
    /// BORDER_TRANSPARENT): `homography` maps src -> dst (row-major 3x3, same
    /// convention OpenCV takes), and every destination pixel whose bilinear
    /// sample window falls entirely outside the source is left untouched (the
    /// caller pre-zeroes `dst`).
    ///
    /// Very close to, but not proven, bit-identical to OpenCV's own kernel.
    /// `remapBilinear` there is fixed-point integer arithmetic built from a
    /// precomputed coefficient table indexed by a 5-bit (`INTER_TAB_SIZE` = 32)
    /// quantization of the fractional sample position — not a continuous
    /// bilinear formula — and this kernel reproduces that quantization (see
    /// `kTabSize` below) rather than only the bilinear math. That quantization,
    /// not float-vs-fixed-point arithmetic, turned out to be the dominant term:
    /// a synthetic high-frequency test pattern measured a 72-of-65535 worst-case
    /// difference without it and 1-of-65535 with it (see GPUOpsTests). The
    /// remaining ~1 LSB is consistent with ordinary float32-vs-fixed-point
    /// rounding at the final weighted sum, but this was not proven equal to
    /// OpenCV's actual rounding step, so "very close" rather than "identical" is
    /// the honest claim without the differential harness
    /// GPU_IMPLEMENTATION_GUIDE.md describes (built from `#include`-ing the real
    /// OpenCV source, which this offline, binary-only vendored copy does not
    /// have). The BORDER_TRANSPARENT boundary rule (untouched iff none of a
    /// pixel's four sample corners exist in the source, renormalised by the
    /// weights that do when some exist) is exact, not approximate — it is a
    /// pure in/out-of-bounds test, which is what the "zero means no data"
    /// invariant the merge depends on actually needs.
    func warp(src: MatWrapperRef, homography: UnsafePointer<Double>, dst: MatWrapperRef) -> Bool {
        let rows = Int(mat_wrapper_rows(src))
        let cols = Int(mat_wrapper_cols(src))
        let channels = Int(mat_wrapper_channels(src))
        guard rows > 0, cols > 0, channels >= 1, channels <= 4,
              rows == Int(mat_wrapper_rows(dst)), cols == Int(mat_wrapper_cols(dst)),
              channels == Int(mat_wrapper_channels(dst)),
              mat_wrapper_bits_per_component(src) == mat_wrapper_bits_per_component(dst)
        else { return false }

        let bitsPerComponent = mat_wrapper_bits_per_component(src)
        let pipeline: MTLComputePipelineState
        switch bitsPerComponent {
        case 8: pipeline = warpU8
        case 16: pipeline = warpU16
        default: return false   // 32-bit sources are never warped in this codebase
        }

        guard let srcPtr = mat_wrapper_data_ptr(src), let dstPtr = mat_wrapper_data_ptr(dst),
              let hInv = invert3x3(homography)
        else { return false }

        let bytesPerComponent = Int(bitsPerComponent) / 8
        let srcStepBytes = Int(mat_wrapper_step(src))
        let dstStepBytes = Int(mat_wrapper_step(dst))
        // Element (not byte) stride: the kernels index typed buffers (uchar*/ushort*).
        guard srcStepBytes % bytesPerComponent == 0, dstStepBytes % bytesPerComponent == 0 else { return false }
        let srcStepElems = Int32(srcStepBytes / bytesPerComponent)
        let dstStepElems = Int32(dstStepBytes / bytesPerComponent)

        var hInvFloat = hInv.map { Float($0) }

        guard let srcBuf = device.makeBuffer(bytes: srcPtr, length: rows * srcStepBytes,
                                             options: .storageModeShared),
              let dstBuf = device.makeBuffer(length: rows * dstStepBytes, options: .storageModeShared),
              let hBuf = device.makeBuffer(bytes: &hInvFloat, length: 9 * MemoryLayout<Float>.stride,
                                           options: .storageModeShared),
              let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder()
        else { return false }

        // `dst` was pre-zeroed by the caller; the copy above did not touch it, and the
        // kernel only ever writes a pixel it can fully or partially sample, so the rest
        // stays zero exactly as the CPU path leaves it.
        var width = Int32(cols), height = Int32(rows), chans = Int32(channels)
        var srcStep = srcStepElems, dstStep = dstStepElems

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(srcBuf, offset: 0, index: 0)
        encoder.setBuffer(dstBuf, offset: 0, index: 1)
        encoder.setBuffer(hBuf, offset: 0, index: 2)
        encoder.setBytes(&width, length: MemoryLayout<Int32>.size, index: 3)
        encoder.setBytes(&height, length: MemoryLayout<Int32>.size, index: 4)
        encoder.setBytes(&chans, length: MemoryLayout<Int32>.size, index: 5)
        encoder.setBytes(&srcStep, length: MemoryLayout<Int32>.size, index: 6)
        encoder.setBytes(&dstStep, length: MemoryLayout<Int32>.size, index: 7)

        dispatch(encoder: encoder, pipeline: pipeline, width: cols, height: rows)
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        guard cmdBuf.status == .completed else { return false }

        memcpy(UnsafeMutableRawPointer(mutating: dstPtr), dstBuf.contents(), rows * dstStepBytes)
        return true
    }

    // MARK: - Median merge

    /// Matches medianMergeTyped's selection exactly (same sort-then-index-pick
    /// logic, same CoverageMisses contract), except mean/variance are exact-sum
    /// float32 rather than the CPU kernel's double-precision Welford recurrence —
    /// Apple GPUs have no fp64. The sum (n <= 17 values, each <= 65535) is exact in
    /// float32, so this avoids the sum-of-squares cancellation a naive
    /// `sumSq - sum^2/count` formula would suffer; only the final division and
    /// square root lose the last handful of bits double precision would have kept.
    /// A deliberate, small, documented output difference — see
    /// GPU_IMPLEMENTATION_GUIDE.md ยง2 and GPUMedianMergeTests for the measured size
    /// of it.
    func medianMerge(sources: UnsafeMutablePointer<MatWrapperRef?>, count: Int,
                     misses: MatWrapperRef?, outlierThreshold: Double, includeAll: Bool,
                     dst: MatWrapperRef) -> Bool {
        guard count > 0, count <= 17, let first = sources[0] else { return false }
        let rows = Int(mat_wrapper_rows(first))
        let cols = Int(mat_wrapper_cols(first))
        let channels = Int(mat_wrapper_channels(first))
        let bitsPerComponent = mat_wrapper_bits_per_component(first)
        guard rows > 0, cols > 0, channels >= 1, channels <= 4,
              rows == Int(mat_wrapper_rows(dst)), cols == Int(mat_wrapper_cols(dst)),
              channels == Int(mat_wrapper_channels(dst)),
              bitsPerComponent == mat_wrapper_bits_per_component(dst)
        else { return false }

        let bytesPerComponent: Int
        let pipeline: MTLComputePipelineState
        switch bitsPerComponent {
        case 8: bytesPerComponent = 1; pipeline = medianU8
        case 16: bytesPerComponent = 2; pipeline = medianU16
        default: return false
        }

        let rowBytes = cols * channels * bytesPerComponent
        var packedSources = [UInt8](repeating: 0, count: rowBytes * rows * count)
        let ok = packedSources.withUnsafeMutableBytes { raw -> Bool in
            for i in 0..<count {
                guard let s = sources[i],
                      Int(mat_wrapper_rows(s)) == rows, Int(mat_wrapper_cols(s)) == cols,
                      Int(mat_wrapper_channels(s)) == channels,
                      mat_wrapper_bits_per_component(s) == bitsPerComponent,
                      let ptr = mat_wrapper_data_ptr(s)
                else { return false }
                let step = Int(mat_wrapper_step(s))
                let base = raw.baseAddress!.advanced(by: i * rowBytes * rows)
                for y in 0..<rows {
                    memcpy(base.advanced(by: y * rowBytes), ptr.advanced(by: y * step), rowBytes)
                }
            }
            return true
        }
        guard ok else { return false }

        // includeAll never allocates a coverage plane on the C++ side (misses ==
        // nullptr), and the kernel is told so via `includeAllFlag` rather than by
        // inferring it from a null buffer — Metal has no null-buffer convention as
        // clean as C's, so a real (tiny, unread) buffer stands in.
        var missesPacked = [UInt8](repeating: 0, count: max(1, cols * rows))
        if let misses {
            guard Int(mat_wrapper_rows(misses)) == rows, Int(mat_wrapper_cols(misses)) == cols,
                  let mptr = mat_wrapper_data_ptr(misses)
            else { return false }
            let mstep = Int(mat_wrapper_step(misses))
            missesPacked.withUnsafeMutableBytes { raw in
                for y in 0..<rows {
                    memcpy(raw.baseAddress!.advanced(by: y * cols), mptr.advanced(by: y * mstep), cols)
                }
            }
        }

        guard let srcBuf = packedSources.withUnsafeBytes({ raw in
                  device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
              }),
              let missesBuf = missesPacked.withUnsafeBytes({ raw in
                  device.makeBuffer(bytes: raw.baseAddress!, length: raw.count, options: .storageModeShared)
              }),
              let dstBuf = device.makeBuffer(length: rowBytes * rows, options: .storageModeShared),
              let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder()
        else { return false }

        var width = Int32(cols), height = Int32(rows), chans = Int32(channels)
        var sourceCount = Int32(count)
        var threshold = Float(outlierThreshold)
        var includeAllFlag: Int32 = includeAll ? 1 : 0

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(srcBuf, offset: 0, index: 0)
        encoder.setBuffer(missesBuf, offset: 0, index: 1)
        encoder.setBuffer(dstBuf, offset: 0, index: 2)
        encoder.setBytes(&width, length: MemoryLayout<Int32>.size, index: 3)
        encoder.setBytes(&height, length: MemoryLayout<Int32>.size, index: 4)
        encoder.setBytes(&chans, length: MemoryLayout<Int32>.size, index: 5)
        encoder.setBytes(&sourceCount, length: MemoryLayout<Int32>.size, index: 6)
        encoder.setBytes(&threshold, length: MemoryLayout<Float>.size, index: 7)
        encoder.setBytes(&includeAllFlag, length: MemoryLayout<Int32>.size, index: 8)

        dispatch(encoder: encoder, pipeline: pipeline, width: cols, height: rows)
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        guard cmdBuf.status == .completed else { return false }

        guard let dstPtr = mat_wrapper_data_ptr(dst) else { return false }
        let dstStepBytes = Int(mat_wrapper_step(dst))
        let outBase = dstBuf.contents()
        for y in 0..<rows {
            memcpy(UnsafeMutableRawPointer(mutating: dstPtr).advanced(by: y * dstStepBytes),
                   outBase.advanced(by: y * rowBytes), rowBytes)
        }
        return true
    }

    // MARK: - SIFT Gaussian pyramid

    /// Builds the Gaussian scale-space pyramid `siftDetectAndComputeGPU`
    /// (SIFTDetector.cpp) needs, via `MPSImageGaussianBlur` for every blur and
    /// `MPSImageBilinearScale`/a tiny custom kernel for the two resizes — see
    /// GPUOps_C.h's `GPUSiftPyramidFunc` for the exact contract this implements.
    /// All work for one pyramid goes on one command buffer, committed once at
    /// the end; every intermediate texture is kept alive until then, since
    /// every one of them is also an output.
    ///
    /// `.storageModeManaged`, not `.shared`: measured directly on this Vega —
    /// a `.shared` texture a compute kernel writes to reads back as all zeros
    /// on this GPU (a plain constant-fill kernel, and `MPSImageGaussianBlur`
    /// itself, both "succeed" with no Metal error and no visible effect),
    /// while the exact same kernel against a `.managed` texture, synchronized
    /// with an explicit blit before `getBytes`, reads back correctly. Tier 1's
    /// kernels never hit this because they use buffers, not textures — a
    /// `.shared` *buffer* behaves as documented here. Revisit if this ever
    /// needs to run on Apple Silicon, where `.managed` does not exist and
    /// `.shared` textures are the only (and correct) choice.
    ///
    /// `MPSImageGaussianBlur` itself is documented (MPSImageConvolution.h) as
    /// "mathematically... an approximate gaussian... suitable for all common
    /// image processing needs demanding ~10 bits of precision or less" — SIFT's
    /// sub-pixel extremum refinement is exactly the kind of higher-precision
    /// consumer that warning is aimed at, and it shows: measured keypoint
    /// agreement against the real-cv::GaussianBlur reference pyramid is
    /// ~83%, well short of the reference pyramid's own ~85%+ agreement with
    /// real cv::SIFT (see SIFTDetectorTests.swift). That gap is the
    /// documented approximation, not a bug in this function.
    func buildSiftPyramid(base: MatWrapperRef, doubleImageSize: Bool, sigma: Double,
                          nOctaves: Int, nOctaveLayers: Int,
                          outPyramid: UnsafeMutablePointer<MatWrapperRef?>) -> Bool {
        guard nOctaves > 0, nOctaveLayers > 0 else { return false }
        guard mat_wrapper_bits_per_component(base) == 32, mat_wrapper_channels(base) == 1 else {
            return false  // SIFTDetector.cpp always hands this CV_32FC1; anything else is a caller bug
        }
        let baseRows = Int(mat_wrapper_rows(base))
        let baseCols = Int(mat_wrapper_cols(base))
        guard baseRows > 0, baseCols > 0, let basePtr = mat_wrapper_data_ptr(base) else { return false }
        let baseStepBytes = Int(mat_wrapper_step(base))

        guard let inputTexture = makeFloatTexture(width: baseCols, height: baseRows) else { return false }
        inputTexture.replace(region: MTLRegionMake2D(0, 0, baseCols, baseRows), mipmapLevel: 0,
                             withBytes: basePtr, bytesPerRow: baseStepBytes)

        guard let cmdBuf = queue.makeCommandBuffer() else { return false }

        // createInitialImage: the optional 2x upscale (plain bilinear — matching
        // cv::SIFT::create()'s actual enable_precise_upscale=false default, not
        // the warpAffine/BORDER_REFLECT "precise" path) ...
        var current = inputTexture
        var curWidth = baseCols, curHeight = baseRows
        if doubleImageSize {
            guard let doubled = makeFloatTexture(width: baseCols * 2, height: baseRows * 2) else {
                return false
            }
            let scaler = MPSImageBilinearScale(device: device)
            var transform = MPSScaleTransform(scaleX: 2.0, scaleY: 2.0, translateX: 0, translateY: 0)
            withUnsafePointer(to: &transform) { scaler.scaleTransform = $0 }
            scaler.encode(commandBuffer: cmdBuf, sourceTexture: current, destinationTexture: doubled)
            current = doubled
            curWidth *= 2
            curHeight *= 2
        }

        // ... then createInitialImage's own blur by sigDiff, exactly as
        // createInitialImageReference computes it.
        let initSigma = 0.5
        let sigDiffSq = doubleImageSize
            ? sigma * sigma - initSigma * initSigma * 4
            : sigma * sigma - initSigma * initSigma
        let sigDiff = Foundation.sqrt(max(sigDiffSq, 0.01))

        guard let firstLayer = makeFloatTexture(width: curWidth, height: curHeight) else { return false }
        MPSImageGaussianBlur(device: device, sigma: Float(sigDiff))
            .encode(commandBuffer: cmdBuf, sourceTexture: current, destinationTexture: firstLayer)

        // buildGaussianPyramid's own incremental sigma schedule: sigma_total^2 =
        // sigma_i^2 + sigma_{i-1}^2, so blur i only ever adds the sigma blur
        // i-1 is missing, not the full sigma again.
        var sig = [Double](repeating: 0, count: nOctaveLayers + 3)
        sig[0] = sigma
        let k = Foundation.pow(2.0, 1.0 / Double(nOctaveLayers))
        for i in 1..<(nOctaveLayers + 3) {
            let sigPrev = Foundation.pow(k, Double(i - 1)) * sigma
            let sigTotal = sigPrev * k
            sig[i] = Foundation.sqrt(sigTotal * sigTotal - sigPrev * sigPrev)
        }

        var textures = [MTLTexture?](repeating: nil, count: nOctaves * (nOctaveLayers + 3))
        textures[0] = firstLayer

        for o in 0..<nOctaves {
            for i in 0..<(nOctaveLayers + 3) {
                let idx = o * (nOctaveLayers + 3) + i
                if o == 0 && i == 0 { continue }  // firstLayer, already placed above

                if i == 0 {
                    // Base of a new octave: exact nearest-neighbour halving of the
                    // previous octave's last layer — matching buildGaussianPyramid's
                    // own INTER_NEAREST resize, not a blur.
                    let srcIdx = (o - 1) * (nOctaveLayers + 3) + nOctaveLayers
                    guard let src = textures[srcIdx] else { return false }
                    let dstWidth = src.width / 2, dstHeight = src.height / 2
                    guard dstWidth > 0, dstHeight > 0,
                          let dst = makeFloatTexture(width: dstWidth, height: dstHeight),
                          let encoder = cmdBuf.makeComputeCommandEncoder()
                    else { return false }
                    encoder.setComputePipelineState(downsampleNearest2xF32)
                    encoder.setTexture(src, index: 0)
                    encoder.setTexture(dst, index: 1)
                    dispatch(encoder: encoder, pipeline: downsampleNearest2xF32,
                            width: dstWidth, height: dstHeight)
                    encoder.endEncoding()
                    textures[idx] = dst
                } else {
                    guard let src = textures[idx - 1],
                          let dst = makeFloatTexture(width: src.width, height: src.height)
                    else { return false }
                    MPSImageGaussianBlur(device: device, sigma: Float(sig[i]))
                        .encode(commandBuffer: cmdBuf, sourceTexture: src, destinationTexture: dst)
                    textures[idx] = dst
                }
            }
        }

        // `.managed` textures need an explicit GPU->CPU sync before a CPU-side
        // `getBytes` sees what the GPU wrote — see this function's doc comment.
        guard let syncEncoder = cmdBuf.makeBlitCommandEncoder() else { return false }
        for texture in textures {
            guard let texture else { return false }
            syncEncoder.synchronize(resource: texture)
        }
        syncEncoder.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        guard cmdBuf.status == .completed else { return false }

        for idx in 0..<textures.count {
            guard let texture = textures[idx], let mat = matWrapper(fromFloatTexture: texture) else {
                return false
            }
            outPyramid[idx] = mat
        }
        return true
    }

    private func makeFloatTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .managed
        return device.makeTexture(descriptor: descriptor)
    }

    /// Reads a texture back into a newly allocated, tightly-packed CV_32FC1
    /// MatWrapper — `mat_wrapper_create(..., takeOwnership: true)` clones the
    /// buffer this hands it, so the Swift array backing that buffer is safe to
    /// free (by simply going out of scope) as soon as the call returns. Callers
    /// must already have synchronized `texture` (see `buildSiftPyramid`) —
    /// this does not do it again.
    private func matWrapper(fromFloatTexture texture: MTLTexture) -> MatWrapperRef? {
        let width = texture.width, height = texture.height
        let rowBytes = width * MemoryLayout<Float>.size
        var pixels = [Float](repeating: 0, count: width * height)
        let ref: MatWrapperRef? = pixels.withUnsafeMutableBytes { raw -> MatWrapperRef? in
            guard let base = raw.baseAddress else { return nil }
            texture.getBytes(base, bytesPerRow: rowBytes,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            let cvType = mat_wrapper_cv_type_for(32, 1)
            return mat_wrapper_create(Int64(width), Int64(height), cvType, rowBytes, base, true)
        }
        return ref
    }

    // MARK: - Shared dispatch

    private func dispatch(encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState,
                          width: Int, height: Int) {
        let w = min(16, pipeline.threadExecutionWidth)
        let h = min(16, max(1, pipeline.maxTotalThreadsPerThreadgroup / w))
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }

    // MARK: - Shader source

    /// Compiled at runtime via `makeLibrary(source:)` rather than shipped as a
    /// precompiled `.metallib`, since the offline Metal toolchain
    /// (`xcrun metal`) is not installed on this build machine — see
    /// GPU_IMPLEMENTATION_GUIDE.md ยง0. Revisit once it is: a precompiled library
    /// avoids paying shader-compile time on every process launch.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    inline bool sample_valid(int x, int y, int width, int height) {
        return x >= 0 && x < width && y >= 0 && y < height;
    }

    // homography is the INVERSE mapping (dst -> src), row-major 3x3 -- the same
    // convention cv::warpPerspective uses internally for a forward-mapping H.
    template <typename T, int MAXV>
    inline void warp_generic(device const T* src, device T* dst,
                             constant float* hInv,
                             int width, int height, int channels,
                             int srcStep, int dstStep, uint2 gid)
    {
        if ((int)gid.x >= width || (int)gid.y >= height) return;

        float x = float(gid.x), y = float(gid.y);
        float w = hInv[6] * x + hInv[7] * y + hInv[8];
        if (fabs(w) < 1e-12f) return;
        float sx = (hInv[0] * x + hInv[1] * y + hInv[2]) / w;
        float sy = (hInv[3] * x + hInv[4] * y + hInv[5]) / w;
        if (!isfinite(sx) || !isfinite(sy)) return;

        int ix = int(floor(sx));
        int iy = int(floor(sy));
        float fx = sx - float(ix);
        float fy = sy - float(iy);

        // OpenCV's INTER_LINEAR does not interpolate at the exact fractional
        // position: it quantizes it to one of 32 steps (INTER_TAB_SIZE, a 5-bit
        // fixed-point fraction) via a precomputed coefficient table. Matching that
        // quantization -- not just the bilinear formula -- is most of what makes
        // this kernel track OpenCV's actual output instead of a continuous-float
        // bilinear resample that merely looks similar; see GPUWarpTests for the
        // measured effect (removing this raised the interior max delta by >10x on
        // a synthetic high-frequency pattern).
        const float kTabSize = 32.0f;
        int fxi = int(round(fx * kTabSize));
        if (fxi >= int(kTabSize)) { fxi -= int(kTabSize); ix += 1; }
        int fyi = int(round(fy * kTabSize));
        if (fyi >= int(kTabSize)) { fyi -= int(kTabSize); iy += 1; }
        fx = float(fxi) / kTabSize;
        fy = float(fyi) / kTabSize;

        float w00 = (1.0f - fx) * (1.0f - fy);
        float w10 = fx * (1.0f - fy);
        float w01 = (1.0f - fx) * fy;
        float w11 = fx * fy;

        bool v00 = sample_valid(ix,     iy,     width, height);
        bool v10 = sample_valid(ix + 1, iy,     width, height);
        bool v01 = sample_valid(ix,     iy + 1, width, height);
        bool v11 = sample_valid(ix + 1, iy + 1, width, height);
        if (!v00 && !v10 && !v01 && !v11) return;   // fully outside: dst stays zero

        float wsum = (v00 ? w00 : 0.0f) + (v10 ? w10 : 0.0f)
                   + (v01 ? w01 : 0.0f) + (v11 ? w11 : 0.0f);
        if (wsum <= 1e-6f) return;

        size_t dstBase = (size_t)gid.y * (size_t)dstStep + (size_t)gid.x * (size_t)channels;
        for (int c = 0; c < channels; ++c) {
            float acc = 0;
            if (v00) acc += w00 * float(src[(size_t)iy * srcStep + (size_t)ix * channels + c]);
            if (v10) acc += w10 * float(src[(size_t)iy * srcStep + (size_t)(ix + 1) * channels + c]);
            if (v01) acc += w01 * float(src[(size_t)(iy + 1) * srcStep + (size_t)ix * channels + c]);
            if (v11) acc += w11 * float(src[(size_t)(iy + 1) * srcStep + (size_t)(ix + 1) * channels + c]);
            float val = acc / wsum;
            dst[dstBase + c] = T(clamp(val + 0.5f, 0.0f, float(MAXV)));
        }
    }

    kernel void warp_u8(device const uchar* src [[buffer(0)]],
                        device uchar* dst [[buffer(1)]],
                        constant float* hInv [[buffer(2)]],
                        constant int& width [[buffer(3)]],
                        constant int& height [[buffer(4)]],
                        constant int& channels [[buffer(5)]],
                        constant int& srcStep [[buffer(6)]],
                        constant int& dstStep [[buffer(7)]],
                        uint2 gid [[thread_position_in_grid]])
    {
        warp_generic<uchar, 255>(src, dst, hInv, width, height, channels, srcStep, dstStep, gid);
    }

    kernel void warp_u16(device const ushort* src [[buffer(0)]],
                         device ushort* dst [[buffer(1)]],
                         constant float* hInv [[buffer(2)]],
                         constant int& width [[buffer(3)]],
                         constant int& height [[buffer(4)]],
                         constant int& channels [[buffer(5)]],
                         constant int& srcStep [[buffer(6)]],
                         constant int& dstStep [[buffer(7)]],
                         uint2 gid [[thread_position_in_grid]])
    {
        warp_generic<ushort, 65535>(src, dst, hInv, width, height, channels, srcStep, dstStep, gid);
    }

    // Sources are packed tightly (no per-source step): source i, row y, pixel x,
    // channel c is at sources[i*width*height*channels + y*width*channels + x*channels + c].
    // `misses[y*width + x]` counts how many of the FIRST `misses[...]` sources (in
    // array order, matching CoverageMisses in ImageAligner.cpp) have no sample here
    // -- ignored when includeAllFlag != 0, in which case every source counts.
    template <typename T, int MAXV>
    inline void median_merge_generic(device const T* sources, device const uchar* misses,
                                     device T* dst,
                                     int width, int height, int channels, int count,
                                     float outlierThreshold, int includeAllFlag, uint2 gid)
    {
        if ((int)gid.x >= width || (int)gid.y >= height) return;

        const int frameStride = width * height * channels;
        const int pixelBase = gid.y * width * channels + gid.x * channels;
        const bool includeAll = includeAllFlag != 0;
        const int missCount = includeAll ? 0 : int(misses[gid.y * width + gid.x]);
        const int n = count;

        for (int c = 0; c < channels; ++c) {
            float v[17];
            for (int i = 0; i < n; ++i) v[i] = float(sources[i * frameStride + pixelBase + c]);

            // insertion sort ascending -- n <= 17, and absent sources (value 0,
            // the type's minimum) sort to the front, which is what lets `first`
            // below skip them by count alone.
            for (int i = 1; i < n; ++i) {
                float key = v[i];
                int j = i - 1;
                while (j >= 0 && v[j] > key) { v[j + 1] = v[j]; --j; }
                v[j + 1] = key;
            }

            const int minIndex = includeAll ? 0 : min(missCount, n);
            const int first = includeAll ? 0 : min(minIndex, n - 1);
            const int cnt = n - first;

            float sum = 0;
            for (int i = first; i < n; ++i) sum += v[i];
            const float mean = sum / float(cnt);

            float m2 = 0;
            for (int i = first; i < n; ++i) { float d = v[i] - mean; m2 += d * d; }
            const float threshold = mean + outlierThreshold * sqrt(m2 / float(cnt));

            int maxIndex = n;
            if (!includeAll) {
                for (int z = first; z < n; ++z) {
                    if (v[z] < threshold) maxIndex = z; else break;
                }
            }

            int idx = (minIndex + maxIndex) / 2;
            if (idx >= n) idx = n - 1;
            if (idx < first) idx = first;

            dst[pixelBase + c] = T(clamp(v[idx], 0.0f, float(MAXV)));
        }
    }

    kernel void median_merge_u8(device const uchar* sources [[buffer(0)]],
                                device const uchar* misses [[buffer(1)]],
                                device uchar* dst [[buffer(2)]],
                                constant int& width [[buffer(3)]],
                                constant int& height [[buffer(4)]],
                                constant int& channels [[buffer(5)]],
                                constant int& count [[buffer(6)]],
                                constant float& outlierThreshold [[buffer(7)]],
                                constant int& includeAllFlag [[buffer(8)]],
                                uint2 gid [[thread_position_in_grid]])
    {
        median_merge_generic<uchar, 255>(sources, misses, dst, width, height, channels, count,
                                         outlierThreshold, includeAllFlag, gid);
    }

    kernel void median_merge_u16(device const ushort* sources [[buffer(0)]],
                                 device const uchar* misses [[buffer(1)]],
                                 device ushort* dst [[buffer(2)]],
                                 constant int& width [[buffer(3)]],
                                 constant int& height [[buffer(4)]],
                                 constant int& channels [[buffer(5)]],
                                 constant int& count [[buffer(6)]],
                                 constant float& outlierThreshold [[buffer(7)]],
                                 constant int& includeAllFlag [[buffer(8)]],
                                 uint2 gid [[thread_position_in_grid]])
    {
        median_merge_generic<ushort, 65535>(sources, misses, dst, width, height, channels, count,
                                            outlierThreshold, includeAllFlag, gid);
    }

    // Exact 2x nearest-neighbour downsample, matching buildGaussianPyramid's own
    // cv::resize(..., INTER_NEAREST) at each octave boundary -- a plain stride-2
    // read, not a blur.
    kernel void downsample_nearest_2x_f32(texture2d<float, access::read> src [[texture(0)]],
                                          texture2d<float, access::write> dst [[texture(1)]],
                                          uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float value = src.read(uint2(gid.x * 2, gid.y * 2)).r;
        dst.write(float4(value, 0.0, 0.0, 0.0), gid);
    }
    """
}

/// Closed-form 3x3 inverse of the row-major matrix `m` points at (9 doubles).
/// Returns nil when `m` is (near-)singular, which the caller treats as "cannot
/// use the GPU for this warp" — not every 3x3 handed to `warpInto` is actually
/// invertible in principle, though in practice a homography that reached this
/// point already survived RANSAC.
private func invert3x3(_ m: UnsafePointer<Double>) -> [Double]? {
    let a = m[0], b = m[1], c = m[2]
    let d = m[3], e = m[4], f = m[5]
    let g = m[6], h = m[7], i = m[8]

    let A = e * i - f * h
    let B = -(d * i - f * g)
    let C = d * h - e * g
    let det = a * A + b * B + c * C
    guard abs(det) > 1e-15 else { return nil }
    let invDet = 1.0 / det

    let D = -(b * i - c * h)
    let E = a * i - c * g
    let F = -(a * h - b * g)
    let G = b * f - c * e
    let H = -(a * f - c * d)
    let I = a * e - b * d

    // Adjugate is the transpose of the cofactor matrix; dividing by det gives
    // the inverse, laid out row-major to match how the kernel reads it.
    return [A * invDet, D * invDet, G * invDet,
            B * invDet, E * invDet, H * invDet,
            C * invDet, F * invDet, I * invDet]
}

#endif
