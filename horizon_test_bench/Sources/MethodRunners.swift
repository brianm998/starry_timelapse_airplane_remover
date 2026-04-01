/*
 MethodRunners.swift — Run each horizon detection method on an image.

 Each method returns a PixelatedImage binary mask (white=sky, black=ground).
*/

import Foundation
import StarCore
import KHTSwift
import kht_bridge

// MARK: - Method identifiers

enum HorizonMethod: String, CaseIterable, Sendable, CustomStringConvertible {
    case otsu = "otsu"
    case dp = "dp"
    case siox = "siox"
    case gradProfile = "grad"
    case texture = "tex"
    case randomWalker = "rw"

    // Combinations
    case otsuThenRW = "otsu+rw"
    case dpThenRW = "dp+rw"
    case sioxThenRW = "siox+rw"
    case gradThenRW = "grad+rw"
    case textureThenRW = "tex+rw"
    case combinedThenRW = "combined+rw"
    case bestOfRW = "bestof+rw"      // best of all single+rw per-sample
    case oracleRW = "oracle+rw"      // oracle: max(combined+rw, bestof+rw) per-sample

    var description: String { rawValue }

    /// Base methods (no combination)
    static let baseMethods: [HorizonMethod] = [.otsu, .dp, .siox, .gradProfile, .texture]

    /// Combined methods
    static let combinedMethods: [HorizonMethod] = [.otsuThenRW, .dpThenRW, .sioxThenRW, .gradThenRW, .textureThenRW, .combinedThenRW, .bestOfRW, .oracleRW]
}

// MARK: - Method parameters

struct OtsuParams: Sendable {
    var bottomPercentage: Double = 50.0
    var useCannyEdgeDetection: Bool = false // usually false for nighttime
}

struct DPParams: Sendable {
    var smoothnessLambda: Double = 2.0
    var sobelWeight: Double = 0.6
    var cannyWeight: Double = 0.4
    var cannyMinThreshold: Double = 50
    var cannyMaxThreshold: Double = 120
    var searchTopFraction: Double = 0.0
    var searchBottomFraction: Double = 1.0
}

struct RWParams: Sendable {
    var beta: Double = 90.0
    var maxWorkingWidth: Int32 = 4096
    var brushRadius: Int = 40   // simulated brush size (pixels at working resolution)
    var seedMargin: Int = 0     // extra pixels beyond brush for sky/ground seed regions
                                // 0 = seeds start right at band edge (default)
                                // >0 = seeds start `seedMargin` pixels outside the band
}

// MARK: - Working resolution helper

enum ImageScaler {
    /// Downscale image for faster processing. Returns (scaled image, scaleX, scaleY).
    static func scaleForProcessing(
        _ image: PixelatedImage,
        maxDim: Int = 1024
    ) -> (image: PixelatedImage, scaleX: Double, scaleY: Double) {
        let w = image.width
        let h = image.height
        if w <= maxDim && h <= maxDim {
            return (image, 1.0, 1.0)
        }
        let scale = Double(maxDim) / Double(max(w, h))
        let newW = max(1, Int(Double(w) * scale))
        let newH = max(1, Int(Double(h) * scale))
        if let scaled = image.mat.downScale(to: UInt(newW), height: UInt(newH)) {
            if let pi = PixelatedImage(mat: scaled) {
                return (pi, Double(newW) / Double(w), Double(newH) / Double(h))
            }
        }
        return (image, 1.0, 1.0)
    }

    /// Scale a horizon Y array from one resolution to another.
    static func scaleHorizonY(_ horizonY: [Int?], fromWidth: Int, toWidth: Int,
                               scaleY: Double) -> [Int?] {
        var result = [Int?](repeating: nil, count: toWidth)
        for x in 0..<toWidth {
            let srcX = Int(Double(x) * Double(fromWidth) / Double(toWidth))
            let clamped = min(max(srcX, 0), fromWidth - 1)
            if let y = horizonY[clamped] {
                result[x] = Int(Double(y) / scaleY)
            }
        }
        return result
    }
}

// MARK: - Otsu runner

enum OtsuRunner {

    /// Run Otsu thresholding at multiple crop percentages and return the best mask.
    /// Tests crop amounts from 10% to 90% and picks the one that looks most reasonable.
    static func run(
        image: PixelatedImage,
        params: OtsuParams = OtsuParams(),
        workingSize: Int = 512
    ) async throws -> PixelatedImage {
        // Scale down for faster Otsu search
        let (scaled, _, _) = ImageScaler.scaleForProcessing(image, maxDim: workingSize)

        // Try multiple crop percentages
        let cropSteps = stride(from: 10.0, through: 90.0, by: 5.0)
        var bestMask: PixelatedImage? = nil
        var bestScore = -1.0

        for crop in cropSteps {
            if let mask = try await scaled.horizonMask(
                at: 0,
                bottomPercentage: crop,
                useCannyEdgeDetection: params.useCannyEdgeDetection
            ) {
                // Simple quality heuristic: prefer masks that aren't all-sky or all-ground
                let horizonY = MaskScorer.extractHorizonY(from: mask.image)
                let defined = horizonY.compactMap { $0 }
                guard !defined.isEmpty else { continue }

                let coverage = Double(defined.count) / Double(horizonY.count)
                let avgY = Double(defined.reduce(0, +)) / Double(defined.count)
                let heightFrac = avgY / Double(scaled.height)

                // Prefer masks where horizon is in the middle range
                let centerPenalty = 1.0 - abs(heightFrac - 0.5) * 2.0
                let score = coverage * max(0.1, centerPenalty)

                if score > bestScore {
                    bestScore = score
                    bestMask = mask.image
                }
            }
        }

        // Scale best mask back to original size
        if let mask = bestMask {
            let origW = image.width
            let origH = image.height
            if mask.width != origW || mask.height != origH {
                if let upscaled = mask.mat.upScale(to: UInt(origW), height: UInt(origH)) {
                    // Threshold the upscaled mask to keep it binary
                    if let binary = PixelatedImage(mat: upscaled) {
                        return thresholdToBinary(binary)
                    }
                }
            }
            return mask
        }

        // Fallback: all-sky mask
        let allSky = PixelatedImageBridge.binaryHorizonMask(
            width: Int32(image.width),
            height: Int32(image.height),
            horizonY: [Int?](repeating: nil, count: image.width)
        )
        return PixelatedImage(mat: allSky)!
    }

