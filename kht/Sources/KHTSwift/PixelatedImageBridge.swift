// PixelatedImageBridge.swift — Swift wrapper for image processing operations
import kht_bridge

public enum PixelatedImageBridge {

    public static func cannyEdgeDetect(_ img: MatWrapper, minThreshold: Double,
                                       maxThreshold: Double, useL2Gradient: Bool) -> MatWrapper? {
        guard let r = pib_canny_edge_detect(img.ref, minThreshold, maxThreshold, useL2Gradient) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func shiftImageUp(_ input: MatWrapper, shiftPixels: Int32) -> MatWrapper? {
        guard let r = pib_shift_image_up(input.ref, shiftPixels) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func bitwiseAnd(_ img: MatWrapper, withImage img1: MatWrapper) -> MatWrapper? {
        guard let r = pib_bitwise_and(img.ref, img1.ref) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func bitwiseOr(_ img: MatWrapper, withImage img1: MatWrapper) -> MatWrapper? {
        guard let r = pib_bitwise_or(img.ref, img1.ref) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func bitwiseNot(_ img: MatWrapper) -> MatWrapper? {
        guard let r = pib_bitwise_not(img.ref) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func detectHorizon(_ img: MatWrapper) -> MatWrapper? {
        guard let r = pib_detect_horizon(img.ref) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func subtractImage(_ img2: MatWrapper, fromImage img1: MatWrapper) -> MatWrapper? {
        guard let r = pib_subtract_image(img2.ref, img1.ref) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func combineImage(_ image1: MatWrapper, mask: MatWrapper,
                                     background image2: MatWrapper) -> MatWrapper? {
        guard let r = pib_combine_image(image1.ref, mask.ref, image2.ref) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func filterConnectedComponents(_ image: MatWrapper, keepLargest n: Int) -> MatWrapper? {
        guard let r = pib_filter_connected_components(image.ref, Int64(n)) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func groundOnly(from image: MatWrapper) -> MatWrapper? {
        guard let r = pib_ground_only(image.ref) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func skyOnly(from image: MatWrapper) -> MatWrapper? {
        guard let r = pib_sky_only(image.ref) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func shrinkDarkRegions(_ img: MatWrapper, by radius: Int32) -> MatWrapper? {
        guard let r = pib_shrink_dark_regions(img.ref, radius) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func growDarkRegions(_ img: MatWrapper, by radius: Int32) -> MatWrapper? {
        guard let r = pib_grow_dark_regions(img.ref, radius) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func horizonExtents(fromImage image: MatWrapper) -> HorizonResult? {
        let data = pib_horizon_extents(image.ref)
        if data.horizonTopY == -1 && data.horizonBottomY == -1 { return nil }
        return HorizonResult(horizonTopY: Int(data.horizonTopY),
                             horizonBottomY: Int(data.horizonBottomY))
    }

    public static func maxBrightnessScale(forImage image: MatWrapper,
                                           maskImage mask: MatWrapper) -> Double {
        pib_max_brightness_scale(image.ref, mask.ref)
    }

    public static func brightenDarks(_ image: MatWrapper, mask: MatWrapper,
                                      amount: Double) -> MatWrapper? {
        guard let r = pib_brighten_darks(image.ref, mask.ref, amount) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func darkenDarks(_ image: MatWrapper, mask: MatWrapper,
                                    amount: Double) -> MatWrapper? {
        guard let r = pib_darken_darks(image.ref, mask.ref, amount) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func maskRaisedBy(_ image: MatWrapper, mask: MatWrapper,
                                     border: Int32) -> MatWrapper? {
        guard let r = pib_mask_raised_by(image.ref, mask.ref, border) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func warpImage(_ image: MatWrapper,
                                  withHomography homography: MatWrapper) -> MatWrapper? {
        guard let r = pib_warp_image(image.ref, homography.ref) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func absDiffGrayscale(_ image1: MatWrapper,
                                         withImage image2: MatWrapper) -> MatWrapper? {
        guard let r = pib_abs_diff_grayscale(image1.ref, image2.ref) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func meanOfImages(_ images: [MatWrapper]) -> MatWrapper? {
        var refs = images.map { $0.ref as MatWrapperRef? }
        guard let r = refs.withUnsafeMutableBufferPointer({ buf in
            pib_mean_of_images(buf.baseAddress, Int32(buf.count))
        }) else { return nil }
        return MatWrapper(ref: r)
    }

    public static func warpHorizonMask(_ mask: MatWrapper,
                                        withHomography homography: MatWrapper) -> MatWrapper? {
        guard let r = pib_warp_horizon_mask(mask.ref, homography.ref) else { return nil }
        return MatWrapper(ref: r)
    }

    /// Create binary horizon mask. Pass nil in horizonY to mean "all sky" for that column.
    public static func binaryHorizonMask(width: Int32, height: Int32,
                                          horizonY: [Int?]) -> MatWrapper {
        let cY: [Int32] = horizonY.map { Int32($0 ?? -1) }
        let r = cY.withUnsafeBufferPointer { buf in
            pib_binary_horizon_mask(width, height, buf.baseAddress!)
        }
        return MatWrapper(ref: r!)
    }

    public static func dpHorizonMask(_ img: MatWrapper,
                                      cannyMin: Double, cannyMax: Double,
                                      useL2Gradient: Bool,
                                      smoothnessLambda: Double,
                                      sobelWeight: Double, cannyWeight: Double,
                                      searchTopFraction: Double,
                                      searchBottomFraction: Double) -> MatWrapper? {
        guard let r = pib_dp_horizon_mask(img.ref, cannyMin, cannyMax, useL2Gradient,
                                           smoothnessLambda, sobelWeight, cannyWeight,
                                           searchTopFraction, searchBottomFraction) else { return nil }
        return MatWrapper(ref: r)
    }
    /// Random Walker horizon detection within a user-painted band.
    ///
    /// Solves an edge-weighted diffusion on a downsampled ROI, then
    /// extracts per-column horizon Y by scanning upward from ground
    /// seeds.  Stars are suppressed by Gaussian pre-blur.
    ///
    /// - Parameters:
    ///   - img:            Full image (any channel count).
    ///   - bandTopY:       Per-column top of painted band (image pixels). -1 = unpainted.
    ///   - bandBottomY:    Per-column bottom of painted band.
    ///   - skyFloorY:      Per-column lowest Y known sky (seed boundary).
    ///   - groundCeilY:    Per-column highest Y known ground (seed boundary).
    ///   - beta:           Edge weight sensitivity. Default 90.
    ///   - maxWorkingWidth: Working resolution width. Default 2048.
    /// - Returns: Per-column horizon Y in image pixel coords. -1 = no result.
    public static func randomWalkerHorizon(
        _ img: MatWrapper,
        bandTopY: [Int32],
        bandBottomY: [Int32],
        skyFloorY: [Int32],
        groundCeilY: [Int32],
        beta: Double = 90.0,
        maxWorkingWidth: Int32 = 4096
    ) -> [Int32] {
        let width = Int32(img.cols)
        var result = [Int32](repeating: -1, count: Int(width))
        bandTopY.withUnsafeBufferPointer { topBuf in
            bandBottomY.withUnsafeBufferPointer { botBuf in
                skyFloorY.withUnsafeBufferPointer { skyBuf in
                    groundCeilY.withUnsafeBufferPointer { gndBuf in
                        result.withUnsafeMutableBufferPointer { outBuf in
                            pib_random_walker_horizon(
                                img.ref,
                                topBuf.baseAddress,
                                botBuf.baseAddress,
                                skyBuf.baseAddress,
                                gndBuf.baseAddress,
                                width,
                                beta,
                                maxWorkingWidth,
                                outBuf.baseAddress
                            )
                        }
                    }
                }
            }
        }
        return result
    }
}

// MARK: - Simple result types

public struct HorizonResult: Sendable {
    public let horizonTopY: Int
    public let horizonBottomY: Int
}
