/*
 ParameterOptimizer.swift — Search for optimal parameters for each method.

 Uses training data to find best parameters, then evaluates on test data.
 This is the "model training" phase — finding the best parameter configuration
 and method combination for each image type.
*/

import Foundation
import StarCore
import KHTSwift
import kht_bridge

// MARK: - Optimization result

struct OptimizationResult: Sendable {
    let bestMethod: HorizonMethod
    let bestBrushRadius: Int
    let bestOtsuParams: OtsuParams
    let bestDPParams: DPParams
    let bestRWParams: RWParams
    let trainScore: Double
    let testScore: Double

    func printSummary() {
        print("\nOptimization Results:")
        print("  Best method: \(bestMethod.rawValue)")
        print("  Best brush radius: \(bestBrushRadius)")
        print("  DP params: lambda=\(bestDPParams.smoothnessLambda) " +
              "sobel=\(bestDPParams.sobelWeight) canny=\(bestDPParams.cannyWeight)")
        print("  RW params: beta=\(bestRWParams.beta)")
        print("  Train combined score: \(String(format: "%.4f", trainScore))")
        print("  Test combined score:  \(String(format: "%.4f", testScore))")
    }
}

// MARK: - Optimizer

actor ParameterOptimizer {
    private let verbose: Bool

    init(verbose: Bool = false) {
        self.verbose = verbose
    }

    /// Run optimization: find best parameters on training data, evaluate on test data.
    func optimize(trainSamples: [TestSample], testSamples: [TestSample]) async -> OptimizationResult {
        print("\n--- Phase 1: Evaluating base methods on training data ---")

        // Step 1: Evaluate each base method with various parameters on training data
        let otsuTrainScores = await evaluateOtsuGrid(samples: trainSamples)
        let dpTrainScores = await evaluateDPGrid(samples: trainSamples)
        let sioxTrainScore = await evaluateSIOX(samples: trainSamples)

        print("\nBase method training scores:")
        print("  Otsu (best crop): \(String(format: "%.4f", otsuTrainScores.bestScore))" +
              " (crop=\(String(format: "%.0f", otsuTrainScores.bestCrop))%)")
        print("  DP (best params): \(String(format: "%.4f", dpTrainScores.bestScore))" +
              " (λ=\(dpTrainScores.bestLambda) s=\(dpTrainScores.bestSobel) c=\(dpTrainScores.bestCanny))")
        print("  SIOX:             \(String(format: "%.4f", sioxTrainScore))")

        // Step 2: For each base method, try Random Walker refinement with different brush sizes
        print("\n--- Phase 2: Testing base+RW combinations on training data ---")

        let brushRadii = [10, 20, 30, 40, 60, 80, 100]
        var bestCombo: (method: HorizonMethod, brush: Int, score: Double) = (.otsu, 40, 0)

        for baseMethod in HorizonMethod.baseMethods {
            for brush in brushRadii {
                let score = await evaluateCombo(
                    baseMethod: baseMethod,
                    brushRadius: brush,
                    samples: trainSamples,
                    dpParams: DPParams(
                        smoothnessLambda: dpTrainScores.bestLambda,
                        sobelWeight: dpTrainScores.bestSobel,
                        cannyWeight: dpTrainScores.bestCanny
                    ),
                    otsuCrop: otsuTrainScores.bestCrop
                )
                let comboMethod: HorizonMethod
                switch baseMethod {
                case .otsu: comboMethod = .otsuThenRW
                case .dp: comboMethod = .dpThenRW
                case .siox: comboMethod = .sioxThenRW
                default: continue
                }

                if verbose {
                    print("  \(comboMethod.rawValue) brush=\(brush): \(String(format: "%.4f", score))")
                }

                if score > bestCombo.score {
                    bestCombo = (comboMethod, brush, score)
                }
            }
        }

        // Also try combined (median of all three) → RW
        for brush in brushRadii {
            let score = await evaluateCombinedCombo(
                brushRadius: brush,
                samples: trainSamples,
                dpParams: DPParams(
                    smoothnessLambda: dpTrainScores.bestLambda,
                    sobelWeight: dpTrainScores.bestSobel,
                    cannyWeight: dpTrainScores.bestCanny
                ),
                otsuCrop: otsuTrainScores.bestCrop
            )
            if verbose {
                print("  combined+rw brush=\(brush): \(String(format: "%.4f", score))")
            }
            if score > bestCombo.score {
                bestCombo = (.combinedThenRW, brush, score)
            }
        }

        print("\nBest combination on training data:")
        print("  \(bestCombo.method.rawValue) brush=\(bestCombo.brush): \(String(format: "%.4f", bestCombo.score))")

        // Step 3: Evaluate best combination on test data
        print("\n--- Phase 3: Evaluating best combination on test data ---")

        let testScore: Double
        if bestCombo.method == .combinedThenRW {
            testScore = await evaluateCombinedCombo(
                brushRadius: bestCombo.brush,
                samples: testSamples,
                dpParams: DPParams(
                    smoothnessLambda: dpTrainScores.bestLambda,
                    sobelWeight: dpTrainScores.bestSobel,
                    cannyWeight: dpTrainScores.bestCanny
                ),
                otsuCrop: otsuTrainScores.bestCrop
            )
        } else {
            let baseMethod: HorizonMethod
            switch bestCombo.method {
            case .otsuThenRW: baseMethod = .otsu
            case .dpThenRW: baseMethod = .dp
            case .sioxThenRW: baseMethod = .siox
            default: baseMethod = .otsu
            }
            testScore = await evaluateCombo(
                baseMethod: baseMethod,
                brushRadius: bestCombo.brush,
                samples: testSamples,
                dpParams: DPParams(
                    smoothnessLambda: dpTrainScores.bestLambda,
                    sobelWeight: dpTrainScores.bestSobel,
                    cannyWeight: dpTrainScores.bestCanny
                ),
                otsuCrop: otsuTrainScores.bestCrop
            )
        }

        print("  Test combined score: \(String(format: "%.4f", testScore))")

        return OptimizationResult(
            bestMethod: bestCombo.method,
            bestBrushRadius: bestCombo.brush,
            bestOtsuParams: OtsuParams(bottomPercentage: otsuTrainScores.bestCrop),
            bestDPParams: DPParams(
                smoothnessLambda: dpTrainScores.bestLambda,
                sobelWeight: dpTrainScores.bestSobel,
                cannyWeight: dpTrainScores.bestCanny
            ),
            bestRWParams: RWParams(beta: 90.0, brushRadius: bestCombo.brush),
            trainScore: bestCombo.score,
            testScore: testScore
        )
    }

    // MARK: - Grid searches

    struct OtsuGridResult: Sendable {
        let bestCrop: Double
        let bestScore: Double
    }

    private func evaluateOtsuGrid(samples: [TestSample]) async -> OtsuGridResult {
        let crops = stride(from: 10.0, through: 90.0, by: 10.0).map { $0 }
        var bestCrop = 50.0
        var bestScore = 0.0

        for crop in crops {
            var totalScore = 0.0
            var count = 0
            for sample in samples {
                guard let image = PixelatedImage(filename: sample.imagePath),
                      let refMask = PixelatedImage(filename: sample.maskPath) else { continue }

                if let mask = try? await image.horizonMask(at: 0, bottomPercentage: crop) {
                    // Scale to full res if needed
                    let score = MaskScorer.score(computed: mask.image, reference: refMask)
                    totalScore += score.combinedScore
                    count += 1
                }
            }
            let avgScore = count > 0 ? totalScore / Double(count) : 0
            if avgScore > bestScore {
                bestScore = avgScore
                bestCrop = crop
            }
        }
        return OtsuGridResult(bestCrop: bestCrop, bestScore: bestScore)
    }

    struct DPGridResult: Sendable {
        let bestLambda: Double
        let bestSobel: Double
        let bestCanny: Double
        let bestScore: Double
    }

    private func evaluateDPGrid(samples: [TestSample]) async -> DPGridResult {
        let lambdas = [1.0, 1.5, 2.0, 3.0]
        let sobels = [0.2, 0.6, 1.0]
        let cannys = [0.2, 0.6, 1.0]

        var best = (lambda: 2.0, sobel: 0.6, canny: 0.4, score: 0.0)

        for lambda in lambdas {
            for sobel in sobels {
                for canny in cannys {
                    var totalScore = 0.0
                    var count = 0
                    for sample in samples {
                        guard let image = PixelatedImage(filename: sample.imagePath),
                              let refMask = PixelatedImage(filename: sample.maskPath) else { continue }

                        let params = DPParams(
                            smoothnessLambda: lambda,
                            sobelWeight: sobel,
                            cannyWeight: canny
                        )
                        if let mask = try? DPRunner.runSingle(image: image, params: params) {
                            let score = MaskScorer.score(computed: mask, reference: refMask)
                            totalScore += score.combinedScore
                            count += 1
                        }
                    }
                    let avgScore = count > 0 ? totalScore / Double(count) : 0
                    if avgScore > best.score {
                        best = (lambda, sobel, canny, avgScore)
                    }
                }
            }
        }
        return DPGridResult(bestLambda: best.lambda, bestSobel: best.sobel,
                            bestCanny: best.canny, bestScore: best.score)
    }

    private func evaluateSIOX(samples: [TestSample]) async -> Double {
        var totalScore = 0.0
        var count = 0
        for sample in samples {
            guard let image = PixelatedImage(filename: sample.imagePath),
                  let refMask = PixelatedImage(filename: sample.maskPath) else { continue }
            let mask = await SIOXRunner.run(image: image)
            let score = MaskScorer.score(computed: mask, reference: refMask)
            totalScore += score.combinedScore
            count += 1
        }
        return count > 0 ? totalScore / Double(count) : 0
    }

    // MARK: - Combination evaluation

    private func evaluateCombo(
        baseMethod: HorizonMethod,
        brushRadius: Int,
        samples: [TestSample],
        dpParams: DPParams,
        otsuCrop: Double
    ) async -> Double {
        var totalScore = 0.0
        var count = 0

        for sample in samples {
            guard let image = PixelatedImage(filename: sample.imagePath),
                  let refMask = PixelatedImage(filename: sample.maskPath) else { continue }

            // Get base horizon
            let baseMask: PixelatedImage?
            switch baseMethod {
            case .otsu:
                baseMask = try? await OtsuRunner.run(image: image,
                    params: OtsuParams(bottomPercentage: otsuCrop))
            case .dp:
                baseMask = try? DPRunner.runSingle(image: image, params: dpParams)
            case .siox:
                baseMask = await SIOXRunner.run(image: image)
            default:
                baseMask = nil
            }

            guard let base = baseMask else { continue }
            let baseY = BandSimulator.horizonYFromMask(base)

            // Run RW refinement
            let rwParams = RWParams(brushRadius: brushRadius)
            let result = RWRunner.run(image: image, baseHorizonY: baseY, params: rwParams)
            let score = MaskScorer.score(computed: result, reference: refMask)
            totalScore += score.combinedScore
            count += 1
        }

        return count > 0 ? totalScore / Double(count) : 0
    }

    private func evaluateCombinedCombo(
        brushRadius: Int,
        samples: [TestSample],
        dpParams: DPParams,
        otsuCrop: Double
    ) async -> Double {
        var totalScore = 0.0
        var count = 0

        for sample in samples {
            guard let image = PixelatedImage(filename: sample.imagePath),
                  let refMask = PixelatedImage(filename: sample.maskPath) else { continue }

            // Get all three base horizons
            let otsuMask = try? await OtsuRunner.run(image: image,
                params: OtsuParams(bottomPercentage: otsuCrop))
            let dpMask = try? DPRunner.runSingle(image: image, params: dpParams)
            let sioxMask = await SIOXRunner.run(image: image)

            var arrays: [[Int?]] = []
            if let m = otsuMask { arrays.append(BandSimulator.horizonYFromMask(m)) }
            if let m = dpMask { arrays.append(BandSimulator.horizonYFromMask(m)) }
            arrays.append(BandSimulator.horizonYFromMask(sioxMask))

            guard !arrays.isEmpty else { continue }
            let combinedY = BandSimulator.medianCombine(arrays)

            let rwParams = RWParams(brushRadius: brushRadius)
            let result = RWRunner.run(image: image, baseHorizonY: combinedY, params: rwParams)
            let score = MaskScorer.score(computed: result, reference: refMask)
            totalScore += score.combinedScore
            count += 1
        }

        return count > 0 ? totalScore / Double(count) : 0
    }
}