    /// Threshold a potentially anti-aliased mask to pure binary (0 or 255).
    static func thresholdToBinary(_ image: PixelatedImage) -> PixelatedImage {
        let w = image.width
        let h = image.height
        var horizonY = [Int?](repeating: nil, count: w)
        for x in 0..<w {
            for y in 0..<h {
                if pixelIntensity(image, x: x, y: y) < 128 {
                    horizonY[x] = y
                    break
                }
            }
        }
        let mat = PixelatedImageBridge.binaryHorizonMask(
            width: Int32(w), height: Int32(h), horizonY: horizonY
        )
        return PixelatedImage(mat: mat)!
    }
}

// MARK: - DP runner

enum DPRunner {

    /// Run DP horizon detection. Optionally search a grid of parameters.
    static func run(
        image: PixelatedImage,
        params: DPParams = DPParams(),
        workingSize: Int = 512,
        gridSearch: Bool = false
    ) async throws -> PixelatedImage {
        if gridSearch {
            return try await runGridSearch(image: image, workingSize: workingSize)
        }
        return try runSingle(image: image, params: params, workingSize: workingSize)
    }

    /// Run DP with a single set of parameters.
    static func runSingle(
        image: PixelatedImage,
        params: DPParams,
        workingSize: Int = 512
    ) throws -> PixelatedImage {
        // Scale down
        let (scaled, _, _) = ImageScaler.scaleForProcessing(image, maxDim: workingSize)

        let mask = try scaled.dpHorizonDetect(
            cannyMinThreshold: params.cannyMinThreshold,
            cannyMaxThreshold: params.cannyMaxThreshold,
            useL2Gradient: true,
            smoothnessLambda: params.smoothnessLambda,
            sobelWeight: params.sobelWeight,
            cannyWeight: params.cannyWeight,
            searchTopFraction: params.searchTopFraction,
            searchBottomFraction: params.searchBottomFraction
        )

        // Scale back up
        let origW = image.width
        let origH = image.height
        if mask.width != origW || mask.height != origH {
            if let upscaled = mask.mat.upScale(to: UInt(origW), height: UInt(origH)) {
                if let pi = PixelatedImage(mat: upscaled) {
                    return OtsuRunner.thresholdToBinary(pi)
                }
            }
        }
        return mask
    }

    /// Grid search over DP parameters and return the best result.
    static func runGridSearch(
        image: PixelatedImage,
        workingSize: Int = 512
    ) async throws -> PixelatedImage {
        let (scaled, _, _) = ImageScaler.scaleForProcessing(image, maxDim: workingSize)
        let origW = image.width
        let origH = image.height

        let lambdas = [1.0, 1.5, 2.0, 3.0]
        let sobelWs = [0.2, 0.6, 1.0]
        let cannyWs = [0.2, 0.6, 1.0]

        var bestMask: PixelatedImage? = nil
        var bestScore = -1.0

        for lambda in lambdas {
            for sobelW in sobelWs {
                for cannyW in cannyWs {
                    let mask = try scaled.dpHorizonDetect(
                        smoothnessLambda: lambda,
                        sobelWeight: sobelW,
                        cannyWeight: cannyW
                    )
                    // Score quality: prefer masks with good coverage and smoothness
                    let horizonY = MaskScorer.extractHorizonY(from: mask)
                    let defined = horizonY.compactMap { $0 }
                    guard !defined.isEmpty else { continue }

                    let coverage = Double(defined.count) / Double(horizonY.count)
                    let diffs = zip(defined.dropLast(), defined.dropFirst()).map { abs($0 - $1) }
                    let smoothness = diffs.isEmpty ? 1.0 :
                        1.0 / (1.0 + Double(diffs.reduce(0, +)) / Double(diffs.count))
                    let score = coverage * 0.5 + smoothness * 0.5

                    if score > bestScore {
                        bestScore = score
                        bestMask = mask
                    }
                }
            }
        }

        if let mask = bestMask {
            if mask.width != origW || mask.height != origH {
                if let up = mask.mat.upScale(to: UInt(origW), height: UInt(origH)) {
                    if let pi = PixelatedImage(mat: up) {
                        return OtsuRunner.thresholdToBinary(pi)
                    }
                }
            }
            return mask
        }

        throw "DP grid search produced no valid results"
    }
}

