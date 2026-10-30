// ImageAligner.swift — Swift wrapper for image alignment operations
import Foundation
import StarCpp

public enum ImageAligner {

    /// Merge `image` with the frames named by `filenames`.
    ///
    /// When holding every source at once would exceed `streamingThresholdBytes`, the
    /// sources are streamed from raw scratch files under `scratchDir` instead, which
    /// bounds peak memory at the cost of writing and re-reading each source once. The
    /// output is bit-identical either way. Pass 0 to disable streaming.
    ///
    /// `loadConcurrency` is how many sources are decoded at once while they are all
    /// being held resident; 1 is the old one-at-a-time loop. It cannot change the
    /// result — the merge sorts each pixel's samples before using them, so source order
    /// never reaches the answer, and the sources are collected in file order anyway.
    /// Ignored on the streaming path, which stays serial by design.
    ///
    /// `useGPU` only ever applies to the all-resident path (never streaming), and even
    /// there is a request, not a guarantee — see `GPUCapability`. On by default so a
    /// caller that does not think about GPU acceleration gets it when the machine
    /// supports it, same as `Config.useGPUForMerge`'s own default.
    public static func medianMergeImage(_ image: MatWrapper, withFilenames filenames: [String],
                                         outlierThreshold: Double, includeAll: Bool,
                                         scratchDir: String? = nil,
                                         streamingThresholdBytes: Int64 = 0,
                                         loadConcurrency: Int = 1,
                                         useGPU: Bool = true) -> MatWrapper? {
        let cStrs = filenames.map { strdup($0) }
        defer { cStrs.forEach { free($0) } }
        var ptrs = cStrs.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        let r = ptrs.withUnsafeMutableBufferPointer { buf in
            ia_median_merge_image_with_filenames(image.ref,
                                                  buf.baseAddress,
                                                  Int32(buf.count),
                                                  outlierThreshold, includeAll,
                                                  scratchDir,
                                                  streamingThresholdBytes,
                                                  Int32(loadConcurrency),
                                                  useGPU)
        }
        // nil when the C++ merge could not produce an image (unreadable source, allocation)
        return r.map { MatWrapper(ref: $0) }
    }

    public static func medianMergeFilenames(_ filenames: [String],
                                             outlierThreshold: Double,
                                             includeAll: Bool,
                                             useGPU: Bool = true) -> MatWrapper? {
        let cStrs = filenames.map { strdup($0) }
        defer { cStrs.forEach { free($0) } }
        var ptrs = cStrs.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        let r = ptrs.withUnsafeMutableBufferPointer { buf in
            ia_median_merge_filenames(buf.baseAddress, Int32(buf.count),
                                      outlierThreshold, includeAll, useGPU)
        }
        return r.map { MatWrapper(ref: $0) }
    }

    public static func findFeatures(baseImage: MatWrapper, frameIndex: Int32,
                                     matchMethod: FeatureMatchMethod,
                                     mask: MatWrapper?,
                                     alignmentType: AlignmentType,
                                     maxKeypoints: Int32,
                                     writeDebugImages: Bool,
                                     groundHorizonExtension: Int32,
                                     skyHorizonExtension: Int32,
                                     baseImageDilateSize: Int32,
                                     baseImageThresholdValue: Int32,
                                     detectionScale: Double = 1.0,
                                     useGPUForSift: Bool = false,
                                     useGPUForAKAZE: Bool = false) -> OCVFeatureSet? {
        var errMsg: UnsafePointer<CChar>?
        guard let r = ia_find_features(baseImage.ref, frameIndex,
                                        matchMethod, mask?.ref,
                                        alignmentType, maxKeypoints,
                                        writeDebugImages,
                                        groundHorizonExtension,
                                        skyHorizonExtension,
                                        baseImageDilateSize,
                                        baseImageThresholdValue,
                                        detectionScale,
                                        useGPUForSift,
                                        useGPUForAKAZE,
                                        &errMsg) else { return nil }
        return OCVFeatureSet(ref: r)
    }

    /// Test-only: the from-scratch SIFT port directly, without cv::SIFT as a
    /// fallback — see `ia_debug_sift_reference`/`ia_debug_sift_gpu`'s comments
    /// for why these exist. `img` must be CV_8U grayscale.
    public static func debugSiftReference(_ img: MatWrapper, mask: MatWrapper?,
                                          nfeatures: Int32) -> OCVFeatureSet? {
        ia_debug_sift_reference(img.ref, mask?.ref, nfeatures).map { OCVFeatureSet(ref: $0) }
    }

