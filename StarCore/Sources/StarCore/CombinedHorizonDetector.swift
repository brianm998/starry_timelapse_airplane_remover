/*
 CombinedHorizonDetector.swift — Combined horizon detection with Random Walker refinement.

 Runs multiple base methods (Otsu, DP, SIOX), median-combines the results
 with outlier filtering, then refines through a Random Walker solver.

 This is the best-performing horizon detection pipeline as measured by the
 horizon_test_bench benchmark across 229 test images spanning nighttime noise,
 dawn/sunrise transitions, and tree-filled horizons.
*/

import Foundation
import StarCppBridge
import StarCpp
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
        let gradResult = runGradProfile(scaled: scaled, image: image)
        let texResult = runTexture(scaled: scaled, image: image)

        let otsuY = await otsuResult
        let dpY = await dpResult

        // Log base method results
        let otsuDefined = otsuY?.compactMap({ $0 }).count ?? 0
        let dpDefined = dpY?.compactMap({ $0 }).count ?? 0
        let sioxDefined = sioxResult.compactMap({ $0 }).count
        let gradDefined = gradResult.compactMap({ $0 }).count
        let texDefined = texResult.compactMap({ $0 }).count
        Log.i("CombinedHorizonDetector: base methods — " +
              "otsu=\(otsuDefined)/\(imgW) dp=\(dpDefined)/\(imgW) siox=\(sioxDefined)/\(imgW) " +
              "grad=\(gradDefined)/\(imgW) tex=\(texDefined)/\(imgW) columns")

        // Confidence-weighted combine with outlier filtering.
        // Each base method gets a confidence score based on smoothness,
        // coverage, and plausibility. Methods with higher confidence
        // contribute more to the final horizon Y at each column.
        struct WeightedMethod {
            let name: String
            let horizonY: [Int?]
            let confidence: Double
        }

        var methods: [WeightedMethod] = []

        if let y = otsuY {
            let conf = horizonConfidence(y, imageHeight: imgH)
            if conf > 0.05 {
                methods.append(WeightedMethod(name: "otsu", horizonY: y, confidence: conf))
                Log.d("CombinedHorizonDetector: Otsu confidence=\(String(format: "%.3f", conf))")
            } else {
                Log.w("CombinedHorizonDetector: Otsu excluded (confidence=\(String(format: "%.3f", conf)))")
            }
        }
        if let y = dpY {
            let conf = horizonConfidence(y, imageHeight: imgH)
            if conf > 0.05 {
                methods.append(WeightedMethod(name: "dp", horizonY: y, confidence: conf))
                Log.d("CombinedHorizonDetector: DP confidence=\(String(format: "%.3f", conf))")
            } else {
                Log.w("CombinedHorizonDetector: DP excluded (confidence=\(String(format: "%.3f", conf)))")
            }
        }
        do {
            let conf = horizonConfidence(sioxResult, imageHeight: imgH)
            if conf > 0.05 {
                methods.append(WeightedMethod(name: "siox", horizonY: sioxResult, confidence: conf))
                Log.d("CombinedHorizonDetector: SIOX confidence=\(String(format: "%.3f", conf))")
            } else {
                Log.w("CombinedHorizonDetector: SIOX excluded (confidence=\(String(format: "%.3f", conf)))")
            }
        }
        do {
            let conf = horizonConfidence(gradResult, imageHeight: imgH)
            if conf > 0.05 {
                methods.append(WeightedMethod(name: "grad", horizonY: gradResult, confidence: conf))
                Log.d("CombinedHorizonDetector: Grad confidence=\(String(format: "%.3f", conf))")
            } else {
                Log.w("CombinedHorizonDetector: Grad excluded (confidence=\(String(format: "%.3f", conf)))")
            }
        }
        do {
            let conf = horizonConfidence(texResult, imageHeight: imgH)
            if conf > 0.05 {
                methods.append(WeightedMethod(name: "tex", horizonY: texResult, confidence: conf))
                Log.d("CombinedHorizonDetector: Tex confidence=\(String(format: "%.3f", conf))")
            } else {
                Log.w("CombinedHorizonDetector: Tex excluded (confidence=\(String(format: "%.3f", conf)))")
            }
        }
        // If all methods were excluded, fall back to using them all with equal weight
        if methods.isEmpty {
            Log.w("CombinedHorizonDetector: all base methods low-confidence, using all")
            if let y = otsuY { methods.append(WeightedMethod(name: "otsu", horizonY: y, confidence: 1.0)) }
            if let y = dpY { methods.append(WeightedMethod(name: "dp", horizonY: y, confidence: 1.0)) }
            methods.append(WeightedMethod(name: "siox", horizonY: sioxResult, confidence: 1.0))
            methods.append(WeightedMethod(name: "grad", horizonY: gradResult, confidence: 1.0))
            methods.append(WeightedMethod(name: "tex", horizonY: texResult, confidence: 1.0))
        }

        guard !methods.isEmpty else {
            throw "CombinedHorizonDetector: all base methods failed"
        }

        let combinedY = confidenceWeightedCombine(
            methods.map { ($0.horizonY, $0.confidence) },
            outlierThreshold: params.outlierThreshold,
            imageHeight: imgH
        )

        Log.i("CombinedHorizonDetector: combined using \(methods.map { "\($0.name)(\(String(format: "%.2f", $0.confidence)))" }.joined(separator: ", "))")

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

            // Gradient-aware correction: search upward from the color-based
            // horizon for a strong vertical L* gradient within 30 rows.
            // This pulls the horizon back up to the true ridgeline when
            // bright snow/canopy was classified as sky by the color scan.
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
                // Only snap if there's a meaningful gradient (>5 L* units)
                if bestGrad > 5.0 {
                    horizonY = bestGradY
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

    // MARK: - Vertical Gradient Profile

    /// Run vertical gradient profile horizon detection.
    /// For each column, finds the strongest sustained vertical gradient transition
    /// in a smoothed brightness profile — the sky→ground boundary.
    /// Complementary to color-based methods because it relies purely on edge structure.
    private static func runGradProfile(
        scaled: PixelatedImage,
        image: PixelatedImage,
        searchTopFraction: Double = 0.05,
        searchBottomFraction: Double = 0.95,
        verticalSmoothRadius: Int = 5,
        columnSmoothRadius: Int = 20
    ) -> [Int?] {
        let sW = scaled.width
        let sH = scaled.height
        let imgW = image.width
        let imgH = image.height

        let searchTop = max(0, Int(Double(sH) * searchTopFraction))
        let searchBot = min(sH - 1, Int(Double(sH) * searchBottomFraction))

        // Ensure 8-bit for gradient computation
        let img8 = PixelatedImage(mat: scaled.mat.ensureEightBit()) ?? scaled
        let pixelData: [UInt8]
        let cpp: Int
        switch img8.imageData {
        case .eightBit(let buf):
            pixelData = Array(buf)
            cpp = img8.componentsPerPixel
        default:
            return [Int?](repeating: nil, count: imgW)
        }
        let pixStride = img8.bytesPerRow

        var horizonYScaled = [Int?](repeating: nil, count: sW)

        for x in 0..<sW {
            // Extract column brightness (average of channels)
            var colBrightness = [Float](repeating: 0, count: sH)
            for y in 0..<sH {
                let base = y * pixStride + x * cpp
                if cpp >= 3 && base + 2 < pixelData.count {
                    colBrightness[y] = (Float(pixelData[base]) + Float(pixelData[base+1]) + Float(pixelData[base+2])) / 3.0
                } else if base < pixelData.count {
                    colBrightness[y] = Float(pixelData[base])
                }
            }

            // Smooth column brightness to suppress noise/stars
            let smoothR = verticalSmoothRadius
            var smoothBright = [Float](repeating: 0, count: sH)
            for y in 0..<sH {
                let lo = max(0, y - smoothR)
                let hi = min(sH - 1, y + smoothR)
                var sum: Float = 0
                for j in lo...hi { sum += colBrightness[j] }
                smoothBright[y] = sum / Float(hi - lo + 1)
            }

            // Absolute vertical gradient
            var gradProfile = [Float](repeating: 0, count: sH)
            for y in 1..<(sH - 1) {
                gradProfile[y] = abs(smoothBright[y + 1] - smoothBright[y - 1]) / 2.0
            }

            // Smooth gradient profile to find sustained transitions
            let gradSmoothR = smoothR * 2
            var smoothGrad = [Float](repeating: 0, count: sH)
            for y in searchTop...searchBot {
                let lo = max(searchTop, y - gradSmoothR)
                let hi = min(searchBot, y + gradSmoothR)
                var sum: Float = 0
                for j in lo...hi { sum += gradProfile[j] }
                smoothGrad[y] = sum / Float(hi - lo + 1)
            }

            // Find peak gradient in search band
            var bestY = (searchTop + searchBot) / 2
            var bestGrad: Float = 0
            for y in searchTop...searchBot {
                if smoothGrad[y] > bestGrad {
                    bestGrad = smoothGrad[y]
                    bestY = y
                }
            }

            // Refine to exact peak within ±smoothR
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

            // Only accept if gradient is meaningful
            if bestGrad >= 2.0 {
                horizonYScaled[x] = refinedY
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
        return scaleHorizonY(smoothed, fromWidth: sW, toWidth: imgW,
                             scaleY: Double(sH) / Double(imgH))
    }

    // MARK: - Texture/Entropy

    /// Run texture-based horizon detection via local variance transition.
    /// Sky has low texture variance; ground has high variance. The horizon is
    /// where variance transitions from low to high.
    private static func runTexture(
        scaled: PixelatedImage,
        image: PixelatedImage,
        searchTopFraction: Double = 0.05,
        searchBottomFraction: Double = 0.95,
        windowRadius: Int = 8,
        columnSmoothRadius: Int = 20
    ) -> [Int?] {
        let sW = scaled.width
        let sH = scaled.height
        let imgW = image.width
        let imgH = image.height

        let searchTop = max(0, Int(Double(sH) * searchTopFraction))
        let searchBot = min(sH - 1, Int(Double(sH) * searchBottomFraction))

        let img8 = PixelatedImage(mat: scaled.mat.ensureEightBit()) ?? scaled
        let pixelData: [UInt8]
        let cpp: Int
        switch img8.imageData {
        case .eightBit(let buf):
            pixelData = Array(buf)
            cpp = img8.componentsPerPixel
        default:
            return [Int?](repeating: nil, count: imgW)
        }
        let pixStride = img8.bytesPerRow
        let winR = windowRadius

        var horizonYScaled = [Int?](repeating: nil, count: sW)

        for x in 0..<sW {
            // Extract column brightness
            var colBright = [Float](repeating: 0, count: sH)
            for y in 0..<sH {
                let base = y * pixStride + x * cpp
                if cpp >= 3 && base + 2 < pixelData.count {
                    colBright[y] = (Float(pixelData[base]) + Float(pixelData[base+1]) + Float(pixelData[base+2])) / 3.0
                } else if base < pixelData.count {
                    colBright[y] = Float(pixelData[base])
                }
            }

            // Local variance via prefix sums
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

            // Smooth variance profile
            var smoothVar = [Float](repeating: 0, count: sH)
            for y in searchTop...searchBot {
                let lo = max(searchTop, y - winR)
                let hi = min(searchBot, y + winR)
                var sum: Float = 0
                for j in lo...hi { sum += localVar[j] }
                smoothVar[y] = sum / Float(hi - lo + 1)
            }

            // Derivative of variance: find max increase (low→high transition)
            var varDeriv = [Float](repeating: 0, count: sH)
            let derivR = 3
            for y in (searchTop + derivR)...(searchBot - derivR) {
                varDeriv[y] = smoothVar[y + derivR] - smoothVar[y - derivR]
            }

            // Smooth derivative
            var smoothDeriv = [Float](repeating: 0, count: sH)
            let derivSmoothR = 4
            for y in searchTop...searchBot {
                let lo = max(searchTop, y - derivSmoothR)
                let hi = min(searchBot, y + derivSmoothR)
                var sum: Float = 0
                for j in lo...hi { sum += varDeriv[j] }
                smoothDeriv[y] = sum / Float(hi - lo + 1)
            }

            // Peak positive derivative = horizon
            var bestY = (searchTop + searchBot) / 2
            var bestDeriv: Float = 0
            for y in searchTop...searchBot {
                if smoothDeriv[y] > bestDeriv {
                    bestDeriv = smoothDeriv[y]
                    bestY = y
                }
            }

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

        return scaleHorizonY(smoothed, fromWidth: sW, toWidth: imgW,
                             scaleY: Double(sH) / Double(imgH))
    }

    // MARK: - GrabCut

    /// Run GrabCut horizon detection using OpenCV's iterative graph-cut with GMMs.
    private static func runGrabCut(
        scaled: PixelatedImage,
        image: PixelatedImage,
        gcWorkingWidth: Int32 = 384,
        iterations: Int32 = 3
    ) -> [Int?] {
        let sW = scaled.width
        let sH = scaled.height
        let imgW = image.width
        let imgH = image.height

        // Quick initial horizon estimate from row brightness
        let img8 = PixelatedImage(mat: scaled.mat.ensureEightBit()) ?? scaled
        let pixelData: [UInt8]
        let cpp: Int
        switch img8.imageData {
        case .eightBit(let buf):
            pixelData = Array(buf)
            cpp = img8.componentsPerPixel
        default:
            return [Int?](repeating: nil, count: imgW)
        }
        let pixStride = img8.bytesPerRow

        var rowBrightness = [Float](repeating: 0, count: sH)
        for y in 0..<sH {
            var sum: Float = 0
            let sampleStep = max(1, sW / 50)
            var count = 0
            for x in stride(from: 0, to: sW, by: sampleStep) {
                let base = y * pixStride + x * cpp
                if cpp >= 3 && base + 2 < pixelData.count {
                    sum += (Float(pixelData[base]) + Float(pixelData[base+1]) + Float(pixelData[base+2])) / 3.0
                } else if base < pixelData.count {
                    sum += Float(pixelData[base])
                }
                count += 1
            }
            rowBrightness[y] = count > 0 ? sum / Float(count) : 0
        }

        let smoothR = 5
        var dropY = sH / 2
        var maxDrop: Float = 0
        for y in smoothR..<(sH - smoothR) {
            let absDrop = abs(rowBrightness[y - smoothR] - rowBrightness[y + smoothR])
            if absDrop > maxDrop { maxDrop = absDrop; dropY = y }
        }

        let scaleY = Double(sH) / Double(imgH)
        let fullInitY: [Int32] = (0..<imgW).map { x in
            return Int32(Double(dropY) / scaleY)
        }

        let resultY32 = PixelatedImageBridge.grabCutHorizon(
            image.mat,
            initHorizonY: fullInitY,
            iterations: iterations,
            maxWorkingWidth: gcWorkingWidth
        )

        return resultY32.map { $0 < 0 ? nil : Int($0) }
    }

    // MARK: - FFT Column Profile

    /// Run FFT-based horizon detection using high-frequency energy transition.
    private static func runFFT(
        scaled: PixelatedImage,
        image: PixelatedImage,
        searchTopFraction: Double = 0.05,
        searchBottomFraction: Double = 0.95,
        lowpassRadius: Int = 4,
        energyWindowRadius: Int = 12,
        columnSmoothRadius: Int = 20
    ) -> [Int?] {
        let sW = scaled.width
        let sH = scaled.height
        let imgW = image.width
        let imgH = image.height

        let searchTop = max(0, Int(Double(sH) * searchTopFraction))
        let searchBot = min(sH - 1, Int(Double(sH) * searchBottomFraction))

        let img8 = PixelatedImage(mat: scaled.mat.ensureEightBit()) ?? scaled
        let pixelData: [UInt8]
        let cpp: Int
        switch img8.imageData {
        case .eightBit(let buf):
            pixelData = Array(buf)
            cpp = img8.componentsPerPixel
        default:
            return [Int?](repeating: nil, count: imgW)
        }
        let pixStride = img8.bytesPerRow
        let lpR = lowpassRadius
        let ewR = energyWindowRadius

        var horizonYScaled = [Int?](repeating: nil, count: sW)

        for x in 0..<sW {
            var colBright = [Float](repeating: 0, count: sH)
            for y in 0..<sH {
                let base = y * pixStride + x * cpp
                if cpp >= 3 && base + 2 < pixelData.count {
                    colBright[y] = (Float(pixelData[base]) + Float(pixelData[base+1]) + Float(pixelData[base+2])) / 3.0
                } else if base < pixelData.count {
                    colBright[y] = Float(pixelData[base])
                }
            }

            // Lowpass via prefix sum
            var prefSum = [Float](repeating: 0, count: sH + 1)
            for y in 0..<sH { prefSum[y + 1] = prefSum[y] + colBright[y] }
            var lowpass = [Float](repeating: 0, count: sH)
            for y in 0..<sH {
                let lo = max(0, y - lpR)
                let hi = min(sH - 1, y + lpR)
                lowpass[y] = (prefSum[hi + 1] - prefSum[lo]) / Float(hi - lo + 1)
            }

            // Highpass squared energy via prefix sum
            var prefSqHP = [Float](repeating: 0, count: sH + 1)
            for y in 0..<sH {
                let hp = colBright[y] - lowpass[y]
                prefSqHP[y + 1] = prefSqHP[y] + hp * hp
            }
            var hfEnergy = [Float](repeating: 0, count: sH)
            for y in searchTop...searchBot {
                let lo = max(0, y - ewR)
                let hi = min(sH - 1, y + ewR)
                hfEnergy[y] = (prefSqHP[hi + 1] - prefSqHP[lo]) / Float(hi - lo + 1)
            }

            // Derivative + smooth
            let derivR = 4
            let dSmoothR = 4
            var smoothDeriv = [Float](repeating: 0, count: sH)
            for y in searchTop...searchBot {
                let lo = max(searchTop, y - dSmoothR)
                let hi = min(searchBot, y + dSmoothR)
                var sum: Float = 0
                for j in lo...hi {
                    if j - derivR >= searchTop && j + derivR <= searchBot {
                        sum += hfEnergy[j + derivR] - hfEnergy[j - derivR]
                    }
                }
                smoothDeriv[y] = sum / Float(hi - lo + 1)
            }

            var bestY = (searchTop + searchBot) / 2
            var bestDeriv: Float = 0
            for y in searchTop...searchBot {
                if smoothDeriv[y] > bestDeriv { bestDeriv = smoothDeriv[y]; bestY = y }
            }

            if bestDeriv > 1.0 { horizonYScaled[x] = bestY }
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

    /// Compute a confidence score for a horizon Y array: smoothness × coverage × plausibility.
    /// Returns a value in [0, 1] where higher = more confident.
    private static func horizonConfidence(_ horizonY: [Int?], imageHeight: Int) -> Double {
        let defined = horizonY.compactMap { $0 }
        guard defined.count > horizonY.count / 20 else { return 0 }

        // Coverage: fraction of columns with a defined horizon
        let coverage = Double(defined.count) / Double(max(1, horizonY.count))

        // Smoothness: 1 / (1 + mean absolute column-to-column diff / imageHeight)
        // Normalized by image height so it's scale-invariant.
        let diffs = zip(defined.dropLast(), defined.dropFirst()).map { abs($0 - $1) }
        let meanDiff = diffs.isEmpty ? 0.0 : Double(diffs.reduce(0, +)) / Double(diffs.count)
        let normalizedDiff = meanDiff / Double(max(1, imageHeight))
        // A meanDiff of ~0.5% of height = very smooth, ~5% = quite rough
        let smoothness = 1.0 / (1.0 + normalizedDiff * 200.0)

        // Plausibility: horizon should be in a reasonable range, not at top/bottom
        let avg = Double(defined.reduce(0, +)) / Double(defined.count)
        let heightFrac = avg / Double(imageHeight)
        // Best at 0.5 (center), worst at 0 or 1
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

    /// Compute per-column local smoothness weights for a horizon Y array.
    /// Each column gets a weight in (0, 1] based on how stable (non-spiky) the
    /// detector is in a local window around that column. A detector that makes a
    /// sudden jump at column X gets a low weight at X regardless of its global score.
    private static func perColumnLocalWeights(
        _ horizonY: [Int?],
        imageHeight: Int,
        windowHalf: Int = 20
    ) -> [Double] {
        let n = horizonY.count
        let scale = Double(max(1, imageHeight))
        var weights = [Double](repeating: 0.0, count: n)
        for x in 0..<n {
            guard horizonY[x] != nil else { continue }
            let lo = max(0, x - windowHalf)
            let hi = min(n - 1, x + windowHalf)
            var window: [Int] = []
            for j in lo...hi { if let y = horizonY[j] { window.append(y) } }
            guard window.count >= 3 else { weights[x] = 0.5; continue }
            let mean = Double(window.reduce(0, +)) / Double(window.count)
            let mad = window.map { abs(Double($0) - mean) }.reduce(0.0, +) / Double(window.count)
            // Normalize by image height so scale-invariant.
            // mad ≈ 0 → weight 1.0; mad ≈ 1% height → weight ~0.67; mad ≈ 5% height → weight ~0.17
            weights[x] = 1.0 / (1.0 + (mad / scale) * 50.0)
        }
        return weights
    }

    /// Median-filter a sparse [Int?] horizon array to remove residual spike columns.
    private static func medianFilterHorizonY(_ horizonY: [Int?], windowHalf: Int) -> [Int?] {
        let n = horizonY.count
        var result = horizonY
        for x in 0..<n {
            guard horizonY[x] != nil else { continue }
            let lo = max(0, x - windowHalf)
            let hi = min(n - 1, x + windowHalf)
            var window: [Int] = []
            for j in lo...hi { if let y = horizonY[j] { window.append(y) } }
            if !window.isEmpty {
                window.sort()
                result[x] = window[window.count / 2]
            }
        }
        return result
    }

    /// Confidence-weighted combine: merge multiple horizon Y arrays, weighting
    /// each method's contribution by its global confidence × per-column local
    /// smoothness. This prevents a noisy detector from raising the noise floor at
    /// columns where it makes a sudden spike, even if it's globally smooth.
    private static func confidenceWeightedCombine(
        _ methodsAndWeights: [([Int?], Double)],
        outlierThreshold: Int,
        imageHeight: Int
    ) -> [Int?] {
        guard let (first, _) = methodsAndWeights.first else { return [] }
        let w = first.count

        // Precompute per-column local smoothness for each detector
        let localWeightsPerMethod: [[Double]] = methodsAndWeights.map { (arr, _) in
            perColumnLocalWeights(arr, imageHeight: imageHeight)
        }

        var result = [Int?](repeating: nil, count: w)

        for x in 0..<w {
            // Collect (value, effective-weight) pairs — effective weight = globalConf × localSmooth
            var entries: [(y: Int, weight: Double)] = []
            for (idx, (arr, conf)) in methodsAndWeights.enumerated() {
                if x < arr.count, let y = arr[x] {
                    let localW = x < localWeightsPerMethod[idx].count ? localWeightsPerMethod[idx][x] : 1.0
                    entries.append((y, conf * localW))
                }
            }
            guard !entries.isEmpty else { continue }

            if entries.count == 1 {
                result[x] = entries[0].y
                continue
            }

            // Compute median for outlier filtering (unweighted, for stability)
            let sortedY = entries.map(\.y).sorted()
            let med = sortedY[sortedY.count / 2]

            // Filter outliers
            let filtered = entries.filter { abs($0.y - med) <= outlierThreshold }

            if filtered.isEmpty {
                result[x] = med
                continue
            }

            // Weighted average of non-outlier values
            let totalWeight = filtered.reduce(0.0) { $0 + $1.weight }
            if totalWeight > 1e-10 {
                let weightedSum = filtered.reduce(0.0) { $0 + Double($1.y) * $1.weight }
                result[x] = Int((weightedSum / totalWeight).rounded())
            } else {
                result[x] = filtered[filtered.count / 2].y
            }
        }

        // Final median-filter pass to remove any residual spike columns before RW refinement.
        return medianFilterHorizonY(result, windowHalf: 12)
    }

    /// Extract per-column horizon Y (topmost ground pixel) from a mask.
    static func extractHorizonY(from mask: PixelatedImage) -> [Int?] {
        let w = mask.width
        let h = mask.height
        var result = [Int?](repeating: nil, count: w)
        // Use mat.dataPtr + bytesPerRow stride so row-padding in the cv::Mat
        // (where mat.step > width × channels) is handled correctly.
        // The UnsafeBufferPointer from imageData has count = w*h*cpp (no padding),
        // which would trap on stride-based offsets, so we go through the raw pointer.
        guard let rawPtr = mask.mat.dataPtr else { return result }
        let cpp = mask.componentsPerPixel
        let rowBytes = mask.bytesPerRow   // == mat.step, includes any padding
        let totalBytes = h * rowBytes
        switch mask.imageData {
        case .eightBit:
            let ptr = rawPtr.assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                for y in 0..<h {
                    let offset = y * rowBytes + x * cpp
                    if offset < totalBytes && ptr[offset] <= 127 {
                        result[x] = y
                        break
                    }
                }
            }
        case .sixteenBit:
            let ptr = rawPtr.assumingMemoryBound(to: UInt16.self)
            let rowElems = rowBytes / MemoryLayout<UInt16>.stride
            let totalElems = h * rowElems
            for x in 0..<w {
                for y in 0..<h {
                    let offset = y * rowElems + x * cpp
                    if offset < totalElems && ptr[offset] <= 32767 {
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

    /// Check if a horizon Y array is plausible: mean Y within 10-90% of height,
    /// stddev < 15% of height, and reasonable coverage.
    private static func isPlausibleHorizon(_ horizonY: [Int?], imageHeight: Int) -> Bool {
        let defined = horizonY.compactMap { $0 }
        guard defined.count > horizonY.count / 10 else { return false } // <10% coverage

        let avg = Double(defined.reduce(0, +)) / Double(defined.count)
        let heightFrac = avg / Double(imageHeight)

        // Mean horizon Y must be in [10%, 90%] of image height
        guard heightFrac > 0.1 && heightFrac < 0.9 else { return false }

        // Stddev must be < 15% of image height (not wildly noisy)
        let variance = defined.map { pow(Double($0) - avg, 2) }.reduce(0, +) / Double(defined.count)
        let stddev = sqrt(variance)
        guard stddev < Double(imageHeight) * 0.15 else { return false }

        return true
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
