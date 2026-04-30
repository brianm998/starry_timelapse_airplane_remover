// ImageAligner.swift — Swift wrapper for image alignment operations
import Foundation
import StarCpp

public enum ImageAligner {

    public static func medianMerge(_ frames: [MatWrapper], outlierThreshold: Double,
                                    includeAll: Bool) -> MatWrapper {
        var refs = frames.map { $0.ref as MatWrapperRef? }
        let r = refs.withUnsafeMutableBufferPointer { buf in
            ia_median_merge(buf.baseAddress, Int32(buf.count), outlierThreshold, includeAll)
        }
        return MatWrapper(ref: r!)
    }

    public static func medianMergeImage(_ image: MatWrapper, withFilenames filenames: [String],
                                         outlierThreshold: Double, includeAll: Bool) -> MatWrapper {
        let cStrs = filenames.map { strdup($0) }
        defer { cStrs.forEach { free($0) } }
        var ptrs = cStrs.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        let r = ptrs.withUnsafeMutableBufferPointer { buf in
            ia_median_merge_image_with_filenames(image.ref,
                                                  buf.baseAddress,
                                                  Int32(buf.count),
                                                  outlierThreshold, includeAll)
        }
        return MatWrapper(ref: r!)
    }

    public static func medianMergeFilenames(_ filenames: [String],
                                             outlierThreshold: Double,
                                             includeAll: Bool) -> MatWrapper {
        let cStrs = filenames.map { strdup($0) }
        defer { cStrs.forEach { free($0) } }
        var ptrs = cStrs.map { UnsafePointer($0) as UnsafePointer<CChar>? }
        let r = ptrs.withUnsafeMutableBufferPointer { buf in
            ia_median_merge_filenames(buf.baseAddress, Int32(buf.count),
                                      outlierThreshold, includeAll)
        }
        return MatWrapper(ref: r!)
    }

    public static func findFeatures(baseImage: MatWrapper, frameIndex: Int32,
                                     matchMethod: FeatureMatchMethod,
                                     mask: MatWrapper?,
                                     alignmentType: AlignmentType,
                                     maxKeypoints: Int32,
                                     writeDebugImages: Bool,
                                     groundHorizonExtension: Int32,
                                     baseImageDilateSize: Int32,
                                     baseImageThresholdValue: Int32) -> OCVFeatureSet? {
        var errMsg: UnsafePointer<CChar>?
        guard let r = ia_find_features(baseImage.ref, frameIndex,
                                        matchMethod, mask?.ref,
                                        alignmentType, maxKeypoints,
                                        writeDebugImages,
                                        groundHorizonExtension,
                                        baseImageDilateSize,
                                        baseImageThresholdValue,
                                        &errMsg) else { return nil }
        return OCVFeatureSet(ref: r)
    }

    public static func computeHomography(baseKeypoints: OCVFeatureSet,
                                          frameIndex: Int32,
                                          neighbors: [AlignmentNeighborInfo],
                                          matchMethod: FeatureMatchMethod,
                                          alignmentType: AlignmentType,
                                          maxKeypoints: Int32,
                                          writeDebugImages: Bool,
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

    public static func align(baseFrameIndex: Int32,
                              neighbors: [AlignmentNeighborInfo],
                              homography: [Int: MatWrapper]) -> [WarpedImageResult] {
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

        var outResults = [WarpedImageResultData](repeating: WarpedImageResultData(), count: neighbors.count)
        var errMsg: UnsafePointer<CChar>?

        let count = cNeighbors.withUnsafeBufferPointer { nBuf in
            keys.withUnsafeMutableBufferPointer { kBuf in
                values.withUnsafeMutableBufferPointer { vBuf in
                    outResults.withUnsafeMutableBufferPointer { rBuf in
                        ia_align_with_homography(baseFrameIndex,
                                                  nBuf.baseAddress, Int32(nBuf.count),
                                                  kBuf.baseAddress, vBuf.baseAddress,
                                                  Int32(kBuf.count),
                                                  rBuf.baseAddress, &errMsg)
                    }
                }
            }
        }

        return outResults.prefix(Int(count)).map { data in
            WarpedImageResult(
                warpedFrame: data.warpedFrame.flatMap { MatWrapper(ref: $0) },
                warpedHorizon: data.warpedHorizon.flatMap { MatWrapper(ref: $0) }
            )
        }
    }

    public static func createGradientMaskIntoSky(_ binaryMask: MatWrapper,
                                                   gradientDistance: Int32) -> MatWrapper {
        MatWrapper(ref: ia_gradient_mask_into_sky(binaryMask.ref, gradientDistance))
    }

    public static func createGradientMaskIntoGround(_ binaryMask: MatWrapper,
                                                      gradientDistance: Int32) -> MatWrapper {
        MatWrapper(ref: ia_gradient_mask_into_ground(binaryMask.ref, gradientDistance))
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