// MARK: - SIOX runner (standalone, extracted from FrameAirplaneRemover)

enum SIOXRunner {

    /// Run standalone SIOX horizon detection on an image.
    /// Uses a simulated band across the full image width from `bandTopFraction` to `bandBottomFraction`.
    static func run(
        image: PixelatedImage,
        bandTopFraction: Double = 0.15,
        bandBottomFraction: Double = 0.85,
        workingSize: Int = 1024
    ) async -> PixelatedImage {
        let imgW = image.width
        let imgH = image.height

        // Scale down for SIOX processing
        let (scaled, scaleX, scaleY) = ImageScaler.scaleForProcessing(image, maxDim: workingSize)
        let sW = scaled.width
        let sH = scaled.height

        // Simulated band: paint across the full width
        let bandTop = Int(Double(sH) * bandTopFraction)
        let bandBot = Int(Double(sH) * bandBottomFraction)

        // Run SIOX on scaled image
        let horizonYScaled = await runSIOXCore(
            image: scaled,
            bandTop: bandTop,
            bandBot: bandBot,
            skyFloorY: bandTop,
            groundCeilingY: bandBot
        )

        // Scale horizon Y back to original resolution
        let horizonYOrig = ImageScaler.scaleHorizonY(
            horizonYScaled, fromWidth: sW, toWidth: imgW, scaleY: scaleY
        )

        let yArray: [Int?] = horizonYOrig
        let maskMat = PixelatedImageBridge.binaryHorizonMask(
            width: Int32(imgW), height: Int32(imgH), horizonY: yArray
        )
        return PixelatedImage(mat: maskMat)!
    }

