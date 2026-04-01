/*
 CombinedHorizonDetector.swift — Combined horizon detection with Random Walker refinement.

 Runs multiple base methods (Otsu, DP, SIOX), median-combines the results
 with outlier filtering, then refines through a Random Walker solver.

 This is the best-performing horizon detection pipeline as measured by the
 horizon_test_bench benchmark across 229 test images spanning nighttime noise,
 dawn/sunrise transitions, and tree-filled horizons.
*/

import Foundation
import KHTSwift
import kht_bridge
import logging

/// Combined horizon detection: run base methods, median-combine, RW-refine.
public enum CombinedHorizonDetector {

    /// Default parameters for the combined detector.
    public struct Params: Sendable {
        /// Maximum dimension for base method processing (Otsu, DP, SIOX).
        public var baseWorkingSize: Int = 512

        /// Brush radii to try for Random Walker refinement.
        /// Multiple radii are tested and the best-scoring result is kept.
        public var brushRadii: [Int] = [40, 80, 160]

        /// Random Walker beta (edge weight sensitivity).
        public var rwBeta: Double = 90.0

        /// Random Walker maximum working width.
        public var rwMaxWorkingWidth: Int32 = 4096

        /// Outlier threshold for median combining: values deviating more
        /// than this from the initial median are excluded.
        public var outlierThreshold: Int = 80

        /// SIOX band search range (fractions of image height).
        public var sioxBandTopFraction: Double = 0.15
        public var sioxBandBottomFraction: Double = 0.85

        /// DP grid search parameters.
        public var dpLambdas: [Double] = [1.0, 1.5, 2.0, 3.0]
        public var dpSobelWeights: [Double] = [0.2, 0.6, 1.0]
        public var dpCannyWeights: [Double] = [0.2, 0.6, 1.0]

        public init() {}
    }

    // MARK: - Main entry point

    /// Run the full combined+RW pipeline on an image.
    /// Returns a HorizonMask with the detected horizon.
    public static func detect(
        image: PixelatedImage,
        params: Params = Params()
    ) async throws -> HorizonMask {
        let imgW = image.width
        let imgH = image.height

        // Scale down for base method processing
        let (scaled, _, _) = scaleForProcessing(image, maxDim: params.baseWorkingSize)
        let sW = scaled.width
        let sH = scaled.height

        Log.i("CombinedHorizonDetector: image \(imgW)x\(imgH), working \(sW)x\(sH)")

        // Run base methods in parallel
        async let otsuResult = runOtsu(scaled: scaled, image: image)
        async let dpResult = runDP(scaled: scaled, image: image, params: params)
        let sioxResult = runSIOX(scaled: scaled, image: image, params: params)

        let otsuY = await otsuResult
        let dpY = await dpResult

        // Log base method results
        let otsuDefined = otsuY?.compactMap({ $0 }).count ?? 0
        let dpDefined = dpY?.compactMap({ $0 }).count ?? 0
        let sioxDefined = sioxResult.compactMap({ $0 }).count
        Log.i("CombinedHorizonDetector: base methods — " +
              "otsu=\(otsuDefined)/\(imgW) dp=\(dpDefined)/\(imgW) siox=\(sioxDefined)/\(imgW) columns")

        // Median-combine with outlier filtering
        var arrays: [[Int?]] = []
        if let y = otsuY { arrays.append(y) }
        if let y = dpY { arrays.append(y) }
        arrays.append(sioxResult)

        guard !arrays.isEmpty else {
            throw "CombinedHorizonDetector: all base methods failed"
        }

        let combinedY = medianCombine(arrays, outlierThreshold: params.outlierThreshold)

        // Try each brush radius and pick the best result
        var bestMask: PixelatedImage? = nil
        var bestScore: Double = -1

        for brush in params.brushRadii {
            let mask = runRandomWalker(
                image: image,
                baseHorizonY: combinedY,
                brushRadius: brush,
                beta: params.rwBeta,
                maxWorkingWidth: params.rwMaxWorkingWidth
            )

            // Score by horizon quality: smoothness + coverage
            let score = selfScore(mask: mask, imageHeight: imgH)
            Log.d("CombinedHorizonDetector: brush=\(brush) selfScore=\(String(format: "%.4f", score))")

            if score > bestScore {
                bestScore = score
                bestMask = mask
            }
        }

        guard let finalMask = bestMask else {
            throw "CombinedHorizonDetector: RW produced no valid mask"
        }

        guard let horizonMask = HorizonMask(finalMask) else {
            throw "CombinedHorizonDetector: cannot compute bounds from mask"
        }

        Log.i("CombinedHorizonDetector: done, horizon Y range [\(horizonMask.horizonTopY)..\(horizonMask.horizonBottomY)]")
        return horizonMask
    }