    public static func debugSiftGPU(_ img: MatWrapper, mask: MatWrapper?,
                                    nfeatures: Int32) -> OCVFeatureSet? {
        ia_debug_sift_gpu(img.ref, mask?.ref, nfeatures).map { OCVFeatureSet(ref: $0) }
    }

    /// Real cv::SIFT, called directly with the same raw-input contract as
    /// `debugSiftReference`/`debugSiftGPU` — see `ia_debug_sift_opencv`.
    public static func debugSiftOpenCV(_ img: MatWrapper, mask: MatWrapper?,
                                       nfeatures: Int32) -> OCVFeatureSet? {
        ia_debug_sift_opencv(img.ref, mask?.ref, nfeatures).map { OCVFeatureSet(ref: $0) }
    }

    /// Test-only: the from-scratch AKAZE port directly, without cv::AKAZE as a
    /// fallback — see `ia_debug_akaze_reference`/`ia_debug_akaze_gpu`'s
    /// comments for why these exist. `img` must be CV_8U grayscale.
    public static func debugAkazeReference(_ img: MatWrapper, mask: MatWrapper?,
                                           maxKeypoints: Int32, threshold: Float) -> OCVFeatureSet? {
        ia_debug_akaze_reference(img.ref, mask?.ref, maxKeypoints, threshold)
          .map { OCVFeatureSet(ref: $0) }
    }

    public static func debugAkazeGPU(_ img: MatWrapper, mask: MatWrapper?,
                                     maxKeypoints: Int32, threshold: Float) -> OCVFeatureSet? {
        ia_debug_akaze_gpu(img.ref, mask?.ref, maxKeypoints, threshold)
          .map { OCVFeatureSet(ref: $0) }
    }

    /// Real cv::AKAZE, called directly with the same raw-input contract as
    /// `debugAkazeReference`/`debugAkazeGPU` — see `ia_debug_akaze_opencv`.
    public static func debugAkazeOpenCV(_ img: MatWrapper, mask: MatWrapper?,
                                        maxKeypoints: Int32, threshold: Float) -> OCVFeatureSet? {
        ia_debug_akaze_opencv(img.ref, mask?.ref, maxKeypoints, threshold)
          .map { OCVFeatureSet(ref: $0) }
    }

    /// `imageWidth` and `imageHeight` are the full-resolution frame's: the ground is fitted
    /// as a camera rotation about the frame's centre, so earth alignment returns nil
    /// without them.  The sky does not read them.
    public static func computeHomography(baseKeypoints: OCVFeatureSet,
                                          frameIndex: Int32,
                                          neighbors: [AlignmentNeighborInfo],
                                          matchMethod: FeatureMatchMethod,
                                          alignmentType: AlignmentType,
                                          maxKeypoints: Int32,
                                          writeDebugImages: Bool,
                                          imageWidth: Int32,
                                          imageHeight: Int32,
                                          handler: @escaping (Int32, AlignmentType, ObjCAlignmentStep, Int32) -> Void) -> HomographyResult? {
        let cNeighbors = neighbors.map { n in
            AlignmentNeighborData(filename: strdup(n.filename),
                                   maskFilename: n.maskFilename.flatMap { strdup($0) },
                                   keypoints: n.keypoints?.ref,
                                   frameIndex: n.frameIndex)
        }
        defer {
            for n in cNeighbors {
                free(UnsafeMutablePointer(mutating: n.filename))
                if let m = n.maskFilename { free(UnsafeMutablePointer(mutating: m)) }
            }
        }

        // Store handler in a box for the C callback
        class HandlerBox { var handler: (Int32, AlignmentType, ObjCAlignmentStep, Int32) -> Void
            init(_ h: @escaping (Int32, AlignmentType, ObjCAlignmentStep, Int32) -> Void) { handler = h }
        }
        let box = HandlerBox(handler)
        let boxPtr = Unmanaged.passRetained(box).toOpaque()

        var outWarpInfos = [AlignmentWarpInfoData](repeating: AlignmentWarpInfoData(), count: neighbors.count)
        var errMsg: UnsafePointer<CChar>?

        let count = cNeighbors.withUnsafeBufferPointer { nBuf in
            outWarpInfos.withUnsafeMutableBufferPointer { wBuf in
                ia_compute_homography(baseKeypoints.ref, frameIndex,
                                       nBuf.baseAddress, Int32(nBuf.count),
                                       matchMethod, alignmentType,
                                       maxKeypoints, writeDebugImages,
                                       imageWidth, imageHeight,
                                       { frameIdx, aType, step, neighborNum, ctx in
                                           let b = Unmanaged<HandlerBox>.fromOpaque(ctx!).takeUnretainedValue()
                                           b.handler(frameIdx, aType, step, neighborNum)
                                       }, boxPtr,
                                       wBuf.baseAddress, &errMsg)
            }
        }

        Unmanaged<HandlerBox>.fromOpaque(boxPtr).release()

        guard count > 0 else { return nil }

        let warpInfos = outWarpInfos.prefix(Int(count)).map { data in
            AlignmentWarpInfo(homography: data.homography.flatMap { MatWrapper(ref: $0) },
                              deviation: data.deviation,
                              alignmentState: data.alignmentState,
                              frameIndex: Int(data.frameIndex))
        }

        return HomographyResult(frameIndex: Int(frameIndex), warpInfo: warpInfos)
    }

