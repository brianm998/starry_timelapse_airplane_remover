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

public enum GPUOps {

    /// Bounds how many GPU entry points are inside Metal at once, across every caller.
    /// Resizable while running — see `setConcurrency`.
    static let gate = BlockingGate(max: 8)

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var _dutyCycle = 1.0
    nonisolated(unsafe) private static var _busyNanoseconds: UInt64 = 0
    nonisolated(unsafe) private static var _deviceNanoseconds: UInt64 = 0

    /// Width of the GPU gate. In-flight work finishes under the old width.
    public static func setConcurrency(_ slots: Int) { gate.set(max: slots) }

    public static var concurrency: Int { gate.max }

    /// Fraction (0, 1] of the device this process may hold: after each GPU op the slot is
    /// kept for as long as the op ran, scaled by `1/duty - 1`. 1 means no throttling.
    public static func setDutyCycle(_ duty: Double) {
        stateLock.withLock { _dutyCycle = min(max(duty, 0.05), 1.0) }
    }

    static var dutyCycle: Double { stateLock.withLock { _dutyCycle } }

    /// Seconds spent inside GPU slots since launch (wall time of the entry points, which
    /// is the GPU's work plus the encode and wait around it). For the resource governor.
    public static var busySeconds: Double {
        Double(stateLock.withLock { _busyNanoseconds }) / 1_000_000_000
    }

    /// Seconds the GPU itself spent executing this process's command buffers since launch,
    /// from each buffer's own `gpuStartTime`/`gpuEndTime`. The other number, `busySeconds`, is
    /// time spent *holding a slot*, which also counts encoding, staging copies and the wait; on
    /// the discrete Vega the device is idle for most of that (measured: GPU wait 0-2 % of slot
    /// time), so slot time says almost nothing about how busy the GPU is.
    public static var deviceBusySeconds: Double {
        Double(stateLock.withLock { _deviceNanoseconds }) / 1_000_000_000
    }

    static func recordDevice(startTime: Double, endTime: Double) {
        guard endTime > startTime, startTime > 0 else { return }
        let nanoseconds = UInt64((endTime - startTime) * 1_000_000_000)
        stateLock.withLock { _deviceNanoseconds &+= nanoseconds }
    }

    /// GPU entry points currently waiting for a slot.
    public static var waiting: Int { gate.waiting }

    /// Drops the pyramid builders' pooled textures, returning that GPU memory. Called on memory
    /// pressure; the next build simply allocates again.
    public static func trimTexturePool() {
        #if canImport(Metal) && os(macOS)
        activeBackend?.texturePool.trim()
        activeBackend?.trimOutputPool()
        activeBackend?.trimReadbackPool()
        #endif
    }

    /// Pool hits and misses so far, and the bytes it is holding. Diagnostics and tests.
    public static var texturePoolStats: (hits: Int, misses: Int, heldBytes: Int) {
        #if canImport(Metal) && os(macOS)
        if let pool = activeBackend?.texturePool {
            let c = pool.counts
            return (c.hits, c.misses, pool.heldBytes)
        }
        #endif
        return (0, 0, 0)
    }

    static func record(busyNanoseconds: UInt64) {
        stateLock.withLock { _busyNanoseconds &+= busyNanoseconds }
    }

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
        // Config.useGPUForMerge above.
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

    /// How many merges (`medianMerge` and `alignedMerge` together) have run on
    /// the GPU since launch, split by whether the GPU read and wrote the images
    /// where they already were or had them copied — see `MetalGPUBackend.runMerge`.
    /// For tests and diagnostics: on unified memory a merge that copies still
    /// gives the right answer, just slower and with an extra frame's worth of
    /// memory per image, so nothing else would notice.
    static func mergeCounts() -> (inPlace: Int, copied: Int) {
        #if canImport(Metal) && os(macOS)
        return activeBackend?.mergeCounts() ?? (0, 0)
        #else
        return (0, 0)
        #endif
    }

    /// Makes every merge take the path a discrete GPU takes — copy the images in,
    /// have the GPU write a `.storageModeManaged` buffer, synchronize it and copy
    /// it out — even on unified memory. For tests: otherwise that path only runs
    /// on hardware the suite may not be running on.
    static func setCopyMergeInputsForTesting(_ on: Bool) {
        #if canImport(Metal) && os(macOS)
        activeBackend?.setCopyInputs(on)
        #endif
    }

    static func setDiscreteMergesForTesting(_ on: Bool) {
        #if canImport(Metal) && os(macOS)
        activeBackend?.setDiscreteMerges(on)
        #endif
    }
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
/// Float textures kept between pyramid builds.
///
/// Profiling a 12 MP keypoint phase put Metal resource creation and release at 22-43 % of the
/// time spent holding a GPU slot: every build made ~40 textures and let them all go. A pyramid
/// build needs the same sizes every frame, so they are checked out for one build and returned
/// after its read-back. Contents are NOT cleared on reuse: every texture is written in full by
/// a kernel (or by `replace`) before anything reads it.
///
/// Storage stays `.managed` with the explicit blit `synchronize` before read-back: `.shared`
/// textures read back as zeros on the discrete Vega this runs on (see `buildSiftPyramid`).
/// Apple Silicon has no `.managed` and wants `.shared` here.
///
/// Bounded: the free list never holds more than twice the size of the last build's textures
/// (and never more than half the device's recommended working set), and is emptied outright on
/// memory pressure via `GPUOps.trimTexturePool()`.
final class FloatTexturePool: @unchecked Sendable {
    private let lock = NSLock()
    private var free: [Int: [MTLTexture]] = [:]
    private var freeBytes = 0
    private var lastBuildBytes = 0
    private(set) var hits = 0
    private(set) var misses = 0

    private static func key(_ width: Int, _ height: Int) -> Int { width &* 1_000_003 &+ height }
    private static func bytes(_ width: Int, _ height: Int) -> Int { width * height * 4 }

    func take(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        lock.lock()
        if var list = free[Self.key(width, height)], let texture = list.popLast() {
            free[Self.key(width, height)] = list
            freeBytes -= Self.bytes(width, height)
            hits += 1
            lock.unlock()
            return texture
        }
        misses += 1
        lock.unlock()
        return MetalGPUBackend.makeFloatTexture(device: device, width: width, height: height)
    }

    /// Returns a build's textures. `buildBytes` is what that build used, which sets the cap.
    func give(_ textures: [MTLTexture], buildBytes: Int, device: MTLDevice) {
        lock.lock()
        defer { lock.unlock() }
        lastBuildBytes = buildBytes
        let cap = min(2 * buildBytes, Int(device.recommendedMaxWorkingSetSize / 2))
        for texture in textures {
            let size = Self.bytes(texture.width, texture.height)
            if freeBytes + size > cap { continue }  // dropped: released with its last reference
            free[Self.key(texture.width, texture.height), default: []].append(texture)
            freeBytes += size
        }
    }

    func trim() {
        lock.lock()
        free.removeAll()
        freeBytes = 0
        lock.unlock()
    }

    var heldBytes: Int { lock.lock(); defer { lock.unlock() }; return freeBytes }
    var counts: (hits: Int, misses: Int) { lock.lock(); defer { lock.unlock() }; return (hits, misses) }
}

/// One build's checked-out textures, handed back together.
final class TextureLease {
    private let pool: FloatTexturePool
    private let device: MTLDevice
    private var leased: [MTLTexture] = []
    private var bytes = 0

    init(pool: FloatTexturePool, device: MTLDevice) {
        self.pool = pool
        self.device = device
    }

    func make(width: Int, height: Int) -> MTLTexture? {
        guard let texture = pool.take(device: device, width: width, height: height) else { return nil }
        leased.append(texture)
        bytes += width * height * 4
        return texture
    }

    func returnAll() {
        pool.give(leased, buildBytes: bytes, device: device)
        leased.removeAll()
    }
}

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
    ///
    /// Both have since happened, and the value was left alone on purpose. On an
    /// M5 Max the 8 slots let up to 8 of the old `alignedMerge`'s ~3.6GB of
    /// per-frame buffers (33MP) exist at once, which is how a 36GB machine went
    /// into swap — but the fix for that was to stop allocating, not to queue
    /// harder: the fused `alignedMerge` reads and writes the frames in place on
    /// unified memory, so a slot it holds pins nothing new, and every frame's
    /// GPU work goes through this one queue whatever the slot count.
    /// On a discrete GPU each slot it holds still has every input copied (9
    /// frames for 8 neighbours) plus the result, about half of what the old
    /// version held. The pyramid builders are unchanged by any of this.
    ///
    /// The width now lives in `GPUOps.gate`, which can be resized mid-run
    /// (`GPUOps.setConcurrency`) and is shared by every entry point.

    /// The merges' bookkeeping: see `GPUOps.mergeCounts` and
    /// `GPUOps.setDiscreteMergesForTesting`.
    private let mergeStateLock = NSLock()
    private var inPlaceMerges = 0
    private var copiedMerges = 0
    private var discreteMerges = false
    private var copyInputsForTesting = false

    /// `.storageModeManaged` merge outputs kept between merges, by length. A discrete GPU
    /// writes its result into one of these and it is copied out afterwards; allocating a
    /// frame-sized managed buffer for every merge was most of what that path cost besides
    /// the copy itself. Two per size is enough: merges in flight each hold one.
    private let outputPoolLock = NSLock()
    private var outputPool: [Int: [MTLBuffer]] = [:]

    private func takeManagedOutput(length: Int) -> MTLBuffer? {
        outputPoolLock.lock()
        if var list = outputPool[length], let buffer = list.popLast() {
            outputPool[length] = list
            outputPoolLock.unlock()
            return buffer
        }
        outputPoolLock.unlock()
        return device.makeBuffer(length: length, options: .storageModeManaged)
    }

    private func giveManagedOutput(_ buffer: MTLBuffer) {
        outputPoolLock.lock()
        defer { outputPoolLock.unlock() }
        var list = outputPool[buffer.length, default: []]
        if list.count < 2 { list.append(buffer) }
        outputPool[buffer.length] = list
    }

    func trimOutputPool() {
        outputPoolLock.lock()
        outputPool.removeAll()
        outputPoolLock.unlock()
    }

    func setCopyInputs(_ on: Bool) {
        mergeStateLock.withLock { copyInputsForTesting = on }
    }

    func mergeCounts() -> (inPlace: Int, copied: Int) {
        mergeStateLock.withLock { (inPlaceMerges, copiedMerges) }
    }

    func setDiscreteMerges(_ on: Bool) {
        mergeStateLock.withLock { discreteMerges = on }
    }

