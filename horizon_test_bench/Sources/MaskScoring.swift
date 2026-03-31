/*
 MaskScoring.swift — Compare a computed horizon mask against a reference mask.

 Primary metric: pixel accuracy (fraction of pixels correctly classified as sky/ground).
 Additional metrics: per-column horizon Y error, IoU, boundary accuracy.
*/

import Foundation
import StarCore
import KHTSwift
import kht_bridge

// MARK: - Pixel access helper (since intensity is internal on PixelatedImage)

/// Read a single pixel's intensity from a PixelatedImage.
/// For multi-channel images, averages the first three channels (BGR).
/// For single-channel, returns the value directly.
func pixelIntensity(_ img: PixelatedImage, x: Int, y: Int) -> UInt {
    switch img.imageData {
    case .eightBit(let buf):
        let cpp = img.componentsPerPixel
        let offset = y * img.width * cpp + x * cpp
        guard offset < buf.count else { return 0 }
        if cpp == 1 { return UInt(buf[offset]) }
        // Multi-channel: average first min(3, cpp) channels
        let n = min(3, cpp)
        var sum: UInt = 0
        for c in 0..<n { sum += UInt(buf[offset + c]) }
        return sum / UInt(n)
    case .sixteenBit(let buf):
        let cpp = img.componentsPerPixel
        let offset = y * img.width * cpp + x * cpp
        guard offset < buf.count else { return 0 }
        if cpp == 1 { return UInt(buf[offset]) }
        let n = min(3, cpp)
        var sum: UInt = 0
        for c in 0..<n { sum += UInt(buf[offset + c]) }
        return sum / UInt(n)
    case .thirtyTwoBit(let buf):
        let cpp = img.componentsPerPixel
        let offset = y * img.width * cpp + x * cpp
        guard offset < buf.count else { return 0 }
        return UInt(max(0, buf[offset]))
    }
}

// MARK: - Score result

struct MaskScore: Sendable, CustomStringConvertible {
    /// Fraction of pixels correctly classified [0,1]. Higher = better.
    let pixelAccuracy: Double

    /// IoU of the sky region [0,1]. Higher = better.
    let skyIoU: Double

    /// Mean absolute error of per-column horizon Y (pixels). Lower = better.
    let meanHorizonError: Double

    /// Fraction of columns within 5 pixels of reference. Higher = better.
    let columnsWithin5px: Double

    /// Fraction of columns within 10 pixels. Higher = better.
    let columnsWithin10px: Double

    /// Number of valid (non-nil) reference columns
    let validColumns: Int

    /// Signed mean error: positive = computed horizon is BELOW reference (too much sky).
    /// Negative = computed horizon is ABOVE reference (too little sky).
    let signedMeanError: Double

    /// Combined score [0,1]. Higher = better.
    var combinedScore: Double {
        // Weight pixel accuracy heavily, but also reward precise horizon tracking
        0.35 * pixelAccuracy + 0.25 * skyIoU + 0.20 * columnsWithin5px + 0.20 * columnsWithin10px
    }

    var description: String {
        let signStr = signedMeanError >= 0 ? "+" : ""
        let base = String(format: "pxAcc=%.4f skyIoU=%.4f meanErr=%.1fpx",
                          pixelAccuracy, skyIoU, meanHorizonError)
        let signed = String(format: "(%@%.0f)", signStr, signedMeanError)
        let rest = String(format: " within5=%.3f within10=%.3f combined=%.4f",
                          columnsWithin5px, columnsWithin10px, combinedScore)
        return base + signed + rest
    }

    /// Short single-line format
    var shortDescription: String {
        let signStr = signedMeanError >= 0 ? "+" : ""
        return String(format: "%.3f (px=%.3f IoU=%.3f err=%.1f)", combinedScore, pixelAccuracy, skyIoU, meanHorizonError) + " \(signStr)\(String(format: "%.0f", signedMeanError))"
    }
}

// MARK: - Scoring engine

enum MaskScorer {