    /// Warp `neighbors` with `homography` and median merge them with `baseImage`,
    /// returning the merged frame and how many neighbours went into it.
    ///
    /// Fused deliberately: `align` hands every warp back to Swift, so all of them are
    /// live when the merge starts — the original plus eight warps plus the output is
    /// ten whole frames. Keeping the warps inside the C++ call is what lets each one
    /// be spilled to a scratch file under `scratchDir` and released immediately once
    /// the set would exceed `streamingThresholdBytes`. Pass 0 to keep them resident;
    /// the output is identical either way.
    ///
    /// `cloudAware` adds the cloud-aware stage after the merge: it measures how clouds
    /// move against the stars, merges the neighbours a second time aligned to the
    /// cloud, and uses that merge wherever it explains `baseImage` better than the
    /// star merge does, with the stars put back. Clear sky comes out byte-identical to
    /// the plain merge. `skyMask` (white = sky) keeps it off the ground; nil means the
    /// whole frame is sky. `cloudDebugDir` makes it write its blend weight and motion
    /// field there. With `cloudAware` false all three are ignored.
    ///
    /// Returns nil when no neighbour could be warped, which is the caller's cue to
    /// fall back to the unaligned frame.
    public static func alignAndMedianMerge(baseImage: MatWrapper,
                                            baseFrameIndex: Int32,
                                            neighbors: [AlignmentNeighborInfo],
                                            homography: [Int: MatWrapper],
                                            outlierThreshold: Double,
                                            includeAll: Bool,
                                            scratchDir: String? = nil,
                                            streamingThresholdBytes: Int64 = 0,
                                            loadConcurrency: Int = 1,
                                            useGPU: Bool = true,
                                            cloudAware: Bool = false,
                                            skyMask: MatWrapper? = nil,
                                            cloudDebugDir: String? = nil)
      -> (merged: MatWrapper, warpCount: Int)?
    {
        let cNeighbors = neighbors.map { n in
            AlignmentNeighborData(filename: strdup(n.filename),
                                   maskFilename: n.maskFilename.flatMap { strdup($0) },
                                   keypoints: n.keypoints?.ref,
                                   frameIndex: n.frameIndex)
        }
        defer {
            for n in cNeighbors {
                free(UnsafeMutablePointer(mutating: n.filename))
                if let m = n.maskFilename { free(UnsafeMutablePointer(mutating: m)) }
            }
        }

        let sortedKeys = homography.keys.sorted()
        var keys = sortedKeys.map { Int32($0) }
        var values = sortedKeys.map { homography[$0]!.ref as MatWrapperRef? }

        var warpCount: Int32 = 0
        var errMsg: UnsafePointer<CChar>?

        let merged = cNeighbors.withUnsafeBufferPointer { nBuf in
            keys.withUnsafeMutableBufferPointer { kBuf in
                values.withUnsafeMutableBufferPointer { vBuf in
                    ia_align_and_median_merge(baseImage.ref, baseFrameIndex,
                                               nBuf.baseAddress, Int32(nBuf.count),
                                               kBuf.baseAddress, vBuf.baseAddress,
                                               Int32(kBuf.count),
                                               outlierThreshold, includeAll,
                                               scratchDir,
                                               streamingThresholdBytes,
                                               Int32(loadConcurrency),
                                               useGPU,
                                               cloudAware,
                                               skyMask?.ref,
                                               cloudDebugDir,
                                               &warpCount, &errMsg)
                }
            }
        }

        guard let merged else { return nil }
        return (MatWrapper(ref: merged), Int(warpCount))
    }