    /// Commits a command buffer, waits for it, and books how long the device itself ran it.
    private func commitAndWait(_ cmdBuf: MTLCommandBuffer) {
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        GPUOps.recordDevice(startTime: cmdBuf.gpuStartTime, endTime: cmdBuf.gpuEndTime)
    }

    /// Runs `body` inside `gpuSlots`. Every public entry point below must go
    /// through this rather than calling into Metal directly.
    private func withGPUSlot<T>(_ body: () -> T) -> T {
        GPUOps.gate.acquire()
        defer { GPUOps.gate.release() }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = body()
        let used = DispatchTime.now().uptimeNanoseconds - start
        GPUOps.record(busyNanoseconds: used)
        // Duty cycle: after an op that used the GPU for `t`, keep the slot for another
        // `t * (1/duty - 1)` so this caller's share of the device is at most `duty`.
        let duty = GPUOps.dutyCycle
        if duty < 1.0, duty > 0 {
            let pause = Double(used) * (1.0 / duty - 1.0) / 1_000_000_000
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        }
        return result
    }
    let warpU8: MTLComputePipelineState
    let warpU16: MTLComputePipelineState
    let medianU8: MTLComputePipelineState
    let medianU16: MTLComputePipelineState
    let alignedMergeU8: MTLComputePipelineState
    let alignedMergeU16: MTLComputePipelineState
    let downsampleNearest2xF32: MTLComputePipelineState
    let upsampleLinear2xF32: MTLComputePipelineState
    let gaussianRowF32: MTLComputePipelineState
    let gaussianColumnF32: MTLComputePipelineState
    let resizeAreaF32: MTLComputePipelineState
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
            self.medianU8 = try pipeline("median_merge_u8")
            self.medianU16 = try pipeline("median_merge_u16")
            self.alignedMergeU8 = try pipeline("aligned_merge_u8")
            self.alignedMergeU16 = try pipeline("aligned_merge_u16")
            self.downsampleNearest2xF32 = try pipeline("downsample_nearest_2x_f32")
            self.upsampleLinear2xF32 = try pipeline("upsample_linear_2x_f32")
            self.gaussianRowF32 = try pipeline("gaussian_row_f32")
            self.gaussianColumnF32 = try pipeline("gaussian_column_f32")
            self.resizeAreaF32 = try pipeline("resize_area_f32")
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
        commitAndWait(cmdBuf)
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
    ///
    /// Like `alignedMerge`, it reads every source where it already is on unified
    /// memory and writes `dst` in place (see "Binding images for the merges"
    /// below), rather than packing all `count` sources into one new buffer. At
    /// 33MP the static-earth merge's 17 sources made that buffer 3.3GB, filled by
    /// one thread, on every frame — the same per-frame allocation that put the
    /// aligned merge's machine into swap.
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
        guard count > 0, count <= Self.maxMergeSources, let first = sources[0],
              let format = MergeFormat(of: first)
        else { return false }
        let pipeline = format.bytesPerComponent == 1 ? medianU8 : medianU16

        var planes: [MergePlane] = []
        planes.reserveCapacity(count + 1)
        for i in 0..<count {
            guard let source = sources[i], let plane = format.plane(of: source) else { return false }
            planes.append(plane)
        }
        guard let dstPlane = format.plane(of: dst) else { return false }
        // The coverage plane, when there is one, is bound like one more input. It
        // has to describe exactly these sources, or it would skip real samples.
        if let misses {
            guard Int(mat_wrapper_rows(misses)) == format.rows, Int(mat_wrapper_cols(misses)) == format.cols,
                  mat_wrapper_channels(misses) == 1, mat_wrapper_bits_per_component(misses) == 8,
                  let pointer = mat_wrapper_data_ptr(misses)
            else { return false }
            let step = Int(mat_wrapper_step(misses))
            guard step >= format.cols else { return false }
            planes.append(MergePlane(pointer: pointer, step: step,
                                     length: (format.rows - 1) * step + format.cols))
        }