    /// Core SIOX algorithm — per-column scan with LAB+intensity centroids.
    /// Extracted from FrameAirplaneRemover.computeLiveObjectSelection.
    static func runSIOXCore(
        image: PixelatedImage,
        bandTop: Int,
        bandBot: Int,
        skyFloorY: Int,
        groundCeilingY: Int
    ) async -> [Int?] {
        let imgW = image.width
        let imgH = image.height
        let halfW = 30
        let intensityWeight: Float = 100.0

        // Ensure 8-bit image for SIOX processing
        let img8 = PixelatedImage(mat: image.mat.ensureEightBit()) ?? image
        let pixelData: [UInt8]
        switch img8.imageData {
        case .eightBit(let buf):
            pixelData = Array(buf)
        default:
            // Shouldn't happen after ensureEightBit, but fallback
            return [Int?](repeating: nil, count: imgW)
        }
        let pixStride = img8.bytesPerRow
        let pxBpp = max(1, img8.bytesPerPixel)

        return await Task.detached(priority: .userInitiated) {
            // sRGB → linear LUT
            let linearLUT: [Float] = (0..<256).map { v in
                let n = Float(v) / 255.0
                return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4)
            }

            @inline(__always)
            func linRGBtoLABI(r: Float, g: Float, b: Float)
                -> (L: Float, a: Float, b: Float, I: Float)
            {
                let X = 0.4124564*r + 0.3575761*g + 0.1804375*b
                let Y = 0.2126729*r + 0.7151522*g + 0.0721750*b
                let Z = 0.0193339*r + 0.1191920*g + 0.9503041*b
                let Xn: Float = 0.95047, Yn: Float = 1.0, Zn: Float = 1.08883
                @inline(__always) func f(_ t: Float) -> Float {
                    t > 0.008856 ? pow(t, 1.0/3.0) : 7.787*t + (16.0/116.0)
                }
                let (fx, fy, fz) = (f(X/Xn), f(Y/Yn), f(Z/Zn))
                return (116.0*fy - 16.0, 500.0*(fx - fy), 200.0*(fy - fz), Y)
            }

            @inline(__always)
            func dist2(_ l1: Float, _ a1: Float, _ b1: Float, _ i1: Float,
                       _ l2: Float, _ a2: Float, _ b2: Float, _ i2: Float) -> Float {
                let dL = l1-l2, da = a1-a2, db = b1-b2, di = i1-i2
                return dL*dL + da*da + db*db + di*di
            }

            // Windowed LAB cache (prefix-sum based)
            let globalTop = max(0, bandTop - 20)
            let globalBot = min(imgH - 1, bandBot + 20)
            let rowStep = 2
            let colLeft = 0
            let colRight = imgW - 1
            let colWidth = imgW

            let pxLeft = max(0, colLeft - halfW)
            let pxRight = min(imgW - 1, colRight + halfW)
            let pxWidth = pxRight - pxLeft + 1
            let bandH = (globalBot - globalTop) / rowStep + 1

            var winL = [Float](repeating: 0, count: bandH * colWidth)
            var winA = [Float](repeating: 0, count: bandH * colWidth)
            var winBB = [Float](repeating: 0, count: bandH * colWidth)
            var winI = [Float](repeating: 0, count: bandH * colWidth)

            for iy in stride(from: globalTop, through: globalBot, by: rowStep) {
                let ri = (iy - globalTop) / rowStep
                var prefR = [Float](repeating: 0, count: pxWidth + 1)
                var prefG = [Float](repeating: 0, count: pxWidth + 1)
                var prefB = [Float](repeating: 0, count: pxWidth + 1)
                for i in 0..<pxWidth {
                    let ix = pxLeft + i
                    let base = iy * pixStride + ix * pxBpp
                    guard base + 2 < pixelData.count else { continue }
                    let bV = linearLUT[Int(pixelData[base])]
                    let gV = pxBpp > 1 ? linearLUT[Int(pixelData[base + 1])] : bV
                    let rV = pxBpp > 2 ? linearLUT[Int(pixelData[base + 2])] : bV
                    prefR[i+1] = prefR[i] + rV
                    prefG[i+1] = prefG[i] + gV
                    prefB[i+1] = prefB[i] + bV
                }
                for ix in colLeft...colRight {
                    let i = ix - pxLeft
                    let lo = max(0, i - halfW)
                    let hi = min(pxWidth - 1, i + halfW)
                    let cnt = Float(hi - lo + 1)
                    let mr = (prefR[hi+1] - prefR[lo]) / cnt
                    let mg = (prefG[hi+1] - prefG[lo]) / cnt
                    let mb = (prefB[hi+1] - prefB[lo]) / cnt
                    let (L, a, lab_b, intensity) = linRGBtoLABI(r: mr, g: mg, b: mb)
                    let idx = ri * colWidth + (ix - colLeft)
                    winL[idx] = L; winA[idx] = a; winBB[idx] = lab_b
                    winI[idx] = intensity * intensityWeight
                }
            }

            @inline(__always)
            func labiAt(ix: Int, iy: Int) -> (L: Float, a: Float, b: Float, I: Float) {
                let ri = min((iy - globalTop) / rowStep, bandH - 1)
                let idx = ri * colWidth + (ix - colLeft)
                return (winL[idx], winA[idx], winBB[idx], winI[idx])
            }

            // Global sky centroid
            let centroidColStep = max(1, colWidth / 40)
            var skyLSum: Float = 0, skyASum: Float = 0, skyBBSum: Float = 0, skyISum: Float = 0
            var nSky = 0
            for ix in stride(from: 0, through: imgW - 1, by: centroidColStep) {
                let yStep = max(1, skyFloorY / 20)
                for iy in stride(from: 0, to: skyFloorY, by: yStep) {
                    let base = iy * pixStride + ix * pxBpp
                    guard base + 2 < pixelData.count else { continue }
                    let bV = linearLUT[Int(pixelData[base])]
                    let gV = pxBpp > 1 ? linearLUT[Int(pixelData[base + 1])] : bV
                    let rV = pxBpp > 2 ? linearLUT[Int(pixelData[base + 2])] : bV
                    let (L, a, b, rawI) = linRGBtoLABI(r: rV, g: gV, b: bV)
                    skyLSum += L; skyASum += a; skyBBSum += b
                    skyISum += rawI * intensityWeight
                    nSky += 1
                }
            }
            let nSkyF = Float(max(1, nSky))
            let gSkyL = skyLSum / nSkyF, gSkyA = skyASum / nSkyF
            let gSkyBB = skyBBSum / nSkyF, gSkyI = skyISum / nSkyF

            // Global ground centroid
            var gndLSum: Float = 0, gndASum: Float = 0, gndBBSum: Float = 0, gndISum: Float = 0
            var nGnd = 0
            for ix in stride(from: 0, through: imgW - 1, by: centroidColStep) {
                let rowSpan = imgH - groundCeilingY
                let yStep = max(1, rowSpan / 20)
                for iy in stride(from: groundCeilingY, to: imgH, by: yStep) {
                    let base = iy * pixStride + ix * pxBpp
                    guard base + 2 < pixelData.count else { continue }
                    let bV = linearLUT[Int(pixelData[base])]
                    let gV = pxBpp > 1 ? linearLUT[Int(pixelData[base + 1])] : bV
                    let rV = pxBpp > 2 ? linearLUT[Int(pixelData[base + 2])] : bV
                    let (L, a, b, rawI) = linRGBtoLABI(r: rV, g: gV, b: bV)
                    gndLSum += L; gndASum += a; gndBBSum += b
                    gndISum += rawI * intensityWeight
                    nGnd += 1
                }
            }
            let nGndF = Float(max(1, nGnd))
            let gGndL = gndLSum / nGndF, gGndA = gndASum / nGndF
            let gGndBB = gndBBSum / nGndF, gGndI = gndISum / nGndF

            // Per-column scan
            let minConsecutive = 4
            var result = [Int?](repeating: nil, count: imgW)
            for ix in 0..<imgW {
                var consecutiveTerrain = 0
                var horizonY = groundCeilingY
                for iy in skyFloorY..<groundCeilingY {
                    let (L, a, b, I) = labiAt(ix: ix, iy: iy)
                    if dist2(L, a, b, I, gGndL, gGndA, gGndBB, gGndI) <
                       dist2(L, a, b, I, gSkyL, gSkyA, gSkyBB, gSkyI) {
                        consecutiveTerrain += 1
                        if consecutiveTerrain >= minConsecutive {
                            horizonY = iy - minConsecutive + 1
                            break
                        }
                    } else {
                        consecutiveTerrain = 0
                    }
                }

                // Gradient-aware correction: search upward from the color-based
                // horizon for a strong vertical L* gradient within 30 rows.
                let gradSearchUp = min(30, horizonY - skyFloorY)
                if gradSearchUp > 2 {
                    var bestGradY = horizonY
                    var bestGrad: Float = 0
                    for checkY in (horizonY - gradSearchUp)..<horizonY {
                        let iy0 = max(globalTop, checkY - 1)
                        let iy1 = min(globalBot, checkY + 1)
                        let (L0, _, _, _) = labiAt(ix: ix, iy: iy0)
                        let (L1, _, _, _) = labiAt(ix: ix, iy: iy1)
                        let grad = abs(L1 - L0)
                        if grad > bestGrad {
                            bestGrad = grad
                            bestGradY = checkY
                        }
                    }
                    if bestGrad > 5.0 {
                        horizonY = bestGradY
                    }
                }

                result[ix] = max(skyFloorY, min(horizonY, groundCeilingY))
            }

            // Median filter
            let medW = 40
            var smoothed = result
            for ix in 0..<imgW {
                guard result[ix] != nil else { continue }
                let lo = max(0, ix - medW)
                let hi = min(imgW - 1, ix + medW)
                var window: [Int] = []
                for jx in lo...hi { if let y = result[jx] { window.append(y) } }
                if !window.isEmpty {
                    window.sort()
                    smoothed[ix] = window[window.count / 2]
                }
            }

            return smoothed
        }.value
    }
}