    /// Compare a computed mask against a reference mask.
    /// Both must be binary images (white=255 sky, black=0 ground) of the same size.
    static func score(computed: PixelatedImage, reference: PixelatedImage) -> MaskScore {
        let w = reference.width
        let h = reference.height

        // If sizes don't match, resize computed to match reference
        let comp: PixelatedImage
        if computed.width != w || computed.height != h {
            if let resized = computed.mat.downScale(to: UInt(w), height: UInt(h)),
               let pi = PixelatedImage(mat: resized) {
                comp = pi
            } else if let resized = computed.mat.upScale(to: UInt(w), height: UInt(h)),
                      let pi = PixelatedImage(mat: resized) {
                comp = pi
            } else {
                comp = computed
            }
        } else {
            comp = computed
        }

        // Extract per-column horizon Y from both masks
        let refY = extractHorizonY(from: reference)
        let compY = extractHorizonY(from: comp)

        // Pixel-level accuracy
        var correct = 0
        var total = 0
        var skyIntersection = 0
        var skyUnion = 0

        for x in 0..<min(w, comp.width) {
            for y in 0..<min(h, comp.height) {
                let refPixel = pixelIntensity(reference, x: x, y: y) > 127
                let compPixel = pixelIntensity(comp, x: x, y: y) > 127
                if refPixel == compPixel { correct += 1 }
                if refPixel || compPixel { skyUnion += 1 }
                if refPixel && compPixel { skyIntersection += 1 }
                total += 1
            }
        }

        let pixelAccuracy = total > 0 ? Double(correct) / Double(total) : 0
        let skyIoU = skyUnion > 0 ? Double(skyIntersection) / Double(skyUnion) : 0

        // Per-column horizon error
        var totalError = 0.0
        var totalSignedError = 0.0
        var within5 = 0
        var within10 = 0
        var validCols = 0

        for x in 0..<min(refY.count, compY.count) {
            guard let ry = refY[x] else { continue }
            validCols += 1
            let cy = compY[x] ?? (ry > h / 2 ? h : 0) // treat missing as worst case
            let err = abs(ry - cy)
            let signedErr = cy - ry  // positive = computed is below ref (too much sky)
            totalError += Double(err)
            totalSignedError += Double(signedErr)
            if err <= 5 { within5 += 1 }
            if err <= 10 { within10 += 1 }
        }

        let meanError = validCols > 0 ? totalError / Double(validCols) : Double(h)
        let signedMean = validCols > 0 ? totalSignedError / Double(validCols) : 0
        let frac5 = validCols > 0 ? Double(within5) / Double(validCols) : 0
        let frac10 = validCols > 0 ? Double(within10) / Double(validCols) : 0

        return MaskScore(
            pixelAccuracy: pixelAccuracy,
            skyIoU: skyIoU,
            meanHorizonError: meanError,
            columnsWithin5px: frac5,
            columnsWithin10px: frac10,
            validColumns: validCols,
            signedMeanError: signedMean
        )
    }

    /// Compare a per-column horizon Y array against a reference mask.
    /// Builds a binary mask from the Y array and delegates to score(computed:reference:).
    static func score(horizonY: [Int32], imageWidth: Int, imageHeight: Int,
                      reference: PixelatedImage) -> MaskScore {
        let yArray: [Int?] = horizonY.map { $0 < 0 ? nil : Int($0) }
        let maskMat = PixelatedImageBridge.binaryHorizonMask(
            width: Int32(imageWidth),
            height: Int32(imageHeight),
            horizonY: yArray
        )
        guard let maskImage = PixelatedImage(mat: maskMat) else {
            return MaskScore(pixelAccuracy: 0, skyIoU: 0, meanHorizonError: Double(imageHeight),
                             columnsWithin5px: 0, columnsWithin10px: 0, validColumns: 0,
                             signedMeanError: 0)
        }
        return score(computed: maskImage, reference: reference)
    }

    /// Extract per-column horizon Y (topmost ground pixel) from a mask.
    /// Uses the same threshold (127) as the pixel-level scoring: anything
    /// ≤ 127 is ground, > 127 is sky.  This handles both pure binary masks
    /// (0/255) and antialiased/soft-edge masks consistently.
    static func extractHorizonY(from mask: PixelatedImage) -> [Int?] {
        let w = mask.width
        let h = mask.height
        var result = [Int?](repeating: nil, count: w)
        for x in 0..<w {
            for y in 0..<h {
                if pixelIntensity(mask, x: x, y: y) <= 127 {
                    result[x] = y
                    break
                }
            }
        }
        return result
    }
}