        return runMerge(inputs: planes, dst: dstPlane, format: format) { encoder, bound in
            let bpc = format.bytesPerComponent
            var sourceSteps = [Int32](repeating: 0, count: Self.maxMergeSources)
            for i in 0..<count { sourceSteps[i] = Int32(bound.inputs[i].step / bpc) }
            let missesBinding = misses == nil ? bound.inputs[0] : bound.inputs[count]
            var width = Int32(format.cols), height = Int32(format.rows), chans = Int32(format.channels)
            var dstStep = Int32(bound.dst.step / bpc)
            var missesStep = Int32(missesBinding.step)
            var sourceCount = Int32(count)
            var threshold = Float(outlierThreshold)
            var includeAllFlag: Int32 = includeAll ? 1 : 0
            var hasMisses: Int32 = misses == nil ? 0 : 1

            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(bound.inputs[0].buffer, offset: bound.inputs[0].offset, index: 0)
            encoder.setBuffer(bound.dst.buffer, offset: bound.dst.offset, index: 1)
            encoder.setBuffer(missesBinding.buffer, offset: missesBinding.offset, index: 2)
            encoder.setBytes(sourceSteps, length: sourceSteps.count * MemoryLayout<Int32>.stride, index: 3)
            encoder.setBytes(&width, length: MemoryLayout<Int32>.size, index: 4)
            encoder.setBytes(&height, length: MemoryLayout<Int32>.size, index: 5)
            encoder.setBytes(&chans, length: MemoryLayout<Int32>.size, index: 6)
            encoder.setBytes(&dstStep, length: MemoryLayout<Int32>.size, index: 7)
            encoder.setBytes(&missesStep, length: MemoryLayout<Int32>.size, index: 8)
            encoder.setBytes(&sourceCount, length: MemoryLayout<Int32>.size, index: 9)
            encoder.setBytes(&threshold, length: MemoryLayout<Float>.size, index: 10)
            encoder.setBytes(&includeAllFlag, length: MemoryLayout<Int32>.size, index: 11)
            // Sources 1..<count at 12..., and the rest of the 16 slots pointed at
            // source 0 only so that no declared buffer is ever left unbound.
            for slot in 1..<Self.maxMergeSources {
                let source = slot < count ? bound.inputs[slot] : bound.inputs[0]
                encoder.setBuffer(source.buffer, offset: source.offset, index: 11 + slot)
            }
            encoder.setBytes(&hasMisses, length: MemoryLayout<Int32>.size, index: 28)
            dispatch(encoder: encoder, pipeline: pipeline, width: format.cols, height: format.rows)
        }
    }

    // MARK: - Aligned merge (fused)

    /// One frame's whole aligned merge — every neighbour's warp, the coverage
    /// count and the sigma-clipped median merge — as ONE kernel dispatch
    /// (`aligned_merge_*`) that, for each destination pixel, warps every
    /// neighbour to it on the spot, counts the neighbours whose warp does not
    /// reach it, and merges. No warped copy of any neighbour ever exists. On
    /// unified memory the kernel also reads the decoded images and writes the
    /// result where they already are (`bindInPlace`), so a merge allocates
    /// nothing and copies nothing.
    ///
    /// What it replaced was already one command buffer per frame — see
    /// GPU_MERGE_BATCHING_FIX.md for the round-trip problem that fixed — but it
    /// still spent its time moving memory rather than computing. Measured on an
    /// M5 Max (36GB unified memory) on a 7008x4672 16-bit RGB frame with 8
    /// neighbours, frames already decoded, in a test process sharing the machine
    /// with a running star (hence the wide ranges):
    ///
    /// | | wall per merge | extra memory | GPU executing |
    /// |---|---|---|---|
    /// | CPU path | 0.37-0.78s | +1.9GB | — |
    /// | a warp dispatch per neighbour into a packed buffer, then a merge | 0.24-0.35s | +3.6GB | ~0.04s |
    /// | this | 0.08-0.13s | +0MB | ~0.05s |
    ///
    /// The old version's 3.6GB was every neighbour copied into a new shared
    /// buffer (1.6GB), the packed warps (1.8GB), a misses plane and the result,
    /// all freshly allocated per frame, all invisible to `MemoryMonitor`'s
    /// ledger, and up to `gpuSlots` (8) frames inside at once — 29GB of a 36GB
    /// machine before anything else in the run is counted.
    /// A real 33MP run went into swap there and its aligned merges took 77-260s
    /// each, against 2-4s once the run was cut to 4-6 frames. Four at a time
    /// this one holds nothing but the results: twelve merges, measured twice,
    /// took 1.2-2.0s a merge on the CPU, peaking 5.6-7.5GB higher, and
    /// 0.07-0.27s a merge here, peaking 0.1-1.8GB higher.
    ///
    /// Its output is byte-identical to that version's (checked on a full 33MP
    /// frame, and on smaller ones with both `includeAll` settings), and
    /// `GPUOpsTests.testFusedAlignedMergeMatchesTheStandaloneKernelsExactly`
    /// holds it, byte for byte, to the merge the standalone `warp` and
    /// `medianMerge` kernels make of the same frames — they share `warp_tap`,
    /// `warp_value` and `sigma_clipped_median`, so the warp, the coverage the
    /// merge counts and the selection cannot drift apart.
    ///
    /// A discrete GPU cannot read the images where they are, so there they are
    /// copied in and the result copied back out (`bindByCopy`) — still without
    /// the packed-warps buffer. That path is checked for correctness on Apple
    /// silicon with a discrete GPU's storage modes forced
    /// (`GPUOps.setDiscreteMergesForTesting`), but its speed has not been
    /// measured on a discrete GPU.
    ///
    /// The streaming/spill path (`MergeSpiller`, ImageAligner.cpp) deliberately
    /// does NOT call this — it holds only one warp resident at a time by
    /// design, which handing every neighbour to one dispatch works directly
    /// against. It keeps calling `warp`/`warpCoverage` above, one round-trip at
    /// a time, exactly as before.
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
        guard neighbourCount > 0, neighbourCount < Self.maxMergeSources,
              let format = MergeFormat(of: base)
        else { return false }
        let pipeline = format.bytesPerComponent == 1 ? alignedMergeU8 : alignedMergeU16

        // Every image has to match base's geometry exactly — the caller
        // (`tryGPUAlignedMerge`, ImageAligner.cpp) filters neighbours by that
        // before calling, so a mismatch here is refused rather than dropped, since
        // a dropped neighbour would make the GPU and CPU paths disagree about
        // which neighbours contributed.
        guard let basePlane = format.plane(of: base), let dstPlane = format.plane(of: dst) else { return false }
        var planes = [basePlane]
        planes.reserveCapacity(neighbourCount + 1)
        for i in 0..<neighbourCount {
            guard let neighbour = neighbours[i], let plane = format.plane(of: neighbour) else { return false }
            planes.append(plane)
        }

        // Each neighbour's INVERSE homography (dst -> src), the convention the
        // warp kernels sample with — same inversion as `warpImpl`.
        var hInv = [Float](repeating: 0, count: (Self.maxMergeSources - 1) * 9)
        for i in 0..<neighbourCount {
            guard let inverse = invert3x3(homographies + i * 9) else { return false }
            for k in 0..<9 { hInv[i * 9 + k] = Float(inverse[k]) }
        }

        return runMerge(inputs: planes, dst: dstPlane, format: format) { encoder, bound in
            let bpc = format.bytesPerComponent
            var width = Int32(format.cols), height = Int32(format.rows), chans = Int32(format.channels)
            var baseStep = Int32(bound.inputs[0].step / bpc)
            var dstStep = Int32(bound.dst.step / bpc)
            var neighbourSteps = [Int32](repeating: 0, count: Self.maxMergeSources - 1)
            for i in 0..<neighbourCount { neighbourSteps[i] = Int32(bound.inputs[i + 1].step / bpc) }
            var count = Int32(neighbourCount)
            var threshold = Float(outlierThreshold)
            var includeAllFlag: Int32 = includeAll ? 1 : 0

            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(bound.inputs[0].buffer, offset: bound.inputs[0].offset, index: 0)
            encoder.setBuffer(bound.dst.buffer, offset: bound.dst.offset, index: 1)
            encoder.setBytes(hInv, length: hInv.count * MemoryLayout<Float>.stride, index: 2)
            encoder.setBytes(neighbourSteps, length: neighbourSteps.count * MemoryLayout<Int32>.stride, index: 3)
            encoder.setBytes(&width, length: MemoryLayout<Int32>.size, index: 4)
            encoder.setBytes(&height, length: MemoryLayout<Int32>.size, index: 5)
            encoder.setBytes(&chans, length: MemoryLayout<Int32>.size, index: 6)
            encoder.setBytes(&baseStep, length: MemoryLayout<Int32>.size, index: 7)
            encoder.setBytes(&dstStep, length: MemoryLayout<Int32>.size, index: 8)
            encoder.setBytes(&count, length: MemoryLayout<Int32>.size, index: 9)
            encoder.setBytes(&threshold, length: MemoryLayout<Float>.size, index: 10)
            encoder.setBytes(&includeAllFlag, length: MemoryLayout<Int32>.size, index: 11)
            // Neighbours at 12..., and the rest of the 16 slots pointed at the base
            // only so that no declared buffer is ever left unbound.
            for slot in 1..<Self.maxMergeSources {
                let source = slot <= neighbourCount ? bound.inputs[slot] : bound.inputs[0]
                encoder.setBuffer(source.buffer, offset: source.offset, index: 11 + slot)
            }
            dispatch(encoder: encoder, pipeline: pipeline, width: format.cols, height: format.rows)
        }
    }

    // MARK: - Binding images for the merges

    /// The most images one merge reads: the base (or first source) plus 16 more,
    /// each bound at its own buffer index — 0, then 12...27 — by the
    /// `median_merge_*` and `aligned_merge_*` kernels, which select from a
    /// 17-entry array.
    static let maxMergeSources = 17

    /// The pixel layout every image in one merge shares: the first image's, which
    /// every other one (and `dst`) has to match exactly.
    private struct MergeFormat {
        let rows: Int, cols: Int, channels: Int
        let bitsPerComponent: Int64
        let bytesPerComponent: Int
        var rowBytes: Int { cols * channels * bytesPerComponent }

        /// nil for anything the merge kernels have no instantiation for.
        init?(of ref: MatWrapperRef) {
            rows = Int(mat_wrapper_rows(ref))
            cols = Int(mat_wrapper_cols(ref))
            channels = Int(mat_wrapper_channels(ref))
            bitsPerComponent = mat_wrapper_bits_per_component(ref)
            guard rows > 0, cols > 0, channels >= 1, channels <= 4,
                  bitsPerComponent == 8 || bitsPerComponent == 16
            else { return nil }
            bytesPerComponent = Int(bitsPerComponent) / 8
        }

        /// Where `ref`'s pixels are, or nil when it does not have exactly this layout.
        func plane(of ref: MatWrapperRef) -> MergePlane? {
            guard Int(mat_wrapper_rows(ref)) == rows, Int(mat_wrapper_cols(ref)) == cols,
                  Int(mat_wrapper_channels(ref)) == channels,
                  mat_wrapper_bits_per_component(ref) == bitsPerComponent,
                  let pointer = mat_wrapper_data_ptr(ref)
            else { return nil }
            let step = Int(mat_wrapper_step(ref))
            guard step >= rowBytes, step % bytesPerComponent == 0 else { return nil }
            return MergePlane(pointer: pointer, step: step, length: (rows - 1) * step + rowBytes)
        }
    }

    /// Where one image's pixels are on the CPU side.
    private struct MergePlane {
        let pointer: UnsafeRawPointer
        let step: Int
        /// Bytes from the first pixel to the end of the last row's pixels — not
        /// `rows * step`, which reaches past the data when the last row is padded.
        let length: Int
    }

    /// One image's pixels as a merge kernel sees them: a buffer, the byte offset
    /// of the first pixel inside it, and the row stride in bytes.
    private struct MergeBinding {
        let buffer: MTLBuffer
        let offset: Int
        let step: Int
    }

    /// How a merge's images reach the GPU, plus what to do once it is done.
    private struct MergeBindings {
        /// In the order the inputs were given.
        let inputs: [MergeBinding]
        let dst: MergeBinding
        /// A `.storageModeManaged` destination needs a blit `synchronize` before the
        /// CPU can read it; nil when there is nothing to synchronize.
        let managedDst: MTLBuffer?
        /// Runs after the command buffer completes: copies the result out when the
        /// GPU wrote into a buffer of its own rather than into `dst` itself.
        let finish: () -> Void
    }

    /// Binds `inputs` and `dst` for the GPU, has `encode` record the dispatch, and
    /// runs it to completion — the part `medianMerge` and `alignedMerge` share.
    /// On unified memory the GPU reads and writes the images in place
    /// (`bindInPlace`); on a discrete GPU, or if an image cannot be wrapped, they
    /// are copied (`bindByCopy`).
    private func runMerge(inputs: [MergePlane], dst: MergePlane, format: MergeFormat,
                          encode: (MTLComputeCommandEncoder, MergeBindings) -> Void) -> Bool {
        let (discrete, copyInputs) = mergeStateLock.withLock { (discreteMerges, copyInputsForTesting) }
        let unified = device.hasUnifiedMemory && !discrete
        // Inputs are read where they are on every device. Only the OUTPUT differs: unified
        // memory writes the destination image itself, a discrete GPU writes a managed buffer
        // (a kernel writing shared memory pays PCIe on every access) that is copied out.
        let inPlace = copyInputs ? nil : bindInPlace(inputs: inputs, dst: dst, format: format,
                                                     writeDstInPlace: unified)
        if inPlace == nil && !copyInputs {
            Log.d("GPU merge: could not hand the GPU these images in place; copying them")
        }
        guard let bound = inPlace ?? bindByCopy(inputs: inputs, dst: dst, rows: format.rows,
                                                rowBytes: format.rowBytes, managedDst: !unified),
              let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder()
        else { return false }

        encode(encoder, bound)
        encoder.endEncoding()

        if let managedDst = bound.managedDst {
            guard let sync = cmdBuf.makeBlitCommandEncoder() else { return false }
            sync.synchronize(resource: managedDst)
            sync.endEncoding()
        }

        commitAndWait(cmdBuf)
        guard cmdBuf.status == .completed else { return false }
        bound.finish()
        mergeStateLock.withLock {
            if inPlace != nil { inPlaceMerges += 1 } else { copiedMerges += 1 }
        }
        return true
    }

    /// Unified memory: hand the GPU the images' own pixels, no copies at all.
    ///
    /// `makeBuffer(bytesNoCopy:)` takes only whole pages, and an OpenCV buffer
    /// starts wherever its allocator put it, so each image is wrapped from the
    /// page its first pixel is on to the end of the page its last pixel is on,
    /// and bound at the first pixel's offset inside that. The kernels read and
    /// write only inside each image's own pixels, never the rest of those
    /// pages. Nothing here owns the memory (`deallocator: nil`): every image
    /// outlives the merge, which waits for the GPU before returning.
    ///
    /// Returns nil when any one image cannot be wrapped, and the caller copies
    /// them all instead.
    private func bindInPlace(inputs: [MergePlane], dst: MergePlane, format: MergeFormat,
                             writeDstInPlace: Bool) -> MergeBindings? {
        func wrap(_ plane: MergePlane) -> MergeBinding? {
            let page = Int(getpagesize())
            let address = Int(bitPattern: plane.pointer)
            let start = address & ~(page - 1)
            let offset = address - start
            let length = (offset + plane.length + page - 1) & ~(page - 1)
            // A device-buffer offset has to be aligned to what the kernel reads
            // through it; 4 covers both pixel depths.
            guard offset % 4 == 0,
                  let pageStart = UnsafeMutableRawPointer(bitPattern: start),
                  let buffer = device.makeBuffer(bytesNoCopy: pageStart, length: length,
                                                 options: .storageModeShared, deallocator: nil)
            else { return nil }
            return MergeBinding(buffer: buffer, offset: offset, step: plane.step)
        }
        var inputBindings: [MergeBinding] = []
        inputBindings.reserveCapacity(inputs.count)
        for input in inputs {
            guard let binding = wrap(input) else { return nil }
            inputBindings.append(binding)
        }
        if writeDstInPlace {
            guard let dstBinding = wrap(dst) else { return nil }
            return MergeBindings(inputs: inputBindings, dst: dstBinding, managedDst: nil, finish: {})
        }

        // Discrete GPU: inputs stay put, the result goes to a pooled managed buffer and is
        // copied out once the GPU is done.
        let rows = format.rows, rowBytes = format.rowBytes
        guard let output = takeManagedOutput(length: rowBytes * rows) else { return nil }
        nonisolated(unsafe) let outPointer = UnsafeMutableRawPointer(mutating: dst.pointer)
        let dstStep = dst.step
        return MergeBindings(
          inputs: inputBindings,
          dst: MergeBinding(buffer: output, offset: 0, step: rowBytes),
          managedDst: output,
          finish: { [self] in
              let source = output.contents()
              for y in 0..<rows {
                  memcpy(outPointer.advanced(by: y * dstStep), source.advanced(by: y * rowBytes), rowBytes)
              }
              giveManagedOutput(output)
          })
    }

    /// A discrete GPU (or an image unified memory could not wrap): copy every
    /// input into one buffer and have the GPU write a buffer of its own, copied
    /// out once it is done.
    ///
    /// The inputs go in `.storageModeShared`, which is how the two-pass aligned
    /// merge this replaced moved its neighbours and was measured on the iMac
    /// Pro's Vega; the result goes in `.storageModeManaged` on a discrete GPU for
    /// the same reason that version gave: a kernel writing `.shared` memory there
    /// pays PCIe on every access. Each input is copied on its own thread — they
    /// are independent, and one thread copying every source was the slowest
    /// part of both merges' old versions.
    private func bindByCopy(inputs: [MergePlane], dst: MergePlane,
                            rows: Int, rowBytes: Int, managedDst: Bool) -> MergeBindings? {
        // Slots start 256-byte aligned, comfortably past any offset rule Metal has
        // for a device buffer.
        var offsets: [Int] = []
        var total = 0
        for input in inputs {
            offsets.append(total)
            total += (input.length + 255) & ~255
        }
        guard let inputBuffer = device.makeBuffer(length: max(total, 1), options: .storageModeShared)
        else { return nil }
        let dstMode: MTLResourceOptions = managedDst ? .storageModeManaged : .storageModeShared
        guard let output = device.makeBuffer(length: rowBytes * rows, options: dstMode) else { return nil }

        nonisolated(unsafe) let inputBase = inputBuffer.contents()
        DispatchQueue.concurrentPerform(iterations: inputs.count) { i in
            memcpy(inputBase.advanced(by: offsets[i]), inputs[i].pointer, inputs[i].length)
        }

        nonisolated(unsafe) let outPointer = UnsafeMutableRawPointer(mutating: dst.pointer)
        let dstStep = dst.step
        return MergeBindings(
          inputs: inputs.indices.map {
              MergeBinding(buffer: inputBuffer, offset: offsets[$0], step: inputs[$0].step)
          },
          dst: MergeBinding(buffer: output, offset: 0, step: rowBytes),
          managedDst: managedDst ? output : nil,
          finish: {
              let source = output.contents()
              for y in 0..<rows {
                  memcpy(outPointer.advanced(by: y * dstStep), source.advanced(by: y * rowBytes), rowBytes)
              }
          })
    }

    // MARK: - SIFT Gaussian pyramid

    /// Builds the Gaussian scale-space pyramid `siftDetectAndComputeGPU`
    /// (SIFTDetector.cpp) needs, with small custom kernels for every step: the
    /// 2x upsample (`upsample_linear_2x_f32`), each blur (`gaussian_row_f32` then
    /// `gaussian_column_f32`, OpenCV's own coefficients) and each octave's halving
    /// (`downsample_nearest_2x_f32`) — see GPUOps_C.h's `GPUSiftPyramidFunc` for
    /// the exact contract this implements. All work for one pyramid goes on one
    /// command buffer, committed once at the end; every output texture is kept
    /// alive until then, and one scratch texture per octave carries the row pass
    /// into the column pass (hazard tracking orders the reuse).
    ///
    /// Not `MPSImageGaussianBlur`, which this used to be, because it is not the
    /// blur SIFT asks for. Fitted against cv::GaussianBlur on a real 4000x2667
    /// detection input, every MPS pass blurred wider than requested — sigma 1.249,
    /// 1.226, 1.545, 1.947, 2.453, 3.090 behaved like 1.284, 1.266, 1.575, 1.967,
    /// 2.473, 3.110, which is a Gaussian convolved with a one-pixel box (variance
    /// + 1/12 each pass) — and it pads with zeros where OpenCV reflects, so the
    /// first three columns came back up to 26 levels dark. The extra variance
    /// accumulates up each octave and moves the small scales stars live at:
    /// on a moonlit 24MP sky the finest octave's extrema per scale layer went from
    /// 1383/271/77 (cv::SIFT and the reference pyramid agree) to 736/123/171, and
    /// the detector returned 1050 keypoints where cv::SIFT returns 1792. SIFT's
    /// scale test compares DoG layers that differ by a few percent at a star, so
    /// a blur that is "approximate... ~10 bits of precision", as MPS documents
    /// its own, is not one it can use.
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
    func buildSiftPyramid(base: MatWrapperRef, doubleImageSize: Bool, sigma: Double,
                          nOctaves: Int, nOctaveLayers: Int,
                          outPyramid: UnsafeMutablePointer<MatWrapperRef?>) -> Bool {
        // The GPU part holds a slot; reading the results out into Mats does not need one, so
        // it happens after the slot is released and another caller can start its own GPU work.
        let pending = withGPUSlot {
            buildSiftPyramidImpl(base: base, doubleImageSize: doubleImageSize, sigma: sigma,
                                 nOctaves: nOctaves, nOctaveLayers: nOctaveLayers)
        }
        guard let pending else { return false }
        defer { giveReadbackBuffers(pending) }
        for (index, readback) in pending.enumerated() {
            guard let mat = matWrapper(fromReadback: readback) else {
                for i in 0..<index { if let m = outPyramid[i] { mat_wrapper_release(m); outPyramid[i] = nil } }
                return false
            }
            outPyramid[index] = mat
        }
        return true
    }

    private func buildSiftPyramidImpl(base: MatWrapperRef, doubleImageSize: Bool, sigma: Double,
                                      nOctaves: Int, nOctaveLayers: Int) -> [PendingReadback]? {
        guard nOctaves > 0, nOctaveLayers > 0 else { return nil }
        guard mat_wrapper_bits_per_component(base) == 32, mat_wrapper_channels(base) == 1 else {
            return nil  // SIFTDetector.cpp always hands this CV_32FC1; anything else is a caller bug
        }
        let baseRows = Int(mat_wrapper_rows(base))
        let baseCols = Int(mat_wrapper_cols(base))
        guard baseRows > 0, baseCols > 0, let basePtr = mat_wrapper_data_ptr(base) else { return nil }
        let baseStepBytes = Int(mat_wrapper_step(base))

        // Every texture below is leased from the pool and handed back when this returns,
        // which is after the read-back at the end.
        let lease = TextureLease(pool: texturePool, device: device)
        defer { lease.returnAll() }

        guard let inputTexture = lease.make(width: baseCols, height: baseRows) else { return nil }
        inputTexture.replace(region: MTLRegionMake2D(0, 0, baseCols, baseRows), mipmapLevel: 0,
                             withBytes: basePtr, bytesPerRow: baseStepBytes)

        guard let cmdBuf = queue.makeCommandBuffer() else { return nil }

        // createInitialImage: the optional 2x upscale (plain bilinear — matching
        // cv::SIFT::create()'s actual enable_precise_upscale=false default, not
        // the warpAffine/BORDER_REFLECT "precise" path) ...
        var current = inputTexture
        var curWidth = baseCols, curHeight = baseRows
        if doubleImageSize {
            guard let doubled = lease.make(width: baseCols * 2, height: baseRows * 2),
                  let encoder = cmdBuf.makeComputeCommandEncoder()
            else { return nil }
            encoder.setComputePipelineState(upsampleLinear2xF32)
            encoder.setTexture(current, index: 0)
            encoder.setTexture(doubled, index: 1)
            dispatch(encoder: encoder, pipeline: upsampleLinear2xF32,
                     width: baseCols * 2, height: baseRows * 2)
            encoder.endEncoding()
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

        // One row-pass scratch texture per octave, shared by that octave's blurs.
        var scratch = [MTLTexture?](repeating: nil, count: nOctaves)
        func scratchTexture(octave: Int, width: Int, height: Int) -> MTLTexture? {
            if scratch[octave] == nil { scratch[octave] = lease.make(width: width, height: height) }
            return scratch[octave]
        }

        guard let firstLayer = lease.make(width: curWidth, height: curHeight),
              let firstScratch = scratchTexture(octave: 0, width: curWidth, height: curHeight),
              encodeGaussianBlur(cmdBuf, source: current, scratch: firstScratch,
                                 destination: firstLayer, sigma: sigDiff)
        else { return nil }

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
                    guard let src = textures[srcIdx] else { return nil }
                    let dstWidth = src.width / 2, dstHeight = src.height / 2
                    guard dstWidth > 0, dstHeight > 0,
                          let dst = lease.make(width: dstWidth, height: dstHeight),
                          let encoder = cmdBuf.makeComputeCommandEncoder()
                    else { return nil }
                    encoder.setComputePipelineState(downsampleNearest2xF32)
                    encoder.setTexture(src, index: 0)
                    encoder.setTexture(dst, index: 1)
                    dispatch(encoder: encoder, pipeline: downsampleNearest2xF32,
                            width: dstWidth, height: dstHeight)
                    encoder.endEncoding()
                    textures[idx] = dst
                } else {
                    guard let src = textures[idx - 1],
                          let dst = lease.make(width: src.width, height: src.height),
                          let tmp = scratchTexture(octave: o, width: src.width, height: src.height),
                          encodeGaussianBlur(cmdBuf, source: src, scratch: tmp,
                                             destination: dst, sigma: sig[i])
                    else { return nil }
                    textures[idx] = dst
                }
            }
        }

        // Each level is blitted into a linear shared buffer by the GPU's own copy engine (which
        // also de-tiles it); the CPU then memcpy's out of those buffers after the slot is gone.
        // No `.managed` synchronize is needed: nothing reads the textures from the CPU.
        let all = textures.compactMap { $0 }
        guard all.count == textures.count else { return nil }
        guard let readbacks = encodeReadbacks(cmdBuf, textures: all) else { return nil }

        commitAndWait(cmdBuf)
        guard cmdBuf.status == .completed else {
            giveReadbackBuffers(readbacks)
            return nil
        }
        return readbacks
    }

    /// cv::GaussianBlur(src, dst, Size(size, size), sigma, sigma, border) on a
    /// CV_32F image, as two passes through `scratch`: rows, then columns. `size`
    /// nil is `Size()`, OpenCV choosing it from sigma; the border is
    /// BORDER_REFLECT_101 (the default) unless `replicateBorder`.
    private func encodeGaussianBlur(_ cmdBuf: MTLCommandBuffer, source: MTLTexture,
                                    scratch: MTLTexture, destination: MTLTexture,
                                    sigma: Double, size: Int? = nil,
                                    replicateBorder: Bool = false) -> Bool {
        let weights = MetalGPUBackend.openCVGaussianKernel(sigma: sigma, size: size)
        var radius = Int32(weights.count / 2)
        var replicate: Int32 = replicateBorder ? 1 : 0
        for (pipeline, input, output) in [(gaussianRowF32, source, scratch),
                                          (gaussianColumnF32, scratch, destination)] {
            guard let encoder = cmdBuf.makeComputeCommandEncoder() else { return false }
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(input, index: 0)
            encoder.setTexture(output, index: 1)
            weights.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
            encoder.setBytes(&radius, length: MemoryLayout<Int32>.size, index: 1)
            encoder.setBytes(&replicate, length: MemoryLayout<Int32>.size, index: 2)
            dispatch(encoder: encoder, pipeline: pipeline,
                     width: destination.width, height: destination.height)
            encoder.endEncoding()
        }
        return true
    }

    /// The coefficients cv::GaussianBlur convolves a CV_32F image with for `sigma`
    /// and an odd kernel `size`: cv::getGaussianKernel's `exp(-x² / 2σ²)` normalised
    /// to sum to one, computed in double and handed over as float. `size` nil is
    /// GaussianBlur's own rule for float depths, `cvRound(sigma * 4 * 2 + 1) | 1`.
    static func openCVGaussianKernel(sigma: Double, size explicitSize: Int? = nil) -> [Float] {
        let size = explicitSize ?? (Int((sigma * 4 * 2 + 1).rounded(.toNearestOrEven)) | 1)
        let half = size / 2
        let scale = -0.5 / (sigma * sigma)
        let raw = (0..<size).map { i -> Double in
            let x = Double(i - half)
            return Foundation.exp(scale * x * x)
        }
        let sum = raw.reduce(0, +)
        return raw.map { Float($0 / sum) }
    }

    /// computeResizeAreaTab (OpenCV's resize.cpp) for one axis of an INTER_AREA
    /// downscale from `source` to `destination` samples, for `resize_area_f32`:
    /// per destination index four (source index, weight) slots in the order OpenCV
    /// sums them, unused ones -1. Built in double as OpenCV builds it — the
    /// 1e-3 cut-offs on the partial cells are compared at that precision, which a
    /// float on the GPU could not reproduce. Nil when a destination index would
    /// need more than four taps, which a downscale by at most ~2 never does.
    static func areaResizeTable(source: Int, destination: Int) -> (index: [Int32], weight: [Float])? {
        guard source > 0, destination > 0, destination <= source else { return nil }
        let scale = 1.0 / (Double(destination) / Double(source))
        var index = [Int32](repeating: -1, count: destination * 4)
        var weight = [Float](repeating: 0, count: destination * 4)
        for d in 0..<destination {
            let fs1 = Double(d) * scale
            let fs2 = fs1 + scale
            let cellWidth = min(scale, Double(source) - fs1)
            var s1 = Int(fs1.rounded(.up))
            let s2 = min(Int(fs2.rounded(.down)), source - 1)
            s1 = min(s1, s2)

            var taps: [(Int, Float)] = []
            if Double(s1) - fs1 > 1e-3 {
                taps.append((s1 - 1, Float((Double(s1) - fs1) / cellWidth)))
            }
            for s in s1..<s2 {
                taps.append((s, Float(1.0 / cellWidth)))
            }
            if fs2 - Double(s2) > 1e-3 {
                taps.append((s2, Float(min(min(fs2 - Double(s2), 1.0), cellWidth) / cellWidth)))
            }
            guard taps.count <= 4 else { return nil }
            for (slot, tap) in taps.enumerated() {
                index[d * 4 + slot] = Int32(tap.0)
                weight[d * 4 + slot] = tap.1
            }
        }
        return (index, weight)
    }

    // MARK: - AKAZE nonlinear diffusion pyramid

    /// Builds the nonlinear diffusion scale-space pyramid
    /// `akazeDetectAndComputeGPU` (AKAZEDetector.cpp) needs — see
    /// `GPUAkazePyramidFunc` in GPUOps_C.h for the exact contract. Each step
    /// reproduces `buildPyramidReference` (AKAZEDetector.cpp): its two blurs are
    /// `encodeGaussianBlur` with the reference's own kernel sizes (9 taps for
    /// `soffset`, 5 for sigma 1) and BORDER_REPLICATE, each new octave is
    /// cv::resize's INTER_AREA through its own weight tables (`resize_area_f32`),
    /// the Scharr derivatives read reflect-101 as cv::Scharr's BORDER_DEFAULT
    /// does, the Perona-Malik G2 diffusivity is a small custom kernel, and the
    /// FED explicit-diffusion steps are a direct port of `nldStepScalar` onto
    /// textures, including its literal four-corner special case.
    ///
    /// It used to approximate the first three — `MPSImageGaussianBlur` for both
    /// blurs (a wider, zero-padded, untruncated Gaussian; see `buildSiftPyramid`),
    /// a plain 2x2 average for the octave step, and a clamped Scharr — and kept
    /// 79-88% of cv::AKAZE's 2000 keypoints on real ground (two moving sequences,
    /// four frames), where it now keeps all 2000 at the same positions to 5e-4px
    /// with 1996-2000 identical descriptors. The 2x2 average was the subtle one: a
    /// level is (int)(size / 2^octave) of the original, so an odd dimension makes
    /// the step 2.0006 rather than 2 and the samples drift a whole source pixel
    /// towards the bottom of the frame, which is where the ground is. Measured
    /// against phase correlation, the old keypoints fitted ground warps no worse
    /// than these (worst third 2.63 vs 2.58px over 16 pairs): the similarity fit's
    /// hundreds of inliers absorbed the difference. What this buys is a GPU path
    /// that finds what the CPU path finds, as Linux, Windows and GPU-less Macs do.
    ///
    /// Like `buildSiftPyramid`, every texture is `.storageModeManaged` with an
    /// explicit blit-encoder `synchronize` before the final readback — see that
    /// function's doc comment for the measured reason (a `.shared` texture a
    /// compute kernel writes reads back as zero on this Vega).
    func buildAkazePyramid(img: MatWrapperRef, soffset: Float,
                          levels: UnsafePointer<GPUAkazeLevelInfo>, levelCount: Int,
                          stepCounts: UnsafePointer<Int32>, tsteps: UnsafePointer<Float>?,
                          tstepsCount: Int, kcontrastBase: Float,
                          outLt: UnsafeMutablePointer<MatWrapperRef?>,
                          outLsmooth: UnsafeMutablePointer<MatWrapperRef?>) -> Bool {
        let pending = withGPUSlot {
            buildAkazePyramidImpl(img: img, soffset: soffset, levels: levels, levelCount: levelCount,
                                  stepCounts: stepCounts, tsteps: tsteps, tstepsCount: tstepsCount,
                                  kcontrastBase: kcontrastBase)
        }
        guard let pending else { return false }
        defer { giveReadbackBuffers(pending) }
        // lt levels first, then lsmooth levels (see the impl)
        var made: [MatWrapperRef] = []
        for readback in pending {
            guard let mat = matWrapper(fromReadback: readback) else {
                made.forEach { mat_wrapper_release($0) }
                return false
            }
            made.append(mat)
        }
        for i in 0..<levelCount {
            outLt[i] = made[i]
            outLsmooth[i] = made[levelCount + i]
        }
        return true
    }

    private func buildAkazePyramidImpl(img: MatWrapperRef, soffset: Float,
                                       levels: UnsafePointer<GPUAkazeLevelInfo>, levelCount: Int,
                                       stepCounts: UnsafePointer<Int32>, tsteps: UnsafePointer<Float>?,
                                       tstepsCount: Int, kcontrastBase: Float) -> [PendingReadback]? {
        guard levelCount > 1 else { return nil }  // the trivial 1-level case never reaches here
        guard mat_wrapper_bits_per_component(img) == 32, mat_wrapper_channels(img) == 1 else {
            return nil  // AKAZEDetector.cpp always hands this CV_32FC1; anything else is a caller bug
        }
        let imgRows = Int(mat_wrapper_rows(img)), imgCols = Int(mat_wrapper_cols(img))
        guard imgRows > 0, imgCols > 0, let imgPtr = mat_wrapper_data_ptr(img) else { return nil }
        let imgStepBytes = Int(mat_wrapper_step(img))

        let lease = TextureLease(pool: texturePool, device: device)
        defer { lease.returnAll() }

        guard let inputTexture = lease.make(width: imgCols, height: imgRows) else { return nil }
        inputTexture.replace(region: MTLRegionMake2D(0, 0, imgCols, imgRows), mipmapLevel: 0,
                             withBytes: imgPtr, bytesPerRow: imgStepBytes)

        guard let cmdBuf = queue.makeCommandBuffer() else { return nil }

        var ltTextures = [MTLTexture?](repeating: nil, count: levelCount)
        var lsmoothTextures = [MTLTexture?](repeating: nil, count: levelCount)

        // The blurs' row-pass scratch, one per level size, shared by that size's
        // blurs (hazard tracking orders the reuse).
        var scratchBySize: [Int: MTLTexture] = [:]
        func scratchTexture(width: Int, height: Int) -> MTLTexture? {
            let key = width * 1_000_000 + height
            if scratchBySize[key] == nil { scratchBySize[key] = lease.make(width: width, height: height) }
            return scratchBySize[key]
        }

        // Level 0: a single blur by `soffset`, used as both Lt and Lsmooth —
        // matching create_nonlinear_scale_space's own
        // `evolution[0].Lsmooth.copyTo(evolution[0].Lt)`. The kernel size is
        // buildPyramidReference's, `cvCeil(2(1 + (soffset - 0.8) / 0.3)) | 1`,
        // in float as it computes it — 9 for the default 1.6 — and the border
        // BORDER_REPLICATE, as every AKAZE blur is.
        let level0Size = Int((2 * (1 + (soffset - 0.8) / 0.3)).rounded(.up)) | 1
        guard let level0 = lease.make(width: imgCols, height: imgRows),
              let level0Scratch = scratchTexture(width: imgCols, height: imgRows),
              encodeGaussianBlur(cmdBuf, source: inputTexture, scratch: level0Scratch,
                                 destination: level0, sigma: Double(soffset),
                                 size: level0Size, replicateBorder: true)
        else { return nil }
        ltTextures[0] = level0
        lsmoothTextures[0] = level0

        var kcontrast = kcontrastBase
        var tstepOffset = 0
        let tstepsBuffer = tsteps.map { UnsafeBufferPointer(start: $0, count: tstepsCount) }

        for i in 1..<levelCount {
            let info = levels[i]
            let width = Int(info.width), height = Int(info.height)
            guard width > 0, height > 0 else { return nil }

            // Halve (new octave) or copy (same octave) the previous level's Lt,
            // producing THIS level's pre-diffusion Lt — matching
            // create_nonlinear_scale_space's own branch.
            guard let prevLt = ltTextures[i - 1] else { return nil }
            let levelLt: MTLTexture
            if info.newOctave != 0 {
                guard let halved = lease.make(width: width, height: height),
                      let xTable = MetalGPUBackend.areaResizeTable(source: prevLt.width,
                                                                   destination: width),
                      let yTable = MetalGPUBackend.areaResizeTable(source: prevLt.height,
                                                                   destination: height)
                else { return nil }
                var buffers: [MTLBuffer] = []
                for table in [xTable, yTable] {
                    guard let index = table.index.withUnsafeBytes({
                              device.makeBuffer(bytes: $0.baseAddress!, length: $0.count,
                                                options: .storageModeShared) }),
                          let weight = table.weight.withUnsafeBytes({
                              device.makeBuffer(bytes: $0.baseAddress!, length: $0.count,
                                                options: .storageModeShared) })
                    else { return nil }
                    buffers += [index, weight]
                }
                guard let encoder = cmdBuf.makeComputeCommandEncoder() else { return nil }
                encoder.setComputePipelineState(resizeAreaF32)
                encoder.setTexture(prevLt, index: 0)
                encoder.setTexture(halved, index: 1)
                for (slot, buffer) in buffers.enumerated() {
                    encoder.setBuffer(buffer, offset: 0, index: slot)
                }
                dispatch(encoder: encoder, pipeline: resizeAreaF32, width: width, height: height)
                encoder.endEncoding()
                levelLt = halved
                kcontrast *= 0.75
            } else {
                guard let copy = lease.make(width: width, height: height),
                      let blit = cmdBuf.makeBlitCommandEncoder()
                else { return nil }
                blit.copy(from: prevLt, sourceSlice: 0, sourceLevel: 0,
                         sourceOrigin: MTLOriginMake(0, 0, 0), sourceSize: MTLSizeMake(width, height, 1),
                         to: copy, destinationSlice: 0, destinationLevel: 0,
                         destinationOrigin: MTLOriginMake(0, 0, 0))
                blit.endEncoding()
                levelLt = copy
            }

            // Lsmooth: the fixed 5x5, sigma=1 blur of the pre-diffusion Lt, used
            // for this level's derivatives now and by
            // Compute_Determinant_Hessian_Response later. Five taps, not a full
            // Gaussian: truncated at 2 sigma it is narrower than its sigma says.
            guard let smooth = lease.make(width: width, height: height),
                  let smoothScratch = scratchTexture(width: width, height: height),
                  encodeGaussianBlur(cmdBuf, source: levelLt, scratch: smoothScratch,
                                     destination: smooth, sigma: 1.0, size: 5,
                                     replicateBorder: true)
            else { return nil }

            guard let lx = lease.make(width: width, height: height),
                  let ly = lease.make(width: width, height: height),
                  let flow = lease.make(width: width, height: height)
            else { return nil }
            guard let derivEncoder = cmdBuf.makeComputeCommandEncoder() else { return nil }
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
            guard stepCount == 0 || tstepsBuffer != nil else { return nil }
            for s in 0..<stepCount {
                guard let lstep = lease.make(width: width, height: height),
                      let stepEncoder = cmdBuf.makeComputeCommandEncoder()
                else { return nil }
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

        // Lt levels, then Lsmooth levels, each blitted into a linear shared buffer; the caller
        // reads them out after the slot is released. (Level 0 is the same texture in both.)
        let ltAll = ltTextures.compactMap { $0 }, smoothAll = lsmoothTextures.compactMap { $0 }
        guard ltAll.count == levelCount, smoothAll.count == levelCount else { return nil }
        guard let readbacks = encodeReadbacks(cmdBuf, textures: ltAll + smoothAll) else { return nil }

        commitAndWait(cmdBuf)
        guard cmdBuf.status == .completed else {
            giveReadbackBuffers(readbacks)
            return nil
        }
        return readbacks
    }

    /// Pooled `.r32Float` `.managed` textures; see `FloatTexturePool`.
    let texturePool = FloatTexturePool()

    fileprivate static func makeFloatTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
          pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .managed
        return device.makeTexture(descriptor: descriptor)
    }

    /// One texture's pixels, copied by the GPU into a linear shared buffer, waiting to be read out.
    fileprivate struct PendingReadback {
        let buffer: MTLBuffer
        let width: Int
        let height: Int
    }

    /// Linear `.shared` readback buffers kept between builds, by length (two per size). Making a
    /// frame-sized buffer per pyramid level was a large share of the time spent in a slot.
    private static let readbackPoolLock = NSLock()
    nonisolated(unsafe) private static var readbackPool: [Int: [MTLBuffer]] = [:]

    func trimReadbackPool() {
        Self.readbackPoolLock.withLock { Self.readbackPool.removeAll() }
    }

    private func takeReadbackBuffer(length: Int) -> MTLBuffer? {
        let reused: MTLBuffer? = Self.readbackPoolLock.withLock {
            var list = Self.readbackPool[length] ?? []
            let buffer = list.popLast()
            Self.readbackPool[length] = list
            return buffer
        }
        return reused ?? device.makeBuffer(length: length, options: .storageModeShared)
    }

    fileprivate func giveReadbackBuffers(_ readbacks: [PendingReadback]) {
        Self.readbackPoolLock.withLock {
            for readback in readbacks {
                var list = Self.readbackPool[readback.buffer.length] ?? []
                if list.count < 2 { list.append(readback.buffer) }
                Self.readbackPool[readback.buffer.length] = list
            }
        }
    }

    /// Encodes a GPU copy of every texture into its own linear buffer, in `cmdBuf`'s blit stage.
    /// The blit engine does the de-tiling, so the CPU side is a straight memcpy afterwards.
    private func encodeReadbacks(_ cmdBuf: MTLCommandBuffer, textures: [MTLTexture]) -> [PendingReadback]? {
        guard let blit = cmdBuf.makeBlitCommandEncoder() else { return nil }
        var readbacks: [PendingReadback] = []
        readbacks.reserveCapacity(textures.count)
        for texture in textures {
            let rowBytes = texture.width * MemoryLayout<Float>.size
            let length = rowBytes * texture.height
            guard let buffer = takeReadbackBuffer(length: length) else {
                blit.endEncoding()
                giveReadbackBuffers(readbacks)
                return nil
            }
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                      to: buffer, destinationOffset: 0,
                      destinationBytesPerRow: rowBytes, destinationBytesPerImage: length)
            readbacks.append(PendingReadback(buffer: buffer, width: texture.width, height: texture.height))
        }
        blit.endEncoding()
        return readbacks
    }

    /// Copies one finished readback buffer into a newly allocated, tightly-packed CV_32FC1
    /// MatWrapper (`mat_wrapper_new`: one allocation, no zero fill, no clone). Needs no GPU slot.
    fileprivate func matWrapper(fromReadback readback: PendingReadback) -> MatWrapperRef? {
        let rowBytes = readback.width * MemoryLayout<Float>.size
        let cvType = mat_wrapper_cv_type_for(32, 1)
        guard let ref = mat_wrapper_new(Int64(readback.width), Int64(readback.height), cvType) else { return nil }
        guard let data = mat_wrapper_data_ptr(ref), mat_wrapper_step(ref) == rowBytes else {
            mat_wrapper_release(ref)
            return nil
        }
        memcpy(UnsafeMutableRawPointer(mutating: data), readback.buffer.contents(), rowBytes * readback.height)
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

    // Where one destination pixel samples a warped source, and whether it samples
    // anything at all. Every warp kernel below goes through warp_tap and
    // warp_value, so the image warp, the coverage the merge counts and the fused
    // aligned merge cannot drift apart.
    struct WarpTap {
        int ix, iy;
        float w00, w10, w01, w11, wsum;
        bool v00, v10, v01, v11;
        bool covered;
    };

    // homography is the INVERSE mapping (dst -> src), row-major 3x3 -- the same
    // convention cv::warpPerspective uses internally for a forward-mapping H.
    // `covered` is false exactly where cv::warpPerspective's BORDER_TRANSPARENT
    // leaves the destination untouched: none of the four sample corners exist in
    // the source (or the projection degenerates).
    inline WarpTap warp_tap(constant float* hInv, int px, int py, int width, int height) {
        WarpTap t;
        t.covered = false;

        float x = float(px), y = float(py);
        float w = hInv[6] * x + hInv[7] * y + hInv[8];
        if (fabs(w) < 1e-12f) return t;
        float sx = (hInv[0] * x + hInv[1] * y + hInv[2]) / w;
        float sy = (hInv[3] * x + hInv[4] * y + hInv[5]) / w;
        if (!isfinite(sx) || !isfinite(sy)) return t;

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

        t.w00 = (1.0f - fx) * (1.0f - fy);
        t.w10 = fx * (1.0f - fy);
        t.w01 = (1.0f - fx) * fy;
        t.w11 = fx * fy;

        t.v00 = sample_valid(ix,     iy,     width, height);
        t.v10 = sample_valid(ix + 1, iy,     width, height);
        t.v01 = sample_valid(ix,     iy + 1, width, height);
        t.v11 = sample_valid(ix + 1, iy + 1, width, height);
        if (!t.v00 && !t.v10 && !t.v01 && !t.v11) return t;   // fully outside

        t.wsum = (t.v00 ? t.w00 : 0.0f) + (t.v10 ? t.w10 : 0.0f)
               + (t.v01 ? t.w01 : 0.0f) + (t.v11 ? t.w11 : 0.0f);
        if (t.wsum <= 1e-6f) return t;

        t.ix = ix;
        t.iy = iy;
        t.covered = true;
        return t;
    }

    // Channel `c` of a covered tap: the bilinear sample, renormalised by the
    // weights of the corners that exist, rounded to the pixel type.
    template <typename T, int MAXV>
    inline T warp_value(device const T* src, int srcStep, int channels, thread const WarpTap& t, int c) {
        float acc = 0;
        if (t.v00) acc += t.w00 * float(src[(size_t)t.iy * srcStep + (size_t)t.ix * channels + c]);
        if (t.v10) acc += t.w10 * float(src[(size_t)t.iy * srcStep + (size_t)(t.ix + 1) * channels + c]);
        if (t.v01) acc += t.w01 * float(src[(size_t)(t.iy + 1) * srcStep + (size_t)t.ix * channels + c]);
        if (t.v11) acc += t.w11 * float(src[(size_t)(t.iy + 1) * srcStep + (size_t)(t.ix + 1) * channels + c]);
        float val = acc / t.wsum;
        return T(clamp(val + 0.5f, 0.0f, float(MAXV)));
    }

    template <typename T, int MAXV>
    inline void warp_generic(device const T* src, device T* dst,
                             constant float* hInv,
                             int width, int height, int channels,
                             int srcStep, int dstStep, uint2 gid)
    {
        if ((int)gid.x >= width || (int)gid.y >= height) return;

        WarpTap t = warp_tap(hInv, int(gid.x), int(gid.y), width, height);
        if (!t.covered) return;   // dst stays zero

        size_t dstBase = (size_t)gid.y * (size_t)dstStep + (size_t)gid.x * (size_t)channels;
        for (int c = 0; c < channels; ++c) {
            dst[dstBase + c] = warp_value<T, MAXV>(src, srcStep, channels, t, c);
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

    // Sorts v[0, n) ascending in place and returns the sample medianMergeTyped
    // (ImageAligner.cpp) selects. The first `missCount` entries of the sorted
    // array are no-data zeros (absent sources read 0, the type's minimum, so
    // they sort to the front) and are skipped by count alone -- the
    // CoverageMisses contract. What is left is sigma-clipped at
    // mean + outlierThreshold * stddev, and the midpoint of what survives wins.
    // includeAll counts every source and skips the clip.
    inline float sigma_clipped_median(thread float* v, int n, int missCount, bool includeAll,
                                      float outlierThreshold) {
        // insertion sort ascending -- n <= 17
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
        return v[idx];
    }

    // Sources 1..16 of a merge, each bound at its own buffer index by the
    // kernels below (12...27; source 0 is at buffer 0).
    template <typename T>
    struct MergeSources {
        device const T* src[16];
    };

    // Each source is read where it is, with its own row step (`sourceSteps[i]`,
    // in elements): source 0 at buffer 0, sources 1...16 at buffers 12...27.
    // When `hasMisses` is set, `misses` (row step `missesStep`, in bytes) counts
    // per pixel how many of the FIRST misses[...] sources (in array order,
    // matching CoverageMisses in ImageAligner.cpp) have no sample there --
    // ignored when includeAllFlag != 0, in which case every source counts.
    template <typename T, int MAXV>
    inline void median_merge_generic(device const T* source0, thread const MergeSources<T>& rest,
                                     constant int* sourceSteps,
                                     device const uchar* misses, int missesStep, bool hasMisses,
                                     device T* dst, int dstStep,
                                     int width, int height, int channels, int count,
                                     float outlierThreshold, int includeAllFlag, uint2 gid)
    {
        if ((int)gid.x >= width || (int)gid.y >= height) return;
        const int x = int(gid.x), y = int(gid.y);
        const bool includeAll = includeAllFlag != 0;
        const int missCount = (includeAll || !hasMisses) ? 0 : int(misses[(size_t)y * missesStep + x]);

        for (int c = 0; c < channels; ++c) {
            float v[17];
            v[0] = float(source0[(size_t)y * sourceSteps[0] + (size_t)x * channels + c]);
            for (int i = 1; i < count; ++i) {
                v[i] = float(rest.src[i - 1][(size_t)y * sourceSteps[i] + (size_t)x * channels + c]);
            }
            const float picked = sigma_clipped_median(v, count, missCount, includeAll, outlierThreshold);
            dst[(size_t)y * dstStep + (size_t)x * channels + c] = T(clamp(picked, 0.0f, float(MAXV)));
        }
    }

    kernel void median_merge_u8(device const uchar* s0 [[buffer(0)]],
                                device uchar* dst [[buffer(1)]],
                                device const uchar* misses [[buffer(2)]],
                                constant int* sourceSteps [[buffer(3)]],
                                constant int& width [[buffer(4)]],
                                constant int& height [[buffer(5)]],
                                constant int& channels [[buffer(6)]],
                                constant int& dstStep [[buffer(7)]],
                                constant int& missesStep [[buffer(8)]],
                                constant int& count [[buffer(9)]],
                                constant float& outlierThreshold [[buffer(10)]],
                                constant int& includeAllFlag [[buffer(11)]],
                                device const uchar* s1 [[buffer(12)]],
                                device const uchar* s2 [[buffer(13)]],
                                device const uchar* s3 [[buffer(14)]],
                                device const uchar* s4 [[buffer(15)]],
                                device const uchar* s5 [[buffer(16)]],
                                device const uchar* s6 [[buffer(17)]],
                                device const uchar* s7 [[buffer(18)]],
                                device const uchar* s8 [[buffer(19)]],
                                device const uchar* s9 [[buffer(20)]],
                                device const uchar* s10 [[buffer(21)]],
                                device const uchar* s11 [[buffer(22)]],
                                device const uchar* s12 [[buffer(23)]],
                                device const uchar* s13 [[buffer(24)]],
                                device const uchar* s14 [[buffer(25)]],
                                device const uchar* s15 [[buffer(26)]],
                                device const uchar* s16 [[buffer(27)]],
                                constant int& hasMisses [[buffer(28)]],
                                uint2 gid [[thread_position_in_grid]])
    {
        MergeSources<uchar> rest = {{ s1, s2, s3, s4, s5, s6, s7, s8,
                                      s9, s10, s11, s12, s13, s14, s15, s16 }};
        median_merge_generic<uchar, 255>(s0, rest, sourceSteps, misses, missesStep, hasMisses != 0,
                                         dst, dstStep, width, height, channels, count,
                                         outlierThreshold, includeAllFlag, gid);
    }

    kernel void median_merge_u16(device const ushort* s0 [[buffer(0)]],
                                 device ushort* dst [[buffer(1)]],
                                 device const uchar* misses [[buffer(2)]],
                                 constant int* sourceSteps [[buffer(3)]],
                                 constant int& width [[buffer(4)]],
                                 constant int& height [[buffer(5)]],
                                 constant int& channels [[buffer(6)]],
                                 constant int& dstStep [[buffer(7)]],
                                 constant int& missesStep [[buffer(8)]],
                                 constant int& count [[buffer(9)]],
                                 constant float& outlierThreshold [[buffer(10)]],
                                 constant int& includeAllFlag [[buffer(11)]],
                                 device const ushort* s1 [[buffer(12)]],
                                 device const ushort* s2 [[buffer(13)]],
                                 device const ushort* s3 [[buffer(14)]],
                                 device const ushort* s4 [[buffer(15)]],
                                 device const ushort* s5 [[buffer(16)]],
                                 device const ushort* s6 [[buffer(17)]],
                                 device const ushort* s7 [[buffer(18)]],
                                 device const ushort* s8 [[buffer(19)]],
                                 device const ushort* s9 [[buffer(20)]],
                                 device const ushort* s10 [[buffer(21)]],
                                 device const ushort* s11 [[buffer(22)]],
                                 device const ushort* s12 [[buffer(23)]],
                                 device const ushort* s13 [[buffer(24)]],
                                 device const ushort* s14 [[buffer(25)]],
                                 device const ushort* s15 [[buffer(26)]],
                                 device const ushort* s16 [[buffer(27)]],
                                 constant int& hasMisses [[buffer(28)]],
                                 uint2 gid [[thread_position_in_grid]])
    {
        MergeSources<ushort> rest = {{ s1, s2, s3, s4, s5, s6, s7, s8,
                                       s9, s10, s11, s12, s13, s14, s15, s16 }};
        median_merge_generic<ushort, 65535>(s0, rest, sourceSteps, misses, missesStep, hasMisses != 0,
                                            dst, dstStep, width, height, channels, count,
                                            outlierThreshold, includeAllFlag, gid);
    }

    // One frame's whole aligned merge in one pass: for every destination pixel,
    // warp each neighbour to it on the spot, count the neighbours whose warp does
    // not reach it, and merge them with the base -- the result warp_generic
    // (once for each neighbour, and once more over a solid probe for its
    // coverage) followed by median_merge_generic produces, without a warped copy
    // of any neighbour ever existing. A neighbour that does not
    // reach a pixel contributes a zero there and one to its miss count, the
    // CoverageMisses contract medianMergeTyped (ImageAligner.cpp) depends on.
    //
    // The tap is recomputed per channel rather than kept for all neighbours at
    // once: sixteen taps' worth of registers would spill, and the arithmetic it
    // saves is a rounding error next to the memory traffic.
    template <typename T, int MAXV>
    inline void aligned_merge_generic(device const T* base, device T* dst,
                                      thread const MergeSources<T>& neighbours,
                                      constant int* neighbourSteps, constant float* hInv,
                                      int width, int height, int channels,
                                      int baseStep, int dstStep, int neighbourCount,
                                      float outlierThreshold, int includeAllFlag, uint2 gid)
    {
        if ((int)gid.x >= width || (int)gid.y >= height) return;
        const int x = int(gid.x), y = int(gid.y);
        const bool includeAll = includeAllFlag != 0;
        const int n = neighbourCount + 1;
        int missCount = 0;

        for (int c = 0; c < channels; ++c) {
            float v[17];
            v[0] = float(base[(size_t)y * baseStep + (size_t)x * channels + c]);
            for (int i = 0; i < neighbourCount; ++i) {
                WarpTap t = warp_tap(hInv + i * 9, x, y, width, height);
                if (t.covered) {
                    v[i + 1] = float(warp_value<T, MAXV>(neighbours.src[i], neighbourSteps[i], channels, t, c));
                } else {
                    v[i + 1] = 0.0f;
                    if (c == 0) ++missCount;
                }
            }
            const float picked = sigma_clipped_median(v, n, includeAll ? 0 : missCount, includeAll,
                                                      outlierThreshold);
            dst[(size_t)y * dstStep + (size_t)x * channels + c] = T(clamp(picked, 0.0f, float(MAXV)));
        }
    }

    kernel void aligned_merge_u8(device const uchar* base [[buffer(0)]],
                                 device uchar* dst [[buffer(1)]],
                                 constant float* hInv [[buffer(2)]],
                                 constant int* neighbourSteps [[buffer(3)]],
                                 constant int& width [[buffer(4)]],
                                 constant int& height [[buffer(5)]],
                                 constant int& channels [[buffer(6)]],
                                 constant int& baseStep [[buffer(7)]],
                                 constant int& dstStep [[buffer(8)]],
                                 constant int& neighbourCount [[buffer(9)]],
                                 constant float& outlierThreshold [[buffer(10)]],
                                 constant int& includeAllFlag [[buffer(11)]],
                                 device const uchar* n0 [[buffer(12)]],
                                 device const uchar* n1 [[buffer(13)]],
                                 device const uchar* n2 [[buffer(14)]],
                                 device const uchar* n3 [[buffer(15)]],
                                 device const uchar* n4 [[buffer(16)]],
                                 device const uchar* n5 [[buffer(17)]],
                                 device const uchar* n6 [[buffer(18)]],
                                 device const uchar* n7 [[buffer(19)]],
                                 device const uchar* n8 [[buffer(20)]],
                                 device const uchar* n9 [[buffer(21)]],
                                 device const uchar* n10 [[buffer(22)]],
                                 device const uchar* n11 [[buffer(23)]],
                                 device const uchar* n12 [[buffer(24)]],
                                 device const uchar* n13 [[buffer(25)]],
                                 device const uchar* n14 [[buffer(26)]],
                                 device const uchar* n15 [[buffer(27)]],
                                 uint2 gid [[thread_position_in_grid]])
    {
        MergeSources<uchar> neighbours = {{ n0, n1, n2, n3, n4, n5, n6, n7,
                                                 n8, n9, n10, n11, n12, n13, n14, n15 }};
        aligned_merge_generic<uchar, 255>(base, dst, neighbours, neighbourSteps, hInv,
                                          width, height, channels, baseStep, dstStep,
                                          neighbourCount, outlierThreshold, includeAllFlag, gid);
    }

    kernel void aligned_merge_u16(device const ushort* base [[buffer(0)]],
                                  device ushort* dst [[buffer(1)]],
                                  constant float* hInv [[buffer(2)]],
                                  constant int* neighbourSteps [[buffer(3)]],
                                  constant int& width [[buffer(4)]],
                                  constant int& height [[buffer(5)]],
                                  constant int& channels [[buffer(6)]],
                                  constant int& baseStep [[buffer(7)]],
                                  constant int& dstStep [[buffer(8)]],
                                  constant int& neighbourCount [[buffer(9)]],
                                  constant float& outlierThreshold [[buffer(10)]],
                                  constant int& includeAllFlag [[buffer(11)]],
                                  device const ushort* n0 [[buffer(12)]],
                                  device const ushort* n1 [[buffer(13)]],
                                  device const ushort* n2 [[buffer(14)]],
                                  device const ushort* n3 [[buffer(15)]],
                                  device const ushort* n4 [[buffer(16)]],
                                  device const ushort* n5 [[buffer(17)]],
                                  device const ushort* n6 [[buffer(18)]],
                                  device const ushort* n7 [[buffer(19)]],
                                  device const ushort* n8 [[buffer(20)]],
                                  device const ushort* n9 [[buffer(21)]],
                                  device const ushort* n10 [[buffer(22)]],
                                  device const ushort* n11 [[buffer(23)]],
                                  device const ushort* n12 [[buffer(24)]],
                                  device const ushort* n13 [[buffer(25)]],
                                  device const ushort* n14 [[buffer(26)]],
                                  device const ushort* n15 [[buffer(27)]],
                                  uint2 gid [[thread_position_in_grid]])
    {
        MergeSources<ushort> neighbours = {{ n0, n1, n2, n3, n4, n5, n6, n7,
                                                  n8, n9, n10, n11, n12, n13, n14, n15 }};
        aligned_merge_generic<ushort, 65535>(base, dst, neighbours, neighbourSteps, hInv,
                                             width, height, channels, baseStep, dstStep,
                                             neighbourCount, outlierThreshold, includeAllFlag, gid);
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

    // cv::resize(src, dst, 2x, INTER_LINEAR) for float: each destination pixel
    // maps to (d + 0.5) / 2 - 0.5 in the source, and a sample that falls off
    // either end takes the edge pixel with no blend -- resize's own coefficient
    // rule, not a texture sampler's. Horizontal interpolation first, then
    // vertical, in the order HResizeLinear/VResizeLinear apply them.
    inline void linear_2x_tap(int d, int len, thread int &s0, thread int &s1, thread float &f) {
        float fx = (float(d) + 0.5f) * 0.5f - 0.5f;
        int s = int(floor(fx));
        f = fx - float(s);
        if (s < 0) { s = 0; f = 0.0f; }
        if (s >= len - 1) { s = len - 1; f = 0.0f; }
        s0 = s;
        s1 = min(s + 1, len - 1);
    }

    kernel void upsample_linear_2x_f32(texture2d<float, access::read> src [[texture(0)]],
                                       texture2d<float, access::write> dst [[texture(1)]],
                                       uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        int x0, x1, y0, y1;
        float fx, fy;
        linear_2x_tap(int(gid.x), int(src.get_width()), x0, x1, fx);
        linear_2x_tap(int(gid.y), int(src.get_height()), y0, y1, fy);
        float r0 = src.read(uint2(x0, y0)).r * (1.0f - fx) + src.read(uint2(x1, y0)).r * fx;
        float r1 = src.read(uint2(x0, y1)).r * (1.0f - fx) + src.read(uint2(x1, y1)).r * fx;
        dst.write(float4(r0 * (1.0f - fy) + r1 * fy, 0.0, 0.0, 0.0), gid);
    }

    // cv::BORDER_REFLECT_101 (BORDER_DEFAULT), borderInterpolate's own loop: the
    // repeat matters at the pyramid's last octaves, which are narrower than the
    // kernel is wide.
    inline int reflect_101(int p, int len) {
        if (len == 1) return 0;
        while (p < 0 || p >= len) p = p < 0 ? -p : 2 * len - p - 2;
        return p;
    }

    // cv::BORDER_REPLICATE when `replicate` is set (AKAZE's blurs), otherwise
    // BORDER_REFLECT_101 (cv::GaussianBlur's default, SIFT's).
    inline int blur_border(int p, int len, int replicate) {
        return replicate != 0 ? clamp(p, 0, len - 1) : reflect_101(p, len);
    }

    // One pass of cv::GaussianBlur's separable filter: `weights` holds the 2r+1
    // coefficients cv::getGaussianKernel gives (see `openCVGaussianKernel`), and
    // the row pass runs first, as sepFilter2D does.
    kernel void gaussian_row_f32(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant float *weights [[buffer(0)]],
                                 constant int &radius [[buffer(1)]],
                                 constant int &replicate [[buffer(2)]],
                                 uint2 gid [[thread_position_in_grid]])
    {
        int w = int(src.get_width()), h = int(src.get_height());
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        float sum = 0.0f;
        for (int k = -radius; k <= radius; k++) {
            int x = blur_border(int(gid.x) + k, w, replicate);
            sum += weights[k + radius] * src.read(uint2(x, gid.y)).r;
        }
        dst.write(float4(sum, 0.0, 0.0, 0.0), gid);
    }

    kernel void gaussian_column_f32(texture2d<float, access::read> src [[texture(0)]],
                                    texture2d<float, access::write> dst [[texture(1)]],
                                    constant float *weights [[buffer(0)]],
                                    constant int &radius [[buffer(1)]],
                                    constant int &replicate [[buffer(2)]],
                                    uint2 gid [[thread_position_in_grid]])
    {
        int w = int(src.get_width()), h = int(src.get_height());
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        float sum = 0.0f;
        for (int k = -radius; k <= radius; k++) {
            int y = blur_border(int(gid.y) + k, h, replicate);
            sum += weights[k + radius] * src.read(uint2(gid.x, y)).r;
        }
        dst.write(float4(sum, 0.0, 0.0, 0.0), gid);
    }

    // cv::resize(..., INTER_AREA) for a downscale -- AKAZEDetector.cpp's own octave
    // halving (create_nonlinear_scale_space's `if (e.octave > ...)` branch) --
    // through computeResizeAreaTab's own tables, built on the CPU in double (see
    // `areaResizeTable`). A level is (int)(size / 2^octave) of the *original*, so
    // an odd dimension makes the scale 2.0006 rather than 2 and the taps drift a
    // whole source pixel across the frame; a plain 2x2 average cannot follow it.
    // Each destination pixel sums up to four source columns in each of up to four
    // source rows, columns first and then rows, as ResizeArea_Invoker does.
    kernel void resize_area_f32(texture2d<float, access::read> src [[texture(0)]],
                                texture2d<float, access::write> dst [[texture(1)]],
                                device const int *xIndex [[buffer(0)]],
                                device const float *xWeight [[buffer(1)]],
                                device const int *yIndex [[buffer(2)]],
                                device const float *yWeight [[buffer(3)]],
                                uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        float sum = 0.0f;
        for (uint j = 0; j < 4; j++) {
            int sy = yIndex[gid.y * 4 + j];
            if (sy < 0) break;
            float row = 0.0f;
            for (uint i = 0; i < 4; i++) {
                int sx = xIndex[gid.x * 4 + i];
                if (sx < 0) break;
                row += src.read(uint2(sx, sy)).r * xWeight[gid.x * 4 + i];
            }
            sum += yWeight[gid.y * 4 + j] * row;
        }
        dst.write(float4(sum, 0.0, 0.0, 0.0), gid);
    }

    // cv::Scharr's BORDER_DEFAULT (reflect-101) read for the 3x3 kernels below.
    inline float read_reflect_101(texture2d<float, access::read> tex, int x, int y) {
        x = reflect_101(x, int(tex.get_width()));
        y = reflect_101(y, int(tex.get_height()));
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
        float v = -3.0f * read_reflect_101(src, x - 1, y - 1) + 3.0f * read_reflect_101(src, x + 1, y - 1)
                - 10.0f * read_reflect_101(src, x - 1, y    ) + 10.0f * read_reflect_101(src, x + 1, y    )
                 - 3.0f * read_reflect_101(src, x - 1, y + 1) + 3.0f * read_reflect_101(src, x + 1, y + 1);
        dst.write(float4(v, 0.0, 0.0, 0.0), gid);
    }

    // 3x3 Scharr, Y direction: Gy = [-3 -10 -3; 0 0 0; 3 10 3].
    kernel void scharr_y_f32(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
        int x = int(gid.x), y = int(gid.y);
        float v = -3.0f * read_reflect_101(src, x - 1, y - 1) - 10.0f * read_reflect_101(src, x, y - 1)
                 - 3.0f * read_reflect_101(src, x + 1, y - 1)
                 + 3.0f * read_reflect_101(src, x - 1, y + 1) + 10.0f * read_reflect_101(src, x, y + 1)
                 + 3.0f * read_reflect_101(src, x + 1, y + 1);
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