// MARK: - Vertical Gradient Profile runner

enum GradProfileRunner {

    /// Run vertical gradient profile horizon detection.
    ///
    /// For each column, computes a smoothed vertical gradient profile (Sobel-Y),
    /// then finds the strongest sustained gradient transition — the sky→ground
    /// boundary. This is complementary to color-based methods (Otsu, SIOX) because
    /// it works purely on edge structure, making it robust to snow/water that
    /// has similar color to sky but a clear gradient at the actual ridgeline.
    static func run(
        image: PixelatedImage,
        workingSize: Int = 512,
        searchTopFraction: Double = 0.05,
        searchBottomFraction: Double = 0.95,
        verticalSmoothRadius: Int = 5,
        columnSmoothRadius: Int = 20
    ) -> PixelatedImage {
        let imgW = image.width
        let imgH = image.height

        // Scale down for processing
        let (scaled, _, scaleY) = ImageScaler.scaleForProcessing(image, maxDim: workingSize)
        let sW = scaled.width
        let sH = scaled.height

        let searchTop = max(0, Int(Double(sH) * searchTopFraction))
        let searchBot = min(sH - 1, Int(Double(sH) * searchBottomFraction))

        // Ensure 8-bit grayscale for gradient computation
        let img8 = PixelatedImage(mat: scaled.mat.ensureEightBit()) ?? scaled
        let grayData: [UInt8]
        let cpp: Int
        switch img8.imageData {
        case .eightBit(let buf):
            grayData = Array(buf)
            cpp = img8.componentsPerPixel
        default:
            // Fallback: return all-sky
            let yArray = [Int?](repeating: nil, count: imgW)
            let mat = PixelatedImageBridge.binaryHorizonMask(
                width: Int32(imgW), height: Int32(imgH), horizonY: yArray)
            return PixelatedImage(mat: mat)!
        }
        let stride = img8.bytesPerRow

        // Compute per-column vertical gradient profile using Sobel-like 1D kernel.
        // For each (x, y), gradient = weighted sum of brightness differences in a
        // vertical window. We use a Gaussian-weighted window of radius verticalSmoothRadius.
        //
        // The key insight: at the horizon, there's a sustained bright→dark (or dark→bright)
        // transition across multiple rows. We want the peak of the smoothed |gradient|.

        var horizonYScaled = [Int?](repeating: nil, count: sW)

        for x in 0..<sW {
            // Extract column brightness (average of channels)
            var colBrightness = [Float](repeating: 0, count: sH)
            for y in 0..<sH {
                let base = y * stride + x * cpp
                if cpp >= 3 && base + 2 < grayData.count {
                    colBrightness[y] = (Float(grayData[base]) + Float(grayData[base+1]) + Float(grayData[base+2])) / 3.0
                } else if base < grayData.count {
                    colBrightness[y] = Float(grayData[base])
                }
            }

            // Smooth the column brightness to reduce noise (stars, etc.)
            let smoothR = verticalSmoothRadius
            var smoothBright = [Float](repeating: 0, count: sH)
            for y in 0..<sH {
                let lo = max(0, y - smoothR)
                let hi = min(sH - 1, y + smoothR)
                var sum: Float = 0
                for j in lo...hi { sum += colBrightness[j] }
                smoothBright[y] = sum / Float(hi - lo + 1)
            }

            // Compute absolute vertical gradient at each row
            var gradProfile = [Float](repeating: 0, count: sH)
            for y in 1..<(sH - 1) {
                gradProfile[y] = abs(smoothBright[y + 1] - smoothBright[y - 1]) / 2.0
            }

            // Smooth the gradient profile to find sustained transitions (not spikes)
            let gradSmoothR = smoothR * 2
            var smoothGrad = [Float](repeating: 0, count: sH)
            for y in searchTop...searchBot {
                let lo = max(searchTop, y - gradSmoothR)
                let hi = min(searchBot, y + gradSmoothR)
                var sum: Float = 0
                for j in lo...hi { sum += gradProfile[j] }
                smoothGrad[y] = sum / Float(hi - lo + 1)
            }

            // Find the peak gradient within the search band
            var bestY = (searchTop + searchBot) / 2
            var bestGrad: Float = 0
            for y in searchTop...searchBot {
                if smoothGrad[y] > bestGrad {
                    bestGrad = smoothGrad[y]
                    bestY = y
                }
            }

            // Refine: snap to the exact peak within ±smoothR of the smoothed peak
            var refinedY = bestY
            var refinedGrad: Float = 0
            let refLo = max(searchTop, bestY - smoothR)
            let refHi = min(searchBot, bestY + smoothR)
            for y in refLo...refHi {
                if gradProfile[y] > refinedGrad {
                    refinedGrad = gradProfile[y]
                    refinedY = y
                }
            }

            // Only accept if the gradient is meaningful (not noise)
            // Threshold: at least 2 brightness units of gradient
            if bestGrad >= 2.0 {
                horizonYScaled[x] = refinedY
            }
        }

        // Column-wise median filter to smooth outliers
        let medW = columnSmoothRadius
        var smoothed = horizonYScaled
        for x in 0..<sW {
            guard horizonYScaled[x] != nil else { continue }
            let lo = max(0, x - medW)
            let hi = min(sW - 1, x + medW)
            var window: [Int] = []
            for jx in lo...hi {
                if let y = horizonYScaled[jx] { window.append(y) }
            }
            if !window.isEmpty {
                window.sort()
                smoothed[x] = window[window.count / 2]
            }
        }

        // Scale back to original resolution
        let horizonYOrig = ImageScaler.scaleHorizonY(
            smoothed, fromWidth: sW, toWidth: imgW, scaleY: scaleY
        )

        let maskMat = PixelatedImageBridge.binaryHorizonMask(
            width: Int32(imgW), height: Int32(imgH), horizonY: horizonYOrig
        )
        return PixelatedImage(mat: maskMat)!
    }
}