    // MARK: - Base methods

    /// Run Otsu at multiple crop percentages and return per-column horizon Y at full resolution.
    private static func runOtsu(
        scaled: PixelatedImage,
        image: PixelatedImage
    ) async -> [Int?]? {
        let cropSteps = stride(from: 10.0, through: 90.0, by: 5.0)
        var bestMask: PixelatedImage? = nil
        var bestScore = -1.0

        for crop in cropSteps {
            guard let mask = try? await scaled.horizonMask(
                at: 0,
                bottomPercentage: crop,
                useCannyEdgeDetection: false
            ) else { continue }

            let horizonY = extractHorizonY(from: mask.image)
            let defined = horizonY.compactMap { $0 }
            guard !defined.isEmpty else { continue }

            let coverage = Double(defined.count) / Double(horizonY.count)
            let avgY = Double(defined.reduce(0, +)) / Double(defined.count)
            let heightFrac = avgY / Double(scaled.height)
            let centerPenalty = 1.0 - abs(heightFrac - 0.5) * 2.0
            let score = coverage * max(0.1, centerPenalty)

            if score > bestScore {
                bestScore = score
                bestMask = mask.image
            }
        }

        guard let mask = bestMask else { return nil }

        // Scale to original resolution
        let origW = image.width
        let origH = image.height
        let fullMask: PixelatedImage
        if mask.width != origW || mask.height != origH {
            if let upscaled = mask.mat.upScale(to: UInt(origW), height: UInt(origH)),
               let pi = PixelatedImage(mat: upscaled) {
                fullMask = thresholdToBinary(pi)
            } else {
                fullMask = mask
            }
        } else {
            fullMask = mask
        }
        return extractHorizonY(from: fullMask)
    }