    /// Accumulate horizon masks from files using a producer/consumer pipeline and
    /// return a binary mask via majority vote (>50 % non-zero → white).
    public static func accumulateHorizonMasks(filenames: [String]) -> MatWrapper? {
        let cStrs = filenames.map { strdup($0) }
        defer { cStrs.forEach { free($0) } }
        var ptrs = cStrs.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        let r = ptrs.withUnsafeMutableBufferPointer { buf in
            ia_accumulate_horizon_masks(buf.baseAddress, Int32(buf.count))
        }
        return r.map { MatWrapper(ref: $0) }
    }

    /// Add a single in-memory horizon mask to a running CV_32S pixel-count accumulator.
    /// Pass nil for `accum` on the first call; pass the previous result on subsequent calls.
    public static func accumulateOneHorizonMask(_ accum: MatWrapper?, mask: MatWrapper) -> MatWrapper? {
        let r = ia_accumulate_one_horizon_mask(accum?.ref, mask.ref)
        return r.map { MatWrapper(ref: $0) }
    }

    /// Load horizon masks from files and add them to an existing CV_32S accumulator.
    /// Pass nil for `accum` to start a fresh accumulation from the files only.
    ///
    /// Returns the new total and, per file, whether it was actually loaded and added (a missing
    /// file is skipped, and must not count towards a vote).
    public static func accumulateFromFiles(_ accum: MatWrapper?,
                                           filenames: [String]) -> (total: MatWrapper?, loaded: [Bool])
    {
        guard !filenames.isEmpty else { return (accum, []) }
        let cStrs = filenames.map { strdup($0) }
        defer { cStrs.forEach { free($0) } }
        var ptrs = cStrs.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        var loadedFlags = [UInt8](repeating: 0, count: filenames.count)
        let r = ptrs.withUnsafeMutableBufferPointer { buf in
            loadedFlags.withUnsafeMutableBufferPointer { flags in
                ia_accumulate_from_files(accum?.ref, buf.baseAddress, Int32(buf.count), flags.baseAddress)
            }
        }
        return (r.map { MatWrapper(ref: $0) }, loadedFlags.map { $0 != 0 })
    }

    /// Apply majority-vote threshold to a CV_32S accumulator and return a binary mask.
    /// Pixels seen in more than half of `totalCount` frames become white (255), rest black (0).
    public static func finalizeHorizonAccumulation(_ accum: MatWrapper, totalCount: Int) -> MatWrapper? {
        let r = ia_finalize_horizon_accumulation(accum.ref, Int32(totalCount))
        return r.map { MatWrapper(ref: $0) }
    }

    public static func createGradientMaskIntoSky(_ binaryMask: MatWrapper,
                                                   gradientDistance: Int32) -> MatWrapper? {
        let r: MatWrapperRef? = ia_gradient_mask_into_sky(binaryMask.ref, gradientDistance)
        return r.map { MatWrapper(ref: $0) }
    }

    public static func createGradientMaskIntoGround(_ binaryMask: MatWrapper,
                                                      gradientDistance: Int32) -> MatWrapper {
        MatWrapper(ref: ia_gradient_mask_into_ground(binaryMask.ref, gradientDistance))
    }

    /// The 8-bit gray that feature detection runs on: `image` stretched across 0-255
    /// over the range `mask` selects, and zeroed outside it.
    public static func maskedStretchToGray8(_ image: MatWrapper,
                                            mask: MatWrapper?) -> MatWrapper? {
        let r = ia_masked_stretch_to_gray8(image.ref, mask?.ref)
        return r.map { MatWrapper(ref: $0) }
    }

    /// Test-only: the raw warp, with no merge picking a value around it. See
    /// `ia_debug_warp`'s comment for why this exists and where it does not belong.
    public static func debugWarp(_ src: MatWrapper, homography: MatWrapper,
                                 useGPU: Bool) -> MatWrapper? {
        let r = ia_debug_warp(src.ref, homography.ref, useGPU)
        return r.map { MatWrapper(ref: $0) }
    }

    /// Test-only: the CPU warp the merge uses for 16-bit frames (`true`, the default) or
    /// cv::warpPerspective itself (`false`).  See `ia_debug_set_exact_warp`; process-wide,
    /// restore it when done.
    public static func debugSetExactWarp(enabled: Bool) {
        ia_debug_set_exact_warp(enabled)
    }