// MARK: - Texture/Entropy runner

enum TextureRunner {

    /// Run texture-based horizon detection.
    ///
    /// Computes local variance in a sliding window for each column. Sky regions
    /// (even with stars) have low texture variance; ground (terrain, trees, snow)
    /// has high variance. The horizon is the transition from low→high variance.
    ///
    /// This is complementary to gradient-based methods because it doesn't look
    /// for a single edge — it detects the *change in texture regime* between
    /// sky and ground, which is robust to gradual transitions and water reflections.
    static func run(
        image: PixelatedImage,
        workingSize: Int = 512,
        searchTopFraction: Double = 0.05,
        searchBottomFraction: Double = 0.95,
        windowRadius: Int = 8,
        columnSmoothRadius: Int = 20
    ) -> PixelatedImage {
        let imgW = image.width
        let imgH = image.height

        // Scale down for processing
        let (scaled, _, scaleY) = ImageScaler.scaleForProcessing(image, maxDim: workingSize)
        let sW = scaled.width
        let sH = scaled.height

        let searchTop = max(0, Int(Double(sH) * searchTopFraction))
        let searchBot = min(sH - 1, Int(Double(sH) * searchBottomFraction))

        // Ensure 8-bit
        let img8 = PixelatedImage(mat: scaled.mat.ensureEightBit()) ?? scaled
        let pixelData: [UInt8]
        let cpp: Int
        switch img8.imageData {
        case .eightBit(let buf):
            pixelData = Array(buf)
            cpp = img8.componentsPerPixel
        default:
            let yArray = [Int?](repeating: nil, count: imgW)
            let mat = PixelatedImageBridge.binaryHorizonMask(
                width: Int32(imgW), height: Int32(imgH), horizonY: yArray)
            return PixelatedImage(mat: mat)!
        }
        let stride = img8.bytesPerRow

        var horizonYScaled = [Int?](repeating: nil, count: sW)
        let winR = windowRadius

        for x in 0..<sW {
            // Extract column brightness
            var colBright = [Float](repeating: 0, count: sH)
            for y in 0..<sH {
                let base = y * stride + x * cpp
                if cpp >= 3 && base + 2 < pixelData.count {
                    colBright[y] = (Float(pixelData[base]) + Float(pixelData[base+1]) + Float(pixelData[base+2])) / 3.0
                } else if base < pixelData.count {
                    colBright[y] = Float(pixelData[base])
                }
            }

            // Compute local variance at each row using a sliding window.
            // variance = E[x^2] - E[x]^2
            // Use prefix sums for O(1) per-row computation.
            var prefSum = [Float](repeating: 0, count: sH + 1)
            var prefSqSum = [Float](repeating: 0, count: sH + 1)
            for y in 0..<sH {
                prefSum[y + 1] = prefSum[y] + colBright[y]
                prefSqSum[y + 1] = prefSqSum[y] + colBright[y] * colBright[y]
            }

            var localVar = [Float](repeating: 0, count: sH)
            for y in searchTop...searchBot {
                let lo = max(0, y - winR)
                let hi = min(sH - 1, y + winR)
                let n = Float(hi - lo + 1)
                let mean = (prefSum[hi + 1] - prefSum[lo]) / n
                let meanSq = (prefSqSum[hi + 1] - prefSqSum[lo]) / n
                localVar[y] = max(0, meanSq - mean * mean)
            }

            // Smooth the variance profile to find sustained transitions
            let smoothR = winR
            var smoothVar = [Float](repeating: 0, count: sH)
            for y in searchTop...searchBot {
                let lo = max(searchTop, y - smoothR)
                let hi = min(searchBot, y + smoothR)
                var sum: Float = 0
                for j in lo...hi { sum += localVar[j] }
                smoothVar[y] = sum / Float(hi - lo + 1)
            }

            // Find the horizon as the row where variance transitions from
            // low (sky) to high (ground). We look for the point of maximum
            // variance increase (derivative of smoothed variance).
            var varDeriv = [Float](repeating: 0, count: sH)
            let derivR = 3
            for y in (searchTop + derivR)...(searchBot - derivR) {
                varDeriv[y] = smoothVar[y + derivR] - smoothVar[y - derivR]
            }

            // Smooth the derivative to avoid spikes
            var smoothDeriv = [Float](repeating: 0, count: sH)
            let derivSmoothR = 4
            for y in searchTop...searchBot {
                let lo = max(searchTop, y - derivSmoothR)
                let hi = min(searchBot, y + derivSmoothR)
                var sum: Float = 0
                for j in lo...hi { sum += varDeriv[j] }
                smoothDeriv[y] = sum / Float(hi - lo + 1)
            }

            // Peak of positive derivative = transition from low to high variance
            var bestY = (searchTop + searchBot) / 2
            var bestDeriv: Float = 0
            for y in searchTop...searchBot {
                if smoothDeriv[y] > bestDeriv {
                    bestDeriv = smoothDeriv[y]
                    bestY = y
                }
            }

            // Only accept if the variance transition is meaningful
            // (derivative significantly positive)
            if bestDeriv > 5.0 {
                horizonYScaled[x] = bestY
            }
        }

        // Column-wise median filter
        let medW = columnSmoothRadius
        var smoothed = horizonYScaled
        for x in 0..<sW {
            guard horizonYScaled[x] != nil else { continue }
            let lo = max(0, x - medW)
            let hi = min(sW - 1, x + medW)
            var window: [Int] = []
            for jx in lo...hi {
                if let y = horizonYScaled[jx] { window.append(y) }
            }
            if !window.isEmpty {
                window.sort()
                smoothed[x] = window[window.count / 2]
            }
        }

        // Scale back to original resolution
        let horizonYOrig = ImageScaler.scaleHorizonY(
            smoothed, fromWidth: sW, toWidth: imgW, scaleY: scaleY
        )

        let maskMat = PixelatedImageBridge.binaryHorizonMask(
            width: Int32(imgW), height: Int32(imgH), horizonY: horizonYOrig
        )
        return PixelatedImage(mat: maskMat)!
    }
}