    /// Run DP with grid search and return per-column horizon Y at full resolution.
    private static func runDP(
        scaled: PixelatedImage,
        image: PixelatedImage,
        params: Params
    ) async -> [Int?]? {
        var bestMask: PixelatedImage? = nil
        var bestScore = -1.0

        for lambda in params.dpLambdas {
            for sobelW in params.dpSobelWeights {
                for cannyW in params.dpCannyWeights {
                    guard let mask = try? scaled.dpHorizonDetect(
                        smoothnessLambda: lambda,
                        sobelWeight: sobelW,
                        cannyWeight: cannyW
                    ) else { continue }

                    let horizonY = extractHorizonY(from: mask)
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

        guard let mask = bestMask else { return nil }

        let origW = image.width
        let origH = image.height
        let fullMask: PixelatedImage
        if mask.width != origW || mask.height != origH {
            if let up = mask.mat.upScale(to: UInt(origW), height: UInt(origH)),
               let pi = PixelatedImage(mat: up) {
                fullMask = thresholdToBinary(pi)
            } else {
                fullMask = mask
            }
        } else {
            fullMask = mask
        }
        return extractHorizonY(from: fullMask)
    }

    /// Run standalone SIOX horizon detection and return per-column horizon Y at full resolution.
    private static func runSIOX(
        scaled: PixelatedImage,
        image: PixelatedImage,
        params: Params
    ) -> [Int?] {
        let sW = scaled.width
        let sH = scaled.height
        let imgW = image.width
        let imgH = image.height

        let bandTop = Int(Double(sH) * params.sioxBandTopFraction)
        let bandBot = Int(Double(sH) * params.sioxBandBottomFraction)
        let skyFloorY = bandTop
        let groundCeilingY = bandBot

        // Ensure 8-bit for SIOX
        let img8 = PixelatedImage(mat: scaled.mat.ensureEightBit()) ?? scaled
        let pixelData: [UInt8]
        switch img8.imageData {
        case .eightBit(let buf):
            pixelData = Array(buf)
        default:
            return [Int?](repeating: nil, count: imgW)
        }
        let pixStride = img8.bytesPerRow
        let pxBpp = max(1, img8.bytesPerPixel)
        let halfW = 30
        let intensityWeight: Float = 100.0

        // sRGB -> linear LUT
        let linearLUT: [Float] = (0..<256).map { v in
            let n = Float(v) / 255.0
            return n <= 0.04045 ? n / 12.92 : pow((n + 0.055) / 1.055, 2.4)
        }

        func linRGBtoLABI(r: Float, g: Float, b: Float)
            -> (L: Float, a: Float, b: Float, I: Float)
        {
            let X = 0.4124564*r + 0.3575761*g + 0.1804375*b
            let Y = 0.2126729*r + 0.7151522*g + 0.0721750*b
            let Z = 0.0193339*r + 0.1191920*g + 0.9503041*b
            let Xn: Float = 0.95047, Yn: Float = 1.0, Zn: Float = 1.08883
            func f(_ t: Float) -> Float {
                t > 0.008856 ? pow(t, 1.0/3.0) : 7.787*t + (16.0/116.0)
            }
            let (fx, fy, fz) = (f(X/Xn), f(Y/Yn), f(Z/Zn))
            return (116.0*fy - 16.0, 500.0*(fx - fy), 200.0*(fy - fz), Y)
        }

        func dist2(_ l1: Float, _ a1: Float, _ b1: Float, _ i1: Float,
                   _ l2: Float, _ a2: Float, _ b2: Float, _ i2: Float) -> Float {
            let dL = l1-l2, da = a1-a2, db = b1-b2, di = i1-i2
            return dL*dL + da*da + db*db + di*di
        }

        // Windowed LAB cache with prefix sums
        let globalTop = max(0, bandTop - 20)
        let globalBot = min(sH - 1, bandBot + 20)
        let rowStep = 2
        let bandH = (globalBot - globalTop) / rowStep + 1
        let pxLeft = max(0, 0 - halfW)
        let pxRight = min(sW - 1, sW - 1 + halfW)
        let pxWidth = pxRight - pxLeft + 1

        var winL  = [Float](repeating: 0, count: bandH * sW)
        var winA  = [Float](repeating: 0, count: bandH * sW)
        var winBB = [Float](repeating: 0, count: bandH * sW)
        var winI  = [Float](repeating: 0, count: bandH * sW)

        for iy in stride(from: globalTop, through: globalBot, by: rowStep) {
            let ri = (iy - globalTop) / rowStep
            var prefR = [Float](repeating: 0, count: pxWidth + 1)
            var prefG = [Float](repeating: 0, count: pxWidth + 1)
            var prefB = [Float](repeating: 0, count: pxWidth + 1)
            for i in 0..<pxWidth {
                let ix = pxLeft + i
                let base = iy * pixStride + ix * pxBpp
                guard base + 2 < pixelData.count, base >= 0 else { continue }
                let bV = linearLUT[Int(pixelData[base])]
                let gV = pxBpp > 1 ? linearLUT[Int(pixelData[base + 1])] : bV
                let rV = pxBpp > 2 ? linearLUT[Int(pixelData[base + 2])] : bV
                prefR[i+1] = prefR[i] + rV
                prefG[i+1] = prefG[i] + gV
                prefB[i+1] = prefB[i] + bV
            }
            for ix in 0..<sW {
                let i = ix - pxLeft
                let lo = max(0, i - halfW)
                let hi = min(pxWidth - 1, i + halfW)
                let cnt = Float(hi - lo + 1)
                let mr = (prefR[hi+1] - prefR[lo]) / cnt
                let mg = (prefG[hi+1] - prefG[lo]) / cnt
                let mb = (prefB[hi+1] - prefB[lo]) / cnt
                let (L, a, lab_b, intensity) = linRGBtoLABI(r: mr, g: mg, b: mb)
                let idx = ri * sW + ix
                winL[idx] = L; winA[idx] = a; winBB[idx] = lab_b
                winI[idx] = intensity * intensityWeight
            }
        }

        func labiAt(ix: Int, iy: Int) -> (L: Float, a: Float, b: Float, I: Float) {
            let ri = min((iy - globalTop) / rowStep, bandH - 1)
            let idx = ri * sW + ix
            return (winL[idx], winA[idx], winBB[idx], winI[idx])
        }

        // Global centroids
        let centroidColStep = max(1, sW / 40)
        var skyLSum: Float = 0, skyASum: Float = 0, skyBBSum: Float = 0, skyISum: Float = 0
        var nSky = 0
        for ix in stride(from: 0, through: sW - 1, by: centroidColStep) {
            let yStep = max(1, skyFloorY / 20)
            for iy in stride(from: 0, to: skyFloorY, by: yStep) {
                let base = iy * pixStride + ix * pxBpp
                guard base + 2 < pixelData.count, base >= 0 else { continue }
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

        var gndLSum: Float = 0, gndASum: Float = 0, gndBBSum: Float = 0, gndISum: Float = 0
        var nGnd = 0
        for ix in stride(from: 0, through: sW - 1, by: centroidColStep) {
            let rowSpan = sH - groundCeilingY
            let yStep = max(1, rowSpan / 20)
            for iy in stride(from: groundCeilingY, to: sH, by: yStep) {
                let base = iy * pixStride + ix * pxBpp
                guard base + 2 < pixelData.count, base >= 0 else { continue }
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
        var scaledResult = [Int?](repeating: nil, count: sW)
        for ix in 0..<sW {
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
            scaledResult[ix] = max(skyFloorY, min(horizonY, groundCeilingY))
        }

        // Median filter
        let medW = 40
        var smoothed = scaledResult
        for ix in 0..<sW {
            guard scaledResult[ix] != nil else { continue }
            let lo = max(0, ix - medW)
            let hi = min(sW - 1, ix + medW)
            var window: [Int] = []
            for jx in lo...hi { if let y = scaledResult[jx] { window.append(y) } }
            if !window.isEmpty {
                window.sort()
                smoothed[ix] = window[window.count / 2]
            }
        }

        // Scale back to original resolution
        return scaleHorizonY(smoothed, fromWidth: sW, toWidth: imgW,
                             scaleY: Double(sH) / Double(imgH))
    }

    // MARK: - Random Walker refinement

    /// Run Random Walker refinement with a simulated painted band.
    private static func runRandomWalker(
        image: PixelatedImage,
        baseHorizonY: [Int?],
        brushRadius: Int,
        beta: Double,
        maxWorkingWidth: Int32
    ) -> PixelatedImage {
        let imgW = image.width
        let imgH = image.height

        var bandTop = [Int32](repeating: -1, count: imgW)
        var bandBot = [Int32](repeating: -1, count: imgW)
        var skyFloor = [Int32](repeating: -1, count: imgW)
        var groundCeil = [Int32](repeating: -1, count: imgW)

        for x in 0..<imgW {
            guard let y = baseHorizonY[x] else { continue }
            let top = max(0, y - brushRadius)
            let bot = min(imgH - 1, y + brushRadius)
            bandTop[x] = Int32(top)
            bandBot[x] = Int32(bot)
            skyFloor[x] = Int32(max(0, top))
            groundCeil[x] = Int32(min(imgH - 1, bot))
        }

        let resultY = PixelatedImageBridge.randomWalkerHorizon(
            image.mat,
            bandTopY: bandTop,
            bandBottomY: bandBot,
            skyFloorY: skyFloor,
            groundCeilY: groundCeil,
            beta: beta,
            maxWorkingWidth: maxWorkingWidth
        )

        let yArray: [Int?] = resultY.map { $0 < 0 ? nil : Int($0) }
        let maskMat = PixelatedImageBridge.binaryHorizonMask(
            width: Int32(imgW), height: Int32(imgH), horizonY: yArray
        )
        return PixelatedImage(mat: maskMat)!
    }

    // MARK: - Helpers

    /// Combine multiple horizon Y arrays with outlier-robust median.
    private static func medianCombine(_ arrays: [[Int?]], outlierThreshold: Int) -> [Int?] {
        guard let first = arrays.first else { return [] }
        let w = first.count
        var result = [Int?](repeating: nil, count: w)
        for x in 0..<w {
            var vals: [Int] = []
            for arr in arrays {
                if x < arr.count, let y = arr[x] { vals.append(y) }
            }
            guard !vals.isEmpty else { continue }

            vals.sort()
            let med = vals[vals.count / 2]

            if vals.count >= 3 {
                let filtered = vals.filter { abs($0 - med) <= outlierThreshold }
                if filtered.count >= 2 {
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

    /// Extract per-column horizon Y (topmost ground pixel) from a mask.
    private static func extractHorizonY(from mask: PixelatedImage) -> [Int?] {
        let w = mask.width
        let h = mask.height
        var result = [Int?](repeating: nil, count: w)
        switch mask.imageData {
        case .eightBit(let buf):
            let cpp = mask.componentsPerPixel
            for x in 0..<w {
                for y in 0..<h {
                    let offset = y * w * cpp + x * cpp
                    if offset < buf.count && buf[offset] <= 127 {
                        result[x] = y
                        break
                    }
                }
            }
        case .sixteenBit(let buf):
            let cpp = mask.componentsPerPixel
            for x in 0..<w {
                for y in 0..<h {
                    let offset = y * w * cpp + x * cpp
                    if offset < buf.count && buf[offset] <= 32767 {
                        result[x] = y
                        break
                    }
                }
            }
        default:
            // Fallback using generic pixel access
            for x in 0..<w {
                for y in 0..<h {
                    if pixelIntensity8(mask, x: x, y: y) <= 127 {
                        result[x] = y
                        break
                    }
                }
            }
        }
        return result
    }

    /// Simple pixel intensity reader for fallback.
    private static func pixelIntensity8(_ img: PixelatedImage, x: Int, y: Int) -> UInt8 {
        switch img.imageData {
        case .eightBit(let buf):
            let cpp = img.componentsPerPixel
            let offset = y * img.width * cpp + x * cpp
            guard offset < buf.count else { return 0 }
            return buf[offset]
        case .sixteenBit(let buf):
            let cpp = img.componentsPerPixel
            let offset = y * img.width * cpp + x * cpp
            guard offset < buf.count else { return 0 }
            return UInt8(min(255, buf[offset] >> 8))
        default:
            return 0
        }
    }

    /// Threshold a potentially anti-aliased mask to pure binary.
    private static func thresholdToBinary(_ image: PixelatedImage) -> PixelatedImage {
        let w = image.width
        let h = image.height
        let horizonY = extractHorizonY(from: image)
        let mat = PixelatedImageBridge.binaryHorizonMask(
            width: Int32(w), height: Int32(h), horizonY: horizonY
        )
        return PixelatedImage(mat: mat)!
    }

    /// Self-score a mask without a reference: smoothness + coverage + plausibility.
    private static func selfScore(mask: PixelatedImage, imageHeight: Int) -> Double {
        let horizonY = extractHorizonY(from: mask)
        let defined = horizonY.compactMap { $0 }
        guard !defined.isEmpty else { return 0 }

        // Coverage: fraction of columns with a defined horizon
        let coverage = Double(defined.count) / Double(horizonY.count)

        // Smoothness: 1 / (1 + mean absolute column-to-column diff)
        let diffs = zip(defined.dropLast(), defined.dropFirst()).map { abs($0 - $1) }
        let meanDiff = diffs.isEmpty ? 0 : Double(diffs.reduce(0, +)) / Double(diffs.count)
        let smoothness = 1.0 / (1.0 + meanDiff)

        // Plausibility: horizon should be in the middle range (not all-sky or all-ground)
        let avgY = Double(defined.reduce(0, +)) / Double(defined.count)
        let heightFrac = avgY / Double(imageHeight)
        let plausibility = 1.0 - abs(heightFrac - 0.5) * 1.5
        let clampedPlausibility = max(0.1, min(1.0, plausibility))

        return 0.3 * coverage + 0.4 * smoothness + 0.3 * clampedPlausibility
    }

    /// Scale image for processing.
    private static func scaleForProcessing(
        _ image: PixelatedImage,
        maxDim: Int
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

    /// Scale horizon Y from one resolution to another.
    private static func scaleHorizonY(
        _ horizonY: [Int?],
        fromWidth: Int,
        toWidth: Int,
        scaleY: Double
    ) -> [Int?] {
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