    /// Test-only: whether there is an exact CPU warp on this machine for the other to be
    /// compared with.
    public static var debugExactWarpIsAvailable: Bool { ia_debug_exact_warp_is_available() }

    /// Test-only: the pair-shared descriptor matching the alignment ops use (`true`, the default)
    /// or OpenCV's BFMatcher on its own (`false`).  See `ia_debug_set_pair_match`; process-wide,
    /// restore it when done.
    public static func debugSetPairMatch(enabled: Bool) {
        ia_debug_set_pair_match(enabled)
    }

    /// Test-only: how many pair matches are waiting for their partner's op; `clear` empties
    /// them first.
    public static func debugPairMatchWaiting(clear: Bool = false) -> Int {
        Int(ia_debug_pair_match_waiting(clear))
    }

    /// Test-only: random descriptor sets through the pair matcher and BFMatcher in both
    /// directions; the number of results that differ (0 is a pass).
    public static func debugPairMatchSelfTest(trials: Int, seed: UInt32) -> Int {
        Int(ia_debug_pair_match_selftest(Int32(trials), seed))
    }

    /// Test-only: force the Welford reference median kernel (`true`) or let the machine pick
    /// (`false`).  See `ia_debug_set_median_kernel`; process-wide, restore it when done.
    public static func debugSetMedianKernel(forceReference: Bool) {
        ia_debug_set_median_kernel(forceReference)
    }

    /// Test-only: whether the machine's own choice is the exact-statistics kernel, i.e.
    /// whether there is a second kernel for the reference to be compared with.
    public static var debugMedianKernelIsExact: Bool { ia_debug_median_kernel_is_exact() }

    /// Test-only: the raw merge of `sources` (the base first), with the coverage
    /// plane given rather than derived. See `ia_debug_median_merge`'s comment.
    public static func debugMedianMerge(_ sources: [MatWrapper], misses: MatWrapper?,
                                        outlierThreshold: Double, includeAll: Bool,
                                        useGPU: Bool) -> MatWrapper? {
        var refs = sources.map { $0.ref as MatWrapperRef? }
        let r = refs.withUnsafeMutableBufferPointer { buf in
            ia_debug_median_merge(buf.baseAddress, Int32(buf.count), misses?.ref,
                                  outlierThreshold, includeAll, useGPU)
        }
        return r.map { MatWrapper(ref: $0) }
    }
}

// MARK: - Supporting types

public struct AlignmentNeighborInfo: Sendable {
    public let filename: String
    public let maskFilename: String?
    public let keypoints: OCVFeatureSet?
    public let frameIndex: Int32

    public init(filename: String, maskFilename: String?, keypoints: OCVFeatureSet?, frameIndex: Int32) {
        self.filename = filename
        self.maskFilename = maskFilename
        self.keypoints = keypoints
        self.frameIndex = frameIndex
    }
}

public struct AlignmentWarpInfo: Sendable {
    public let homography: MatWrapper?
    public let deviation: Double
    public let alignmentState: AlignmentStateObjC
    public let frameIndex: Int

    public init(homography: MatWrapper?, deviation: Double, alignmentState: AlignmentStateObjC, frameIndex: Int) {
        self.homography = homography
        self.deviation = deviation
        self.alignmentState = alignmentState
        self.frameIndex = frameIndex
    }
}

public struct HomographyResult: Sendable {
    public let frameIndex: Int
    public let warpInfo: [AlignmentWarpInfo]

    public init(frameIndex: Int, warpInfo: [AlignmentWarpInfo]) {
        self.frameIndex = frameIndex
        self.warpInfo = warpInfo
    }
}

public struct WarpedImageResult: Sendable {
    public let warpedFrame: MatWrapper?
    public let warpedHorizon: MatWrapper?

    public init(warpedFrame: MatWrapper?, warpedHorizon: MatWrapper?) {
        self.warpedFrame = warpedFrame
        self.warpedHorizon = warpedHorizon
    }
}

public struct AlignmentResult: Sendable {
    public let alignedMat: MatWrapper?
    public let failedMat: MatWrapper?
    public let horizonMask: MatWrapper?

    public init(alignedMat: MatWrapper?, failedMat: MatWrapper?, horizonMask: MatWrapper?) {
        self.alignedMat = alignedMat
        self.failedMat = failedMat
        self.horizonMask = horizonMask
    }
}