// MARK: - Random Walker runner

enum RWRunner {

    /// Run Random Walker with a simulated painted band derived from a base horizon.
    /// The base horizon (per-column Y) comes from another method (Otsu, DP, SIOX, etc.).
    static func run(
        image: PixelatedImage,
        baseHorizonY: [Int?],
        params: RWParams = RWParams()
    ) -> PixelatedImage {
        return runWithBands(
            image: image,
            baseHorizonY: baseHorizonY,
            perColumnBrush: nil,
            params: params
        )
    }

    /// Run Random Walker with per-column adaptive brush widths.
    /// `perColumnBrush` provides a brush radius for each column.
    /// Falls back to `params.brushRadius` for columns without a custom value.
    static func runAdaptive(
        image: PixelatedImage,
        baseHorizonY: [Int?],
        perColumnBrush: [Int],
        params: RWParams = RWParams()
    ) -> PixelatedImage {
        return runWithBands(
            image: image,
            baseHorizonY: baseHorizonY,
            perColumnBrush: perColumnBrush,
            params: params
        )
    }

    private static func runWithBands(
        image: PixelatedImage,
        baseHorizonY: [Int?],
        perColumnBrush: [Int]?,
        params: RWParams
    ) -> PixelatedImage {
        let imgW = image.width
        let imgH = image.height
        let defaultBrush = params.brushRadius
        let seedMargin = params.seedMargin

        // Build band arrays: paint a brush-radius band around the base horizon.
        var bandTop = [Int32](repeating: -1, count: imgW)
        var bandBot = [Int32](repeating: -1, count: imgW)
        var skyFloor = [Int32](repeating: -1, count: imgW)
        var groundCeil = [Int32](repeating: -1, count: imgW)

        for x in 0..<imgW {
            guard let y = baseHorizonY[x] else { continue }
            let brush = perColumnBrush != nil && x < perColumnBrush!.count
                ? perColumnBrush![x] : defaultBrush
            let top = max(0, y - brush)
            let bot = min(imgH - 1, y + brush)
            bandTop[x] = Int32(top)
            bandBot[x] = Int32(bot)
            skyFloor[x] = Int32(max(0, top - seedMargin))
            groundCeil[x] = Int32(min(imgH - 1, bot + seedMargin))
        }

        // Run Random Walker
        let resultY = PixelatedImageBridge.randomWalkerHorizon(
            image.mat,
            bandTopY: bandTop,
            bandBottomY: bandBot,
            skyFloorY: skyFloor,
            groundCeilY: groundCeil,
            beta: params.beta,
            maxWorkingWidth: params.maxWorkingWidth
        )

        // Build mask from result
        let yArray: [Int?] = resultY.map { $0 < 0 ? nil : Int($0) }
        let maskMat = PixelatedImageBridge.binaryHorizonMask(
            width: Int32(imgW), height: Int32(imgH), horizonY: yArray
        )
        return PixelatedImage(mat: maskMat)!
    }
}

// MARK: - Band simulation

enum BandSimulator {

