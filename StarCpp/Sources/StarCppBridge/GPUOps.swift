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
          },
          { base, neighbours, neighbourCount, homographies, outlierThreshold, includeAll, dst in
              guard let backend = activeBackend, let base, let neighbours, let homographies, let dst,
                    neighbourCount > 0
              else { return false }
              return backend.alignedMerge(base: base, neighbours: neighbours,
                                          neighbourCount: Int(neighbourCount), homographies: homographies,
                                          outlierThreshold: outlierThreshold, includeAll: includeAll, dst: dst)
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
        // Separate again, gated by its own Config.useGPUForAKAZE flag — see
        // GPUOps_C.h's GPUAkazePyramidFunc doc comment.
        gpu_ops_set_akaze_pyramid_handler { img, soffset, levels, levelCount, stepCounts, tsteps,
                                            tstepsCount, kcontrastBase, outLt, outLsmooth in
            guard let backend = activeBackend, let img, let levels, let stepCounts,
                  let outLt, let outLsmooth else { return false }
            return backend.buildAkazePyramid(img: img, soffset: soffset, levels: levels,
                                             levelCount: Int(levelCount), stepCounts: stepCounts,
                                             tsteps: tsteps, tstepsCount: Int(tstepsCount),
                                             kcontrastBase: kcontrastBase,
                                             outLt: outLt, outLsmooth: outLsmooth)
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

    /// Bounds how many of this backend's entry points (warp, medianMerge, the
    /// two pyramid builders) can be inside Metal at once, across every caller.
    ///
    /// GPU_IMPLEMENTATION_GUIDE.md ยง4 says this outright — "The GPU is one
    /// resource shared by 18 concurrent frames. Serialise work through a
    /// single queue with bounded in-flight buffers, or you will move the
    /// memory-pressure problem from RAM to VRAM and gain nothing" — but no
    /// entry point here actually did it: `NativeWork.concurrencyLimit` bounds
    /// how many *native calls* run at once (it exists to protect the Swift
    /// cooperative thread pool, not the GPU), which on this 18-core iMac Pro
    /// is ~14 by design. Every one of those, hitting medianMerge at 42MP with
    /// up to 17 sources, allocates and `memcpy`s a multi-hundred-MB-to-multi-GB
    /// `.storageModeShared` buffer and pushes it across PCIe — this machine's
    /// Vega 64 has no unified memory, so that crossing is real, measured
    /// (GPU_IMPLEMENTATION_GUIDE.md: 11.5 GB/s shared→private) traffic, not a
    /// pointer handoff. 14-way concurrent multi-GB allocation-and-transfer
    /// against one discrete GPU is exactly the "flail" a real run reported —
    /// severe slowdown and, per the same report, a plausible contributor to a
    /// crash (this bypasses `MemoryMonitor`'s reservation ledger entirely, so
    /// its multi-GB transient spikes are invisible to the accounting that
    /// gates admission elsewhere).
    ///
    /// Re-measured after `alignedMerge` (below) replaced `ia_align_and_median_merge`'s
    /// old per-neighbour warp/coverage/merge shape with one batched call per
    /// frame — see GPU_MERGE_BATCHING_FIX.md. The old shape made up to 17
    /// separate round-trips through this semaphore per frame (`warpInto` +
    /// `warpCoverage` x 8 neighbours, plus one merge); the batched replacement
    /// makes exactly one.
    ///
    /// Re-measured directly with `GPUOpsConcurrencyStressTests.
    /// testRealisticAlignedMergeThroughputAtConcurrency` (18 concurrent 42MP
    /// frames x 8 neighbours each) at several values, GPU/CPU wall-clock ratio
    /// (> 1 is GPU slower, the thing this whole fix is about):
    ///
    /// | value | ratio |
    /// |---|---|
    /// | 2 (the old, pre-batching value) | ~1.21-1.30 |
    /// | 4 | ~1.03 |
    /// | 6 | ~1.03 |
    /// | 8 | ~0.98-0.99 |
    ///
    /// 8 is the first value that measured GPU as (slightly) FASTER than CPU at
    /// this concurrency, consistently across repeated runs, and also happens to
    /// match `1 + neighbourCount` for star's own default 8-neighbour aligned
    /// merge — "one merge's worth of frames' GPU work in flight" is a more
    /// natural bound for the new one-round-trip-per-frame shape than the old
    /// value's "two small calls can overlap." It was not pushed higher: gains
    /// past 8 were not measured (diminishing returns were already visible
    /// between 4 and 6), and higher values raise exactly the concurrent-
    /// multi-GB-transfer exposure this semaphore exists to bound in the first
    /// place (see the note below on why this GPU has no unified-memory fast
    /// path) — a value that only helps a synthetic benchmark, never validated
    /// against a real multi-hundred-frame run, is not worth that risk.
    /// `GPUOpsConcurrencyStressTests.testManyConcurrentMediumFrameMergesCompleteWithoutHangingOrCrashing`
    /// (the plain, un-aligned `medianMergeImage` case) still finishes 18
    /// concurrent merges in about the same ~1.5s at this value as it did at 2.
    ///
    /// This machine's Vega 64 still has no unified memory (see the paragraph
    /// above) — a real pointer handoff for an Apple Silicon GPU is real PCIe
    /// traffic here — so this still bounds actual hardware contention, not a
    /// number picked in a vacuum. Re-measure again if this backend ever
    /// targets a GPU with unified memory, or if `alignedMerge`'s own buffer
    /// strategy changes.
    private let gpuSlots = DispatchSemaphore(value: 8)

    /// Runs `body` inside `gpuSlots`. Every public entry point below must go
    /// through this rather than calling into Metal directly.
    private func withGPUSlot<T>(_ body: () -> T) -> T {
        gpuSlots.wait()
        defer { gpuSlots.signal() }
        return body()
    }
    let warpU8: MTLComputePipelineState
    let warpU16: MTLComputePipelineState
    let warpAndCoverageU8: MTLComputePipelineState
    let warpAndCoverageU16: MTLComputePipelineState
    let medianU8: MTLComputePipelineState
    let medianU16: MTLComputePipelineState
    let downsampleNearest2xF32: MTLComputePipelineState
    let downsampleArea2xF32: MTLComputePipelineState
    let scharrXF32: MTLComputePipelineState
    let scharrYF32: MTLComputePipelineState
    let pmG2F32: MTLComputePipelineState
    let fedStepF32: MTLComputePipelineState
    let addInPlaceF32: MTLComputePipelineState

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
            self.warpAndCoverageU8 = try pipeline("warp_and_coverage_u8")
            self.warpAndCoverageU16 = try pipeline("warp_and_coverage_u16")
            self.medianU8 = try pipeline("median_merge_u8")
            self.medianU16 = try pipeline("median_merge_u16")
            self.downsampleNearest2xF32 = try pipeline("downsample_nearest_2x_f32")
            self.downsampleArea2xF32 = try pipeline("downsample_area_2x_f32")
            self.scharrXF32 = try pipeline("scharr_x_f32")
            self.scharrYF32 = try pipeline("scharr_y_f32")
            self.pmG2F32 = try pipeline("pm_g2_f32")
            self.fedStepF32 = try pipeline("fed_step_f32")
            self.addInPlaceF32 = try pipeline("add_in_place_f32")
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
        withGPUSlot { warpImpl(src: src, homography: homography, dst: dst) }
    }

    private func warpImpl(src: MatWrapperRef, homography: UnsafePointer<Double>, dst: MatWrapperRef) -> Bool {
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
        withGPUSlot {
            medianMergeImpl(sources: sources, count: count, misses: misses,
                            outlierThreshold: outlierThreshold, includeAll: includeAll, dst: dst)
        }
    }

    private func medianMergeImpl(sources: UnsafeMutablePointer<MatWrapperRef?>, count: Int,
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

        // Allocate the Metal buffers first and `memcpy` straight into their
        // `.contents()`, rather than packing into a Swift `[UInt8]` and handing
        // that to `makeBuffer(bytes:...)` (which copies it again itself). At up
        // to 17 sources and 42MP that second copy was a real multi-hundred-MB
        // duplicate allocation and pass, on top of the one PCIe crossing this
        // data already has to make to reach a discrete GPU's `.storageModeShared`
        // memory — see `gpuSlots`'s doc comment for the concurrent-frame cost of
        // that crossing.
        let rowBytes = cols * channels * bytesPerComponent
        guard let srcBuf = device.makeBuffer(length: rowBytes * rows * count, options: .storageModeShared),
              let missesBuf = device.makeBuffer(length: max(1, cols * rows), options: .storageModeShared),
              let dstBuf = device.makeBuffer(length: rowBytes * rows, options: .storageModeShared),
              let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder()
        else { return false }

        let srcBase = srcBuf.contents()
        for i in 0..<count {
            guard let s = sources[i],
                  Int(mat_wrapper_rows(s)) == rows, Int(mat_wrapper_cols(s)) == cols,
                  Int(mat_wrapper_channels(s)) == channels,
                  mat_wrapper_bits_per_component(s) == bitsPerComponent,
                  let ptr = mat_wrapper_data_ptr(s)
            else { return false }
            let step = Int(mat_wrapper_step(s))
            let base = srcBase.advanced(by: i * rowBytes * rows)
            for y in 0..<rows {
                memcpy(base.advanced(by: y * rowBytes), ptr.advanced(by: y * step), rowBytes)
            }
        }

        // includeAll never allocates a coverage plane on the C++ side (misses ==
        // nullptr), and the kernel is told so via `includeAllFlag` rather than by
        // inferring it from a null buffer — Metal has no null-buffer convention as
        // clean as C's, so a real (tiny, unread, zeroed) buffer stands in.
        memset(missesBuf.contents(), 0, max(1, cols * rows))
        if let misses {
            guard Int(mat_wrapper_rows(misses)) == rows, Int(mat_wrapper_cols(misses)) == cols,
                  let mptr = mat_wrapper_data_ptr(misses)
            else { return false }
            let mstep = Int(mat_wrapper_step(misses))
            let missesBase = missesBuf.contents()
            for y in 0..<rows {
                memcpy(missesBase.advanced(by: y * cols), mptr.advanced(by: y * mstep), cols)
            }
        }

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

    // MARK: - Aligned merge (batched)

    /// One frame's whole aligned merge — every neighbour's warp plus the final
    /// sigma-clipped median merge — on ONE `MTLCommandBuffer`, replacing what
    /// `ia_align_and_median_merge` (ImageAligner.cpp) used to do as
    /// `neighbourCount * 2 + 1` separate GPU round-trips (`warp`/`warpCoverage`
    /// per neighbour via the plain `warp` entry point above, then one call to
    /// `medianMerge`). See GPU_MERGE_BATCHING_FIX.md for the measurements that
    /// motivated this: each round-trip's fixed cost (a fresh
    /// `.storageModeShared` allocation, a command buffer, a synchronous
    /// `waitUntilCompleted`, a `memcpy` back out) measured larger than the GPU
    /// kernel work itself, so paying it 17 times per frame was a 2.35x
    /// regression against the CPU path at real 42MP/8-neighbour scale — this
    /// is modelled on `buildSiftPyramid`/`buildAkazePyramid` (one command
    /// buffer, one `waitUntilCompleted`), not on `warp`/`medianMergeImpl`.
    ///
    /// Two things are fused beyond just "one command buffer," both worth
    /// calling out:
    ///
    /// 1. Every source (`base` plus every warped neighbour) is written
    ///    directly into ONE shared, tightly-packed buffer at the exact layout
    ///    `median_merge_generic` (see `medianMerge` above / the shader source
    ///    below) already expects — `sources[i*width*height*channels + ...]`,
    ///    no per-source step. The base is `memcpy`'d in (respecting its own,
    ///    possibly padded, step); every neighbour's warp dispatch targets its
    ///    slot directly via a byte-offset `MTLBuffer` binding, so there is no
    ///    intermediate per-neighbour buffer this function has to allocate,
    ///    warp into, then re-pack for the merge the way `medianMergeImpl` (a
    ///    standalone call, receiving already-separate source Mats) has to.
    ///
    /// 2. `warpCoverage`'s old redundant second warp call — running the whole
    ///    kernel again on an all-255 probe image purely to learn which
    ///    destination pixels a warp reached — is gone entirely here. The
    ///    `warp_and_coverage_*` kernels below write that as a second output
    ///    of the SAME dispatch that produces the real warped image: every
    ///    pixel this warp does not reach is written as an explicit zero (this
    ///    function does not pre-zero neighbour slots the way `warp` pre-zeros
    ///    `dst` — the kernel's every code path now writes every pixel, real
    ///    value or zero) and increments a shared per-pixel miss count, the
    ///    exact `CoverageMisses` contract `medianMergeTyped` depends on
    ///    (ImageAligner.cpp). This is safe as a plain, non-atomic `+= 1`
    ///    because every neighbour's dispatch runs in the SAME
    ///    `MTLComputeCommandEncoder`, in encoding order, by Metal's default
    ///    serial dispatch semantics — the exact guarantee `buildAkazePyramid`
    ///    already relies on for its own `fed_step_f32` -> `add_in_place_f32`
    ///    read-after-write chain, just applied across dispatches instead of
    ///    within a level's own step loop.
    ///
    /// 3. Getting each neighbour's raw pixels onto the GPU at all turned out to
    ///    be a second, independent cost batching alone does not touch — see the
    ///    `.storageModeManaged` and `rawBuf`/`concurrentPerform` comments below
    ///    for what was measured and what it bought. Read GPU_MERGE_BATCHING_FIX.md
    ///    for the honest bottom line: batching plus both of those changes took
    ///    this function's own GPU/CPU ratio from a documented 2.35x regression
    ///    down to roughly 1.3x at real 42MP/8-neighbour concurrency — a real,
    ///    substantial improvement, but not (yet) the "GPU is faster" crossover
    ///    the original investigation hoped batching alone would produce. The
    ///    remaining gap is memory bandwidth, not round-trip count: this
    ///    function's own timing breakdown showed getting ~750MB of source
    ///    pixels resident and the ~84MB result back out costs more, on this
    ///    machine, than the CPU path's entire warp-and-merge computation.
    ///
    /// The streaming/spill path (`MergeSpiller`, ImageAligner.cpp) deliberately
    /// does NOT call this — it holds only one warp resident at a time by
    /// design, which a single command buffer holding every neighbour's warp at
    /// once works directly against. It keeps calling `warp`/`warpCoverage`
    /// above, one round-trip at a time, exactly as before.
    ///
    /// `neighbours`/`homographies` are parallel arrays: neighbour i's forward
    /// (src -> dst) homography is `homographies[i*9 ..< i*9+9]`, row-major,
    /// the same convention `warp` takes — this inverts each one the same way
    /// `warpImpl` does. Every neighbour must already match `base`'s rows/cols/
    /// type; the caller (`tryGPUAlignedMerge`, ImageAligner.cpp) guarantees
    /// this by construction rather than this function silently dropping a
    /// mismatched one, since a dropped neighbour here would make the GPU and
    /// CPU paths disagree about which neighbours contributed.
    func alignedMerge(base: MatWrapperRef, neighbours: UnsafeMutablePointer<MatWrapperRef?>,
                      neighbourCount: Int, homographies: UnsafePointer<Double>,
                      outlierThreshold: Double, includeAll: Bool, dst: MatWrapperRef) -> Bool {
        withGPUSlot {
            alignedMergeImpl(base: base, neighbours: neighbours, neighbourCount: neighbourCount,
                             homographies: homographies, outlierThreshold: outlierThreshold,
                             includeAll: includeAll, dst: dst)
        }
    }

    private func alignedMergeImpl(base: MatWrapperRef, neighbours: UnsafeMutablePointer<MatWrapperRef?>,
                                  neighbourCount: Int, homographies: UnsafePointer<Double>,
                                  outlierThreshold: Double, includeAll: Bool, dst: MatWrapperRef) -> Bool {
        // count is base + every neighbour -- the same <= 17 cap medianMergeImpl
        // enforces, since this reuses that same median_merge_u8/u16 pipeline
        // unmodified over GPU-resident buffers.
        let count = neighbourCount + 1
        guard neighbourCount > 0, count <= 17 else { return false }

        let rows = Int(mat_wrapper_rows(base))
        let cols = Int(mat_wrapper_cols(base))
        let channels = Int(mat_wrapper_channels(base))
        let bitsPerComponent = mat_wrapper_bits_per_component(base)
        guard rows > 0, cols > 0, channels >= 1, channels <= 4,
              rows == Int(mat_wrapper_rows(dst)), cols == Int(mat_wrapper_cols(dst)),
              channels == Int(mat_wrapper_channels(dst)),
              bitsPerComponent == mat_wrapper_bits_per_component(dst)
        else { return false }

        let bytesPerComponent: Int
        let warpPipeline: MTLComputePipelineState
        let mergePipeline: MTLComputePipelineState
        switch bitsPerComponent {
        case 8: bytesPerComponent = 1; warpPipeline = warpAndCoverageU8; mergePipeline = medianU8
        case 16: bytesPerComponent = 2; warpPipeline = warpAndCoverageU16; mergePipeline = medianU16
        default: return false
        }

        guard let basePtr = mat_wrapper_data_ptr(base) else { return false }
        let baseStepBytes = Int(mat_wrapper_step(base))
        // Tightly packed -- see this function's doc comment point 1. Every
        // neighbour's warp dispatch below writes directly at this layout, so
        // (unlike medianMergeImpl) there is no separate re-pack pass.
        let rowBytes = cols * channels * bytesPerComponent
        // Every neighbour's warp dispatch binds `sourcesBuf` at a per-slot BYTE
        // offset (`(i+1) * rowBytes * rows`, below) rather than the zero offset
        // every other GPU entry point in this file uses -- Metal requires
        // `setBuffer(_:offset:index:)` offsets to be 4-byte aligned, which a
        // tightly-packed row is not guaranteed to be for every channel/depth
        // combination (e.g. an odd-width single-channel 8-bit frame). Real
        // frames in this codebase are always even-width 16-bit, where this
        // guard never fires; it exists so an unusual input falls back to the
        // CPU path instead of risking undefined GPU behaviour.
        guard rowBytes % 4 == 0 else { return false }

        // `.storageModeManaged`, not `.shared`, for the two big buffers a whole
        // frame's worth of data moves through (`sourcesBuf`, `dstBuf`) -- unlike
        // `warp`/`medianMergeImpl` above, which pay one small `.shared` transfer
        // per call and were never the thing measured slow. Measured directly:
        // switching just these two buffers (plus `missesBuf`, below) from
        // `.shared` to `.managed` cut this function's own SOLO (no concurrency,
        // so not a `gpuSlots` question) GPU/CPU ratio from 1.8x to 1.3x for one
        // 42MP/8-neighbour frame -- see GPU_MERGE_BATCHING_FIX.md for the
        // full before/after numbers this and the `rawBuf` change below produced
        // together. `.shared` memory on this discrete Vega has no
        // unified-memory fast path (see `gpuSlots`'s doc comment: PCIe, not a
        // pointer handoff), so a kernel reading/writing a `.shared` buffer pays
        // that PCIe cost on every access *during* the dispatch, not just at
        // transfer time -- and this function's buffers are hundreds of MB to
        // over a GB (`sourcesBuf` is `rowBytes * rows * count`, ~750MB at
        // 42MP/9 sources), read and written by nine dispatches each.
        // `.storageModeManaged` keeps the authoritative copy in VRAM once
        // transferred, exactly like `buildSiftPyramid`/`buildAkazePyramid`'s
        // textures (same reasoning, different resource type) -- the CPU-write
        // side needs `didModifyRange` after writing the base image in, and the
        // CPU-read side needs an explicit blit `synchronize` before reading
        // `dstBuf` back (both below); GPU-to-GPU visibility (a warp dispatch's
        // write, the merge dispatch's read) needs neither, since that ordering
        // is already guaranteed by this encoder's default serial dispatch order
        // regardless of storage mode. `missesBuf` is also `.managed`, for the
        // same reason -- at ~40MB (one byte per pixel at 42MP) it is not the
        // tiny plane its `.shared` counterpart in `medianMergeImpl` above is at
        // that function's much smaller call sizes, and every one of this
        // function's 9 dispatches (8 warps + the merge) touches all of it.
        // `hBuf` alone stays `.shared`: 9 floats, never read back by the CPU,
        // not worth the bookkeeping.
        guard let sourcesBuf = device.makeBuffer(length: rowBytes * rows * count, options: .storageModeManaged),
              let missesBuf = device.makeBuffer(length: max(1, cols * rows), options: .storageModeManaged),
              let dstBuf = device.makeBuffer(length: rowBytes * rows, options: .storageModeManaged),
              let cmdBuf = queue.makeCommandBuffer()
        else { return false }

        // Slot 0 is always the base image -- it is never warped, so it is the
        // only slot filled from the CPU side rather than by a dispatch, copied
        // row by row to respect its own (possibly padded) step. `didModifyRange`
        // tells Metal about this CPU-side write so the GPU's later read (inside
        // the merge dispatch) sees it -- required for `.storageModeManaged`,
        // unlike the `.shared` buffers elsewhere in this file.
        let sourcesBase = sourcesBuf.contents()
        for y in 0..<rows {
            memcpy(sourcesBase.advanced(by: y * rowBytes), basePtr.advanced(by: y * baseStepBytes), rowBytes)
        }
        sourcesBuf.didModifyRange(0..<(rowBytes * rows))
        // Always zeroed, including under includeAll (which never reads it) --
        // matching medianMergeImpl's own unconditional memset, for the same
        // reason: one code path regardless of includeAll is simpler than two.
        // `didModifyRange` again, for the same reason as `sourcesBuf` above.
        let missesLength = max(1, cols * rows)
        memset(missesBuf.contents(), 0, missesLength)
        missesBuf.didModifyRange(0..<missesLength)

        var width = Int32(cols), height = Int32(rows), chans = Int32(channels)

        // Every neighbour's raw (still-unwarped) pixels go into ONE buffer
        // instead of one `device.makeBuffer(bytes:...)` allocation per
        // neighbour (what an earlier version of this function did, and what
        // `warpImpl` above still does for its own single-neighbour case) --
        // allocated once here and filled by explicit `memcpy`s below, one per
        // neighbour, run concurrently. Measured: neither choice of allocation
        // API was the point -- a single-threaded copy of 8 neighbours' ~84MB
        // each (672MB total) cost about the same (~0.33-0.4s) whether the
        // destination was `makeBuffer(bytes:...)`, this buffer's `.contents()`,
        // or a plain `malloc`'d region, which means the cost is ordinary
        // single-core memory bandwidth on this machine moving *this machine's*
        // source data, not anything about Metal or GPU-visible memory. See the
        // `concurrentPerform` call below for what this bought once spread
        // across cores instead.
        //
        // Neighbours are validated (just above) to share base's rows/cols/
        // channels/bits, but not necessarily its row step -- an unpadded
        // OpenCV Mat of that shape always would, but this does not assume it,
        // so each neighbour's own step sizes its own slot.
        // `nonisolated(unsafe)`: mutated only by the sequential validation loop
        // just below, then only read (at disjoint indices, one per iteration)
        // from the `concurrentPerform` closure further down -- safe by
        // construction, but the compiler cannot see that a `DispatchQueue.
        // concurrentPerform` call is synchronous and each iteration touches a
        // different index.
        nonisolated(unsafe) var neighbourStepsBytes = [Int](repeating: 0, count: neighbourCount)
        nonisolated(unsafe) var neighbourOffsets = [Int](repeating: 0, count: neighbourCount)
        nonisolated(unsafe) var neighbourPtrs = [UnsafeRawPointer?](repeating: nil, count: neighbourCount)
        var rawTotal = 0
        for i in 0..<neighbourCount {
            guard let neighbour = neighbours[i] else { return false }
            guard Int(mat_wrapper_rows(neighbour)) == rows, Int(mat_wrapper_cols(neighbour)) == cols,
                  Int(mat_wrapper_channels(neighbour)) == channels,
                  mat_wrapper_bits_per_component(neighbour) == bitsPerComponent,
                  let neighbourPtr = mat_wrapper_data_ptr(neighbour)
            else { return false }
            let neighbourStepBytes = Int(mat_wrapper_step(neighbour))
            // Same 4-byte offset-alignment requirement as `rowBytes` above --
            // this becomes a `setBuffer(_:offset:index:)` offset into `rawBuf`
            // below.
            guard neighbourStepBytes % bytesPerComponent == 0, neighbourStepBytes % 4 == 0
            else { return false }
            neighbourStepsBytes[i] = neighbourStepBytes
            neighbourOffsets[i] = rawTotal
            neighbourPtrs[i] = neighbourPtr
            rawTotal += neighbourStepBytes * rows
        }
        guard let rawBuf = device.makeBuffer(length: max(1, rawTotal), options: .storageModeShared)
        else { return false }
        // Each neighbour's copy is independent (disjoint source, disjoint
        // destination range), so this spreads it across cores instead of
        // paying the ~0.35s single-threaded cost (see above) on the one thread
        // already doing the rest of this function's work. Measured gain was
        // modest (roughly 1.2x, not close to core-count-proportional) --
        // consistent with the single-threaded number already being close to
        // this machine's aggregate memory bandwidth for a copy this size,
        // which more threads reading/writing the same memory subsystem cannot
        // multiply. Kept anyway: it is a real, free reduction on the thread
        // that matters (the one blocking on `waitUntilCompleted` next), not a
        // regression risk, and costs nothing when `neighbourCount` is small.
        nonisolated(unsafe) let rawBase = rawBuf.contents()
        DispatchQueue.concurrentPerform(iterations: neighbourCount) { i in
            let step = neighbourStepsBytes[i]
            memcpy(rawBase.advanced(by: neighbourOffsets[i]), neighbourPtrs[i]!, step * rows)
        }

        // Every neighbour's warp+coverage dispatch goes on ONE encoder -- see
        // this function's doc comment point 2 for why the plain, non-atomic
        // `misses` increment inside each dispatch is safe across this loop.
        guard let warpEncoder = cmdBuf.makeComputeCommandEncoder() else { return false }
        for i in 0..<neighbourCount {
            guard let hInv = invert3x3(homographies + i * 9) else { return false }
            let srcStepElems = Int32(neighbourStepsBytes[i] / bytesPerComponent)
            var dstStep = Int32(cols * channels)   // tightly packed destination slot
            var hInvFloat = hInv.map { Float($0) }

            guard let hBuf = device.makeBuffer(bytes: &hInvFloat, length: 9 * MemoryLayout<Float>.stride,
                                               options: .storageModeShared)
            else { return false }

            var srcStep = srcStepElems

            warpEncoder.setComputePipelineState(warpPipeline)
            warpEncoder.setBuffer(rawBuf, offset: neighbourOffsets[i], index: 0)
            // Byte offset into the shared sources buffer: slot 0 is the base,
            // so neighbour i lands at slot i+1.
            warpEncoder.setBuffer(sourcesBuf, offset: (i + 1) * rowBytes * rows, index: 1)
            warpEncoder.setBuffer(hBuf, offset: 0, index: 2)
            warpEncoder.setBytes(&width, length: MemoryLayout<Int32>.size, index: 3)
            warpEncoder.setBytes(&height, length: MemoryLayout<Int32>.size, index: 4)
            warpEncoder.setBytes(&chans, length: MemoryLayout<Int32>.size, index: 5)
            warpEncoder.setBytes(&srcStep, length: MemoryLayout<Int32>.size, index: 6)
            warpEncoder.setBytes(&dstStep, length: MemoryLayout<Int32>.size, index: 7)
            warpEncoder.setBuffer(missesBuf, offset: 0, index: 8)

            dispatch(encoder: warpEncoder, pipeline: warpPipeline, width: cols, height: rows)
        }
        warpEncoder.endEncoding()

        // The final merge, reading directly from the now GPU-resident sources
        // and misses buffers this encoder's dispatches just filled -- no CPU
        // round trip in between. Same pipeline, same buffer layout, as the
        // standalone `medianMerge` above.
        guard let mergeEncoder = cmdBuf.makeComputeCommandEncoder() else { return false }
        var sourceCount = Int32(count)
        var threshold = Float(outlierThreshold)
        var includeAllFlag: Int32 = includeAll ? 1 : 0
        mergeEncoder.setComputePipelineState(mergePipeline)
        mergeEncoder.setBuffer(sourcesBuf, offset: 0, index: 0)
        mergeEncoder.setBuffer(missesBuf, offset: 0, index: 1)
        mergeEncoder.setBuffer(dstBuf, offset: 0, index: 2)
        mergeEncoder.setBytes(&width, length: MemoryLayout<Int32>.size, index: 3)
        mergeEncoder.setBytes(&height, length: MemoryLayout<Int32>.size, index: 4)
        mergeEncoder.setBytes(&chans, length: MemoryLayout<Int32>.size, index: 5)
        mergeEncoder.setBytes(&sourceCount, length: MemoryLayout<Int32>.size, index: 6)
        mergeEncoder.setBytes(&threshold, length: MemoryLayout<Float>.size, index: 7)
        mergeEncoder.setBytes(&includeAllFlag, length: MemoryLayout<Int32>.size, index: 8)
        dispatch(encoder: mergeEncoder, pipeline: mergePipeline, width: cols, height: rows)
        mergeEncoder.endEncoding()

        // `.storageModeManaged` needs an explicit GPU->CPU sync before a
        // CPU-side read (here, the readback loop below) sees what the GPU
        // wrote -- same requirement, same fix, as buildSiftPyramid/
        // buildAkazePyramid's own blit-encoder `synchronize` before their
        // final readback.
        guard let syncEncoder = cmdBuf.makeBlitCommandEncoder() else { return false }
        syncEncoder.synchronize(resource: dstBuf)
        syncEncoder.endEncoding()

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
        withGPUSlot {
            buildSiftPyramidImpl(base: base, doubleImageSize: doubleImageSize, sigma: sigma,
                                 nOctaves: nOctaves, nOctaveLayers: nOctaveLayers, outPyramid: outPyramid)
        }
    }

    private func buildSiftPyramidImpl(base: MatWrapperRef, doubleImageSize: Bool, sigma: Double,
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

    // MARK: - AKAZE nonlinear diffusion pyramid

    /// Builds the nonlinear diffusion scale-space pyramid
    /// `akazeDetectAndComputeGPU` (AKAZEDetector.cpp) needs — see
    /// `GPUAkazePyramidFunc` in GPUOps_C.h for the exact contract. Every
    /// level's Gaussian blur uses `MPSImageGaussianBlur` (as `buildSiftPyramid`
    /// does), the 2x octave halving is `cv::INTER_AREA`'s exact box-filter
    /// average (a custom kernel — MPS has no box-average filter), the Scharr
    /// derivatives and Perona-Malik G2 diffusivity are small custom kernels,
    /// and the FED explicit-diffusion steps are a direct port of
    /// `nldStepScalar` (AKAZEDetector.cpp) onto textures, including its literal
    /// four-corner special case.
    ///
    /// Like `buildSiftPyramid`, every texture is `.storageModeManaged` with an
    /// explicit blit-encoder `synchronize` before the final readback — see that
    /// function's doc comment for the measured reason (a `.shared` texture a
    /// compute kernel writes reads back as zero on this Vega).
    ///
    /// The Scharr kernel here uses clamp-to-edge rather than `cv::Scharr`'s
    /// actual `BORDER_DEFAULT` (reflect-101): a one-pixel-wide simplification
    /// that only affects the diffusivity input, itself already an approximate,
    /// behaviorally-validated stand-in for OpenCV's own boundary handling —
    /// not worth a second boundary-mode kernel variant for a single row/column
    /// of pixels deep inside the border `Find_Scale_Space_Extrema` excludes.
    func buildAkazePyramid(img: MatWrapperRef, soffset: Float,
                          levels: UnsafePointer<GPUAkazeLevelInfo>, levelCount: Int,
                          stepCounts: UnsafePointer<Int32>, tsteps: UnsafePointer<Float>?,
                          tstepsCount: Int, kcontrastBase: Float,
                          outLt: UnsafeMutablePointer<MatWrapperRef?>,
                          outLsmooth: UnsafeMutablePointer<MatWrapperRef?>) -> Bool {
        withGPUSlot {
            buildAkazePyramidImpl(img: img, soffset: soffset, levels: levels, levelCount: levelCount,
                                  stepCounts: stepCounts, tsteps: tsteps, tstepsCount: tstepsCount,
                                  kcontrastBase: kcontrastBase, outLt: outLt, outLsmooth: outLsmooth)
        }
    }

    private func buildAkazePyramidImpl(img: MatWrapperRef, soffset: Float,
                                       levels: UnsafePointer<GPUAkazeLevelInfo>, levelCount: Int,
                                       stepCounts: UnsafePointer<Int32>, tsteps: UnsafePointer<Float>?,
                                       tstepsCount: Int, kcontrastBase: Float,
                                       outLt: UnsafeMutablePointer<MatWrapperRef?>,
                                       outLsmooth: UnsafeMutablePointer<MatWrapperRef?>) -> Bool {
        guard levelCount > 1 else { return false }  // the trivial 1-level case never reaches here
        guard mat_wrapper_bits_per_component(img) == 32, mat_wrapper_channels(img) == 1 else {
            return false  // AKAZEDetector.cpp always hands this CV_32FC1; anything else is a caller bug
        }
        let imgRows = Int(mat_wrapper_rows(img)), imgCols = Int(mat_wrapper_cols(img))
        guard imgRows > 0, imgCols > 0, let imgPtr = mat_wrapper_data_ptr(img) else { return false }
        let imgStepBytes = Int(mat_wrapper_step(img))

        guard let inputTexture = makeFloatTexture(width: imgCols, height: imgRows) else { return false }
        inputTexture.replace(region: MTLRegionMake2D(0, 0, imgCols, imgRows), mipmapLevel: 0,
                             withBytes: imgPtr, bytesPerRow: imgStepBytes)

        guard let cmdBuf = queue.makeCommandBuffer() else { return false }

        var ltTextures = [MTLTexture?](repeating: nil, count: levelCount)
        var lsmoothTextures = [MTLTexture?](repeating: nil, count: levelCount)

        // Level 0: a single blur by `soffset`, used as both Lt and Lsmooth —
        // matching create_nonlinear_scale_space's own
        // `evolution[0].Lsmooth.copyTo(evolution[0].Lt)`.
        guard let level0 = makeFloatTexture(width: imgCols, height: imgRows) else { return false }
        MPSImageGaussianBlur(device: device, sigma: soffset)
            .encode(commandBuffer: cmdBuf, sourceTexture: inputTexture, destinationTexture: level0)
        ltTextures[0] = level0
        lsmoothTextures[0] = level0

        var kcontrast = kcontrastBase
        var tstepOffset = 0
        let tstepsBuffer = tsteps.map { UnsafeBufferPointer(start: $0, count: tstepsCount) }

        for i in 1..<levelCount {
            let info = levels[i]
            let width = Int(info.width), height = Int(info.height)
            guard width > 0, height > 0 else { return false }

            // Halve (new octave) or copy (same octave) the previous level's Lt,
            // producing THIS level's pre-diffusion Lt — matching
            // create_nonlinear_scale_space's own branch.
            guard let prevLt = ltTextures[i - 1] else { return false }
            let levelLt: MTLTexture
            if info.newOctave != 0 {
                guard let halved = makeFloatTexture(width: width, height: height) else { return false }
                guard let encoder = cmdBuf.makeComputeCommandEncoder() else { return false }
                encoder.setComputePipelineState(downsampleArea2xF32)
                encoder.setTexture(prevLt, index: 0)
                encoder.setTexture(halved, index: 1)
                dispatch(encoder: encoder, pipeline: downsampleArea2xF32, width: width, height: height)
                encoder.endEncoding()
                levelLt = halved
                kcontrast *= 0.75
            } else {
                guard let copy = makeFloatTexture(width: width, height: height),
                      let blit = cmdBuf.makeBlitCommandEncoder()
                else { return false }
                blit.copy(from: prevLt, sourceSlice: 0, sourceLevel: 0,
                         sourceOrigin: MTLOriginMake(0, 0, 0), sourceSize: MTLSizeMake(width, height, 1),
                         to: copy, destinationSlice: 0, destinationLevel: 0,
                         destinationOrigin: MTLOriginMake(0, 0, 0))
                blit.endEncoding()
                levelLt = copy
            }

            // Lsmooth: the fixed 5x5-equivalent, sigma=1 blur of the
            // pre-diffusion Lt, used for this level's derivatives now and by
            // Compute_Determinant_Hessian_Response later.
            guard let smooth = makeFloatTexture(width: width, height: height) else { return false }
            MPSImageGaussianBlur(device: device, sigma: 1.0)
                .encode(commandBuffer: cmdBuf, sourceTexture: levelLt, destinationTexture: smooth)

            guard let lx = makeFloatTexture(width: width, height: height),
                  let ly = makeFloatTexture(width: width, height: height),
                  let flow = makeFloatTexture(width: width, height: height)
            else { return false }
            guard let derivEncoder = cmdBuf.makeComputeCommandEncoder() else { return false }
            derivEncoder.setComputePipelineState(scharrXF32)
            derivEncoder.setTexture(smooth, index: 0)
            derivEncoder.setTexture(lx, index: 1)
            dispatch(encoder: derivEncoder, pipeline: scharrXF32, width: width, height: height)
            derivEncoder.setComputePipelineState(scharrYF32)
            derivEncoder.setTexture(smooth, index: 0)
            derivEncoder.setTexture(ly, index: 1)
            dispatch(encoder: derivEncoder, pipeline: scharrYF32, width: width, height: height)
            var k = kcontrast
            derivEncoder.setComputePipelineState(pmG2F32)
            derivEncoder.setTexture(lx, index: 0)
            derivEncoder.setTexture(ly, index: 1)
            derivEncoder.setTexture(flow, index: 2)
            derivEncoder.setBytes(&k, length: MemoryLayout<Float>.size, index: 0)
            dispatch(encoder: derivEncoder, pipeline: pmG2F32, width: width, height: height)
            derivEncoder.endEncoding()

            // FED steps: each computes Lstep into its own texture, then adds
            // it into `current` in place (add_in_place_f32) — safe because the
            // read (fed_step_f32, into a separate destination) always
            // completes, and is encoded, before the in-place add that follows
            // it, so the next step's fed_step_f32 always sees a fully updated
            // `current`.
            let current = levelLt
            let stepCount = Int(stepCounts[i])
            guard stepCount == 0 || tstepsBuffer != nil else { return false }
            for s in 0..<stepCount {
                guard let lstep = makeFloatTexture(width: width, height: height),
                      let stepEncoder = cmdBuf.makeComputeCommandEncoder()
                else { return false }
                var stepSize = tstepsBuffer![tstepOffset + s]
                stepEncoder.setComputePipelineState(fedStepF32)
                stepEncoder.setTexture(current, index: 0)
                stepEncoder.setTexture(flow, index: 1)
                stepEncoder.setTexture(lstep, index: 2)
                stepEncoder.setBytes(&stepSize, length: MemoryLayout<Float>.size, index: 0)
                dispatch(encoder: stepEncoder, pipeline: fedStepF32, width: width, height: height)

                stepEncoder.setComputePipelineState(addInPlaceF32)
                stepEncoder.setTexture(current, index: 0)
                stepEncoder.setTexture(lstep, index: 1)
                dispatch(encoder: stepEncoder, pipeline: addInPlaceF32, width: width, height: height)
                stepEncoder.endEncoding()
            }
            tstepOffset += stepCount

            ltTextures[i] = current
            lsmoothTextures[i] = smooth
        }

        guard let syncEncoder = cmdBuf.makeBlitCommandEncoder() else { return false }
        for texture in ltTextures + lsmoothTextures {
            guard let texture else { return false }
            syncEncoder.synchronize(resource: texture)
        }
        syncEncoder.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        guard cmdBuf.status == .completed else { return false }

        for i in 0..<levelCount {
            guard let ltTex = ltTextures[i], let smoothTex = lsmoothTextures[i],
                  let ltMat = matWrapper(fromFloatTexture: ltTex),
                  let smoothMat = matWrapper(fromFloatTexture: smoothTex)
            else { return false }
            outLt[i] = ltMat
            outLsmooth[i] = smoothMat
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

    // Same warp as warp_generic above, but also writes a coverage-misses
    // contribution as a second output of the SAME dispatch, instead of a caller
    // running the whole kernel again on a synthetic all-255 probe image
    // (warpCoverage, ImageAligner.cpp) -- see MetalGPUBackend.alignedMerge's doc
    // comment for why this is safe to accumulate with a plain, non-atomic `+= 1`
    // across the several dispatches (one per neighbour) that share `misses`.
    //
    // Unlike warp_generic, every code path here WRITES dst -- real value or an
    // explicit zero -- rather than leaving an unreached pixel untouched and
    // relying on the destination having been pre-zeroed. alignedMerge does not
    // pre-zero a neighbour's slot in the shared sources buffer, so this kernel's
    // full-grid coverage (every (x, y) in [0, width) x [0, height) is written by
    // exactly one thread, via the bounds check just below) is what keeps the
    // "zero means no data" invariant the merge depends on true.
    template <typename T, int MAXV>
    inline void warp_and_coverage_generic(device const T* src, device T* dst,
                                          device uchar* misses,
                                          constant float* hInv,
                                          int width, int height, int channels,
                                          int srcStep, int dstStep, uint2 gid)
    {
        if ((int)gid.x >= width || (int)gid.y >= height) return;

        size_t dstBase = (size_t)gid.y * (size_t)dstStep + (size_t)gid.x * (size_t)channels;
        size_t missIdx = (size_t)gid.y * (size_t)width + (size_t)gid.x;

        float x = float(gid.x), y = float(gid.y);
        float w = hInv[6] * x + hInv[7] * y + hInv[8];
        bool covered = fabs(w) >= 1e-12f;
        float sx = 0.0f, sy = 0.0f;
        if (covered) {
            sx = (hInv[0] * x + hInv[1] * y + hInv[2]) / w;
            sy = (hInv[3] * x + hInv[4] * y + hInv[5]) / w;
            covered = isfinite(sx) && isfinite(sy);
        }

        int ix = 0, iy = 0;
        float fx = 0.0f, fy = 0.0f;
        bool v00 = false, v10 = false, v01 = false, v11 = false;
        float w00 = 0.0f, w10 = 0.0f, w01 = 0.0f, w11 = 0.0f, wsum = 0.0f;

        if (covered) {
            ix = int(floor(sx));
            iy = int(floor(sy));
            fx = sx - float(ix);
            fy = sy - float(iy);

            // Same OpenCV INTER_TAB_SIZE fractional-position quantization as
            // warp_generic above -- see that function's doc comment.
            const float kTabSize = 32.0f;
            int fxi = int(round(fx * kTabSize));
            if (fxi >= int(kTabSize)) { fxi -= int(kTabSize); ix += 1; }
            int fyi = int(round(fy * kTabSize));
            if (fyi >= int(kTabSize)) { fyi -= int(kTabSize); iy += 1; }
            fx = float(fxi) / kTabSize;
            fy = float(fyi) / kTabSize;

            w00 = (1.0f - fx) * (1.0f - fy);
            w10 = fx * (1.0f - fy);
            w01 = (1.0f - fx) * fy;
            w11 = fx * fy;

            v00 = sample_valid(ix,     iy,     width, height);
            v10 = sample_valid(ix + 1, iy,     width, height);
            v01 = sample_valid(ix,     iy + 1, width, height);
            v11 = sample_valid(ix + 1, iy + 1, width, height);
            covered = v00 || v10 || v01 || v11;
            if (covered) {
                wsum = (v00 ? w00 : 0.0f) + (v10 ? w10 : 0.0f)
                     + (v01 ? w01 : 0.0f) + (v11 ? w11 : 0.0f);
                covered = wsum > 1e-6f;
            }
        }

        if (!covered) {
            for (int c = 0; c < channels; ++c) dst[dstBase + c] = T(0);
            misses[missIdx] = misses[missIdx] + 1;
            return;
        }

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

    kernel void warp_and_coverage_u8(device const uchar* src [[buffer(0)]],
                                     device uchar* dst [[buffer(1)]],
                                     constant float* hInv [[buffer(2)]],
                                     constant int& width [[buffer(3)]],
                                     constant int& height [[buffer(4)]],
                                     constant int& channels [[buffer(5)]],
                                     constant int& srcStep [[buffer(6)]],
                                     constant int& dstStep [[buffer(7)]],
                                     device uchar* misses [[buffer(8)]],
                                     uint2 gid [[thread_position_in_grid]])
    {
        warp_and_coverage_generic<uchar, 255>(src, dst, misses, hInv, width, height, channels,
                                              srcStep, dstStep, gid);
    }

    kernel void warp_and_coverage_u16(device const ushort* src [[buffer(0)]],
                                      device ushort* dst [[buffer(1)]],
                                      constant float* hInv [[buffer(2)]],
                                      constant int& width [[buffer(3)]],
                                      constant int& height [[buffer(4)]],
                                      constant int& channels [[buffer(5)]],
                                      constant int& srcStep [[buffer(6)]],
                                      constant int& dstStep [[buffer(7)]],
                                      device uchar* misses [[buffer(8)]],
                                      uint2 gid [[thread_position_in_grid]])
    {
        warp_and_coverage_generic<ushort, 65535>(src, dst, misses, hInv, width, height, channels,
                                                 srcStep, dstStep, gid);
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

    // Exact 2x box-average downsample, matching cv::resize(..., INTER_AREA)
    // for an exact integer scale factor -- AKAZEDetector.cpp's own octave
    // halving (create_nonlinear_scale_space's `if (e.octave > ...)` branch).
    kernel void downsample_area_2x_f32(texture2d<float, access::read> src [[texture(0)]],
                                       texture2d<float, access::write> dst [[texture(1)]],
                                       uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        uint2 s = gid * 2;
        float v00 = src.read(uint2(s.x,     s.y)).r;
        float v10 = src.read(uint2(s.x + 1, s.y)).r;
        float v01 = src.read(uint2(s.x,     s.y + 1)).r;
        float v11 = src.read(uint2(s.x + 1, s.y + 1)).r;
        dst.write(float4(0.25f * (v00 + v10 + v01 + v11), 0.0, 0.0, 0.0), gid);
    }

    // A clamp-to-edge helper for the 3x3 kernels below -- see buildAkazePyramid's
    // doc comment on why clamp stands in for cv::Scharr's actual BORDER_DEFAULT
    // (reflect-101) here.
    inline float read_clamped(texture2d<float, access::read> tex, int x, int y) {
        int w = int(tex.get_width()), h = int(tex.get_height());
        x = clamp(x, 0, w - 1);
        y = clamp(y, 0, h - 1);
        return tex.read(uint2(uint(x), uint(y))).r;
    }

    // 3x3 Scharr, matching cv::Scharr(src, dst, CV_32F, 1, 0, 1, 0, BORDER_DEFAULT):
    // Gx = [-3 0 3; -10 0 10; -3 0 3].
    kernel void scharr_x_f32(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        int x = int(gid.x), y = int(gid.y);
        float v = -3.0f * read_clamped(src, x - 1, y - 1) + 3.0f * read_clamped(src, x + 1, y - 1)
                - 10.0f * read_clamped(src, x - 1, y    ) + 10.0f * read_clamped(src, x + 1, y    )
                 - 3.0f * read_clamped(src, x - 1, y + 1) + 3.0f * read_clamped(src, x + 1, y + 1);
        dst.write(float4(v, 0.0, 0.0, 0.0), gid);
    }

    // 3x3 Scharr, Y direction: Gy = [-3 -10 -3; 0 0 0; 3 10 3].
    kernel void scharr_y_f32(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        int x = int(gid.x), y = int(gid.y);
        float v = -3.0f * read_clamped(src, x - 1, y - 1) - 10.0f * read_clamped(src, x, y - 1)
                 - 3.0f * read_clamped(src, x + 1, y - 1)
                 + 3.0f * read_clamped(src, x - 1, y + 1) + 10.0f * read_clamped(src, x, y + 1)
                 + 3.0f * read_clamped(src, x + 1, y + 1);
        dst.write(float4(v, 0.0, 0.0, 0.0), gid);
    }

    // Perona-Malik G2 diffusivity, matching pm_g2 (AKAZEDetector.cpp):
    // 1 / (1 + (Lx^2 + Ly^2) / k^2).
    kernel void pm_g2_f32(texture2d<float, access::read> lx [[texture(0)]],
                          texture2d<float, access::read> ly [[texture(1)]],
                          texture2d<float, access::write> dst [[texture(2)]],
                          constant float& k [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float x = lx.read(gid).r, y = ly.read(gid).r;
        float v = 1.0f / (1.0f + (x * x + y * y) / (k * k));
        dst.write(float4(v, 0.0, 0.0, 0.0), gid);
    }

    // One Fast Explicit Diffusion step, a direct port of nldStepScalar
    // (AKAZEDetector.cpp): a five-point forward-Euler stencil with Neumann
    // (no-flux) boundaries -- a border pixel omits the term reaching outside
    // the image -- and AKAZE's own literal four-corner special case (frozen at
    // exactly 0, not a 2-term partial stencil; see AKAZEDetector.cpp's comment
    // on nldStepScalar for why this is replicated rather than "improved").
    kernel void fed_step_f32(texture2d<float, access::read> lt [[texture(0)]],
                             texture2d<float, access::read> lf [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             constant float& stepSize [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]])
    {
        int w = int(lt.get_width()), h = int(lt.get_height());
        int x = int(gid.x), y = int(gid.y);
        if (x >= w || y >= h) return;

        bool topOrBottomRow = (y == 0 || y == h - 1);
        if (topOrBottomRow && (x == 0 || x == w - 1)) {
            dst.write(float4(0.0, 0.0, 0.0, 0.0), gid);
            return;
        }

        float ltC = lt.read(uint2(x, y)).r;
        float lfC = lf.read(uint2(x, y)).r;
        float acc = 0.0f;
        if (x < w - 1) {
            float ltR = lt.read(uint2(x + 1, y)).r, lfR = lf.read(uint2(x + 1, y)).r;
            acc += (lfC + lfR) * (ltR - ltC);
        }
        if (x > 0) {
            float ltL = lt.read(uint2(x - 1, y)).r, lfL = lf.read(uint2(x - 1, y)).r;
            acc += (lfC + lfL) * (ltL - ltC);
        }
        if (y < h - 1) {
            float ltB = lt.read(uint2(x, y + 1)).r, lfB = lf.read(uint2(x, y + 1)).r;
            acc += (lfC + lfB) * (ltB - ltC);
        }
        if (y > 0) {
            float ltA = lt.read(uint2(x, y - 1)).r, lfA = lf.read(uint2(x, y - 1)).r;
            acc += (lfC + lfA) * (ltA - ltC);
        }
        dst.write(float4(acc * stepSize, 0.0, 0.0, 0.0), gid);
    }

    // In-place elementwise add (Lt += Lstep) -- safe as read_write since every
    // thread only ever touches its own pixel, with no neighbour dependency.
    kernel void add_in_place_f32(texture2d<float, access::read_write> lt [[texture(0)]],
                                 texture2d<float, access::read> lstep [[texture(1)]],
                                 uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= lt.get_width() || gid.y >= lt.get_height()) return;
        float v = lt.read(gid).r + lstep.read(gid).r;
        lt.write(float4(v, 0.0, 0.0, 0.0), gid);
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