    /// Given a binary horizon mask, extract per-column Y and optionally smooth it.
    static func horizonYFromMask(_ mask: PixelatedImage) -> [Int?] {
        MaskScorer.extractHorizonY(from: mask)
    }

    /// Compute per-column adaptive brush width based on disagreement between
    /// multiple base method horizons.  Where methods agree (low spread), use a
    /// tight brush for precision.  Where they disagree (high spread), widen the
    /// brush so the RW solver has room to find the correct edge.
    static func adaptiveBrushWidths(
        _ arrays: [[Int?]],
        baseBrush: Int,
        minBrush: Int = 30,
        maxBrushMultiplier: Double = 4.0
    ) -> [Int] {
        guard let first = arrays.first else { return [] }
        let w = first.count
        var brushes = [Int](repeating: baseBrush, count: w)
        let maxBrush = Int(Double(baseBrush) * maxBrushMultiplier)

        for x in 0..<w {
            var vals: [Int] = []
            for arr in arrays {
                if x < arr.count, let y = arr[x] { vals.append(y) }
            }
            guard vals.count >= 2 else { continue }

            vals.sort()
            let spread = vals.last! - vals.first!

            // Brush should be at least half the spread (to cover the range of
            // estimates) plus baseBrush (for solver margin).
            let needed = spread / 2 + baseBrush
            brushes[x] = min(maxBrush, max(minBrush, needed))
        }
        return brushes
    }

    /// Combine multiple horizon Y arrays with outlier-robust median.
    /// If any value deviates more than `outlierThreshold` from the initial
    /// median, it is excluded and the median is recomputed.  This handles
    /// catastrophic failure of one base method (e.g. Otsu on bright images).
    static func medianCombine(_ arrays: [[Int?]], outlierThreshold: Int = 80) -> [Int?] {
        guard let first = arrays.first else { return [] }
        let w = first.count
        var result = [Int?](repeating: nil, count: w)
        for x in 0..<w {
            var vals: [Int] = []
            for arr in arrays {
                if x < arr.count, let y = arr[x] { vals.append(y) }
            }
            guard !vals.isEmpty else { continue }

            // First median
            vals.sort()
            let med = vals[vals.count / 2]

            // Filter outliers
            if vals.count >= 3 {
                let filtered = vals.filter { abs($0 - med) <= outlierThreshold }
                if filtered.count >= 2 {
                    // Recompute median from inliers
                    result[x] = filtered[filtered.count / 2]
                } else {
                    result[x] = med
                }
            } else {
                result[x] = med
            }
        }
        return result
    }

    /// Compute a confidence score for a horizon Y array.
    /// Based on smoothness (low column-to-column variation), coverage, and plausibility.
    static func horizonConfidence(_ horizonY: [Int?], imageHeight: Int) -> Double {
        let defined = horizonY.compactMap { $0 }
        guard defined.count > horizonY.count / 20 else { return 0 }

        let coverage = Double(defined.count) / Double(max(1, horizonY.count))

        let diffs = zip(defined.dropLast(), defined.dropFirst()).map { abs($0 - $1) }
        let meanDiff = diffs.isEmpty ? 0.0 : Double(diffs.reduce(0, +)) / Double(diffs.count)
        let normalizedDiff = meanDiff / Double(max(1, imageHeight))
        let smoothness = 1.0 / (1.0 + normalizedDiff * 200.0)

        let avg = Double(defined.reduce(0, +)) / Double(defined.count)
        let heightFrac = avg / Double(imageHeight)
        let plausibility: Double
        if heightFrac < 0.05 || heightFrac > 0.95 {
            plausibility = 0.0
        } else if heightFrac < 0.15 || heightFrac > 0.85 {
            plausibility = 0.3
        } else {
            plausibility = 1.0 - abs(heightFrac - 0.5) * 1.2
        }
        let clampedPlausibility = max(0.05, min(1.0, plausibility))

        return coverage * smoothness * clampedPlausibility
    }

    /// Confidence-weighted combine: each method contributes proportionally
    /// to its confidence score, with outlier filtering.
    static func confidenceWeightedCombine(
        _ methodsAndWeights: [([Int?], Double)],
        outlierThreshold: Int = 80
    ) -> [Int?] {
        guard let (first, _) = methodsAndWeights.first else { return [] }
        let w = first.count
        var result = [Int?](repeating: nil, count: w)

        for x in 0..<w {
            var entries: [(y: Int, weight: Double)] = []
            for (arr, conf) in methodsAndWeights {
                if x < arr.count, let y = arr[x] {
                    entries.append((y, conf))
                }
            }
            guard !entries.isEmpty else { continue }

            if entries.count == 1 {
                result[x] = entries[0].y
                continue
            }

            let sortedY = entries.map(\.y).sorted()
            let med = sortedY[sortedY.count / 2]

            let filtered = entries.filter { abs($0.y - med) <= outlierThreshold }

            if filtered.isEmpty {
                result[x] = med
                continue
            }

            let totalWeight = filtered.reduce(0.0) { $0 + $1.weight }
            if totalWeight > 1e-10 {
                let weightedSum = filtered.reduce(0.0) { $0 + Double($1.y) * $1.weight }
                result[x] = Int((weightedSum / totalWeight).rounded())
            } else {
                result[x] = filtered[filtered.count / 2].y
            }
        }
        return result
    }
}
