/*
 ParameterOptimizer.swift — Search for optimal parameters for each method.

 Uses training data to find best parameters, then evaluates on test data.
 This is the "model training" phase — finding the best parameter configuration
 and method combination for each image type.

 All sample-level evaluation runs in parallel, bounded by maxConcurrency.
*/

import Foundation
import StarCore
import StarCpp
import starcpp_bridge
import Semaphore

// MARK: - Optimization result

struct OptimizationResult: Sendable {
    let bestMethod: HorizonMethod
    let bestBrushRadius: Int
    let bestSeedMargin: Int
    let bestOtsuParams: OtsuParams
    let bestDPParams: DPParams
    let bestRWParams: RWParams
    let trainScore: Double
    let testScore: Double

    func printSummary() {
        print("\nOptimization Results:")
        print("  Best method: \(bestMethod.rawValue)")
        print("  Best brush radius: \(bestBrushRadius)")
        print("  Best seed margin: \(bestSeedMargin)")
        print("  DP params: lambda=\(bestDPParams.smoothnessLambda) " +
              "sobel=\(bestDPParams.sobelWeight) canny=\(bestDPParams.cannyWeight)")
        print("  RW params: beta=\(bestRWParams.beta) seedMargin=\(bestRWParams.seedMargin)")
        print("  Train combined score: \(String(format: "%.4f", trainScore))")
        print("  Test combined score:  \(String(format: "%.4f", testScore))")
    }
}

// MARK: - Optimizer

actor ParameterOptimizer {
    private let verbose: Bool
    private let maxConcurrency: Int

    init(verbose: Bool = false, maxConcurrency: Int = ParallelBenchmark.defaultConcurrency) {
        self.verbose = verbose
        self.maxConcurrency = maxConcurrency
    }

    /// Run optimization: find best parameters on training data, evaluate on test data.
    func optimize(trainSamples: [TestSample], testSamples: [TestSample]) async -> OptimizationResult {
        let concurrency = maxConcurrency

        print("\n--- Phase 1: Evaluating base methods on training data (\(concurrency) concurrent) ---")

        // Step 1: Evaluate each base method with various parameters on training data
        let otsuTrainScores = await evaluateOtsuGrid(samples: trainSamples, concurrency: concurrency)
        let dpTrainScores = await evaluateDPGrid(samples: trainSamples, concurrency: concurrency)
        let sioxTrainScore = await evaluateSIOX(samples: trainSamples, concurrency: concurrency)

        print("\nBase method training scores:")
        print("  Otsu (best crop): \(String(format: "%.4f", otsuTrainScores.bestScore))" +
              " (crop=\(String(format: "%.0f", otsuTrainScores.bestCrop))%)")
        print("  DP (best params): \(String(format: "%.4f", dpTrainScores.bestScore))" +
              " (λ=\(dpTrainScores.bestLambda) s=\(dpTrainScores.bestSobel) c=\(dpTrainScores.bestCanny))")
        print("  SIOX:             \(String(format: "%.4f", sioxTrainScore))")

        // Step 2: For each base method, try Random Walker refinement with different brush sizes
        print("\n--- Phase 2: Testing base+RW combinations on training data ---")

        let brushRadii = [15, 25, 40, 60, 80, 100]
        let seedMargins = [0, 20, 50, 100]
        let bestDPParams = DPParams(
            smoothnessLambda: dpTrainScores.bestLambda,
            sobelWeight: dpTrainScores.bestSobel,
            cannyWeight: dpTrainScores.bestCanny
        )
        let bestOtsuCrop = otsuTrainScores.bestCrop

        // Evaluate all base+brush+seedMargin combos in parallel
        struct ComboCandidate: Sendable {
            let method: HorizonMethod
            let brush: Int
            let seedMargin: Int
            let score: Double
        }

        let comboCandidates: [ComboCandidate] = await withTaskGroup(of: ComboCandidate.self) { group in
            // base methods × brush radii × seed margins
            for baseMethod in HorizonMethod.baseMethods {
                for brush in brushRadii {
                    for margin in seedMargins {
                        let comboMethod: HorizonMethod
                        switch baseMethod {
                        case .otsu: comboMethod = .otsuThenRW
                        case .dp: comboMethod = .dpThenRW
                        case .siox: comboMethod = .sioxThenRW
                        default: continue
                        }
                        group.addTask { [concurrency] in
                            let score = await Self.evaluateComboStatic(
                                baseMethod: baseMethod,
                                brushRadius: brush,
                                seedMargin: margin,
                                samples: trainSamples,
                                dpParams: bestDPParams,
                                otsuCrop: bestOtsuCrop,
                                concurrency: concurrency
                            )
                            return ComboCandidate(method: comboMethod, brush: brush,
                                                  seedMargin: margin, score: score)
                        }
                    }
                }
            }
            // combined (median of all three) → RW
            for brush in brushRadii {
                for margin in seedMargins {
                    group.addTask { [concurrency] in
                        let score = await Self.evaluateCombinedComboStatic(
                            brushRadius: brush,
                            seedMargin: margin,
                            samples: trainSamples,
                            dpParams: bestDPParams,
                            otsuCrop: bestOtsuCrop,
                            concurrency: concurrency
                        )
                        return ComboCandidate(method: .combinedThenRW, brush: brush,
                                              seedMargin: margin, score: score)
                    }
                }
            }

            var results: [ComboCandidate] = []
            for await candidate in group {
                results.append(candidate)
            }
            return results
        }

        var bestCombo: (method: HorizonMethod, brush: Int, seedMargin: Int, score: Double) = (.otsu, 40, 0, 0)
        for c in comboCandidates.sorted(by: { $0.score > $1.score }) {
            if verbose {
                print("  \(c.method.rawValue) brush=\(c.brush) margin=\(c.seedMargin): \(String(format: "%.4f", c.score))")
            }
            if c.score > bestCombo.score {
                bestCombo = (c.method, c.brush, c.seedMargin, c.score)
            }
        }

        print("\nBest combination on training data:")
        print("  \(bestCombo.method.rawValue) brush=\(bestCombo.brush) margin=\(bestCombo.seedMargin): \(String(format: "%.4f", bestCombo.score))")

        // Step 3: Evaluate best combination on test data
        print("\n--- Phase 3: Evaluating best combination on test data ---")

        let testScore: Double
        if bestCombo.method == .combinedThenRW {
            testScore = await Self.evaluateCombinedComboStatic(
                brushRadius: bestCombo.brush,
                seedMargin: bestCombo.seedMargin,
                samples: testSamples,
                dpParams: bestDPParams,
                otsuCrop: bestOtsuCrop,
                concurrency: concurrency
            )
        } else {
            let baseMethod: HorizonMethod
            switch bestCombo.method {
            case .otsuThenRW: baseMethod = .otsu
            case .dpThenRW: baseMethod = .dp
            case .sioxThenRW: baseMethod = .siox
            default: baseMethod = .otsu
            }
            testScore = await Self.evaluateComboStatic(
                baseMethod: baseMethod,
                brushRadius: bestCombo.brush,
                seedMargin: bestCombo.seedMargin,
                samples: testSamples,
                dpParams: bestDPParams,
                otsuCrop: bestOtsuCrop,
                concurrency: concurrency
            )
        }

        print("  Test combined score: \(String(format: "%.4f", testScore))")

        return OptimizationResult(
            bestMethod: bestCombo.method,
            bestBrushRadius: bestCombo.brush,
            bestSeedMargin: bestCombo.seedMargin,
            bestOtsuParams: OtsuParams(bottomPercentage: bestOtsuCrop),
            bestDPParams: bestDPParams,
            bestRWParams: RWParams(beta: 90.0, brushRadius: bestCombo.brush,
                                   seedMargin: bestCombo.seedMargin),
            trainScore: bestCombo.score,
            testScore: testScore
        )
    }

    // MARK: - Parallel grid searches

    struct OtsuGridResult: Sendable {
        let bestCrop: Double
        let bestScore: Double
    }

    /// Evaluate Otsu at multiple crop percentages. For each crop%, score all samples in parallel.
    private func evaluateOtsuGrid(samples: [TestSample], concurrency: Int) async -> OtsuGridResult {
        let crops = stride(from: 10.0, through: 90.0, by: 10.0).map { $0 }
        var bestCrop = 50.0
        var bestScore = 0.0

        for crop in crops {
            let avgScore = await Self.evaluateSamplesParallel(samples: samples, concurrency: concurrency) {
                image, refMask in
                if let mask = try? await image.horizonMask(at: 0, bottomPercentage: crop) {
                    return MaskScorer.score(computed: mask.image, reference: refMask).combinedScore
                }
                return nil
            }
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

    /// Evaluate DP across a parameter grid. Each param combo scores all samples in parallel.
    private func evaluateDPGrid(samples: [TestSample], concurrency: Int) async -> DPGridResult {
        let lambdas = [1.0, 1.5, 2.0, 3.0]
        let sobels = [0.2, 0.6, 1.0]
        let cannys = [0.2, 0.6, 1.0]

        // Build all param combos, evaluate each in parallel across samples
        struct DPCombo: Sendable {
            let lambda: Double, sobel: Double, canny: Double, score: Double
        }

        let results: [DPCombo] = await withTaskGroup(of: DPCombo.self) { group in
            for lambda in lambdas {
                for sobel in sobels {
                    for canny in cannys {
                        group.addTask { [concurrency] in
                            let avg = await Self.evaluateSamplesParallel(
                                samples: samples, concurrency: concurrency
                            ) { image, refMask in
                                let params = DPParams(
                                    smoothnessLambda: lambda,
                                    sobelWeight: sobel,
                                    cannyWeight: canny
                                )
                                if let mask = try? DPRunner.runSingle(image: image, params: params) {
                                    return MaskScorer.score(computed: mask, reference: refMask).combinedScore
                                }
                                return nil
                            }
                            return DPCombo(lambda: lambda, sobel: sobel, canny: canny, score: avg)
                        }
                    }
                }
            }
            var all: [DPCombo] = []
            for await r in group { all.append(r) }
            return all
        }

        let best = results.max(by: { $0.score < $1.score })
            ?? DPCombo(lambda: 2.0, sobel: 0.6, canny: 0.4, score: 0)

        return DPGridResult(bestLambda: best.lambda, bestSobel: best.sobel,
                            bestCanny: best.canny, bestScore: best.score)
    }

    /// Evaluate SIOX across all samples in parallel.
    private func evaluateSIOX(samples: [TestSample], concurrency: Int) async -> Double {
        await Self.evaluateSamplesParallel(samples: samples, concurrency: concurrency) {
            image, refMask in
            let mask = await SIOXRunner.run(image: image)
            return MaskScorer.score(computed: mask, reference: refMask).combinedScore
        }
    }

    // MARK: - Combination evaluation (static, for use from task groups)

    /// Evaluate a base+RW combo across samples in parallel.
    static func evaluateComboStatic(
        baseMethod: HorizonMethod,
        brushRadius: Int,
        seedMargin: Int = 0,
        samples: [TestSample],
        dpParams: DPParams,
        otsuCrop: Double,
        concurrency: Int
    ) async -> Double {
        await evaluateSamplesParallel(samples: samples, concurrency: concurrency) {
            image, refMask in
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
            guard let base = baseMask else { return nil }
            let baseY = BandSimulator.horizonYFromMask(base)
            let rwParams = RWParams(brushRadius: brushRadius, seedMargin: seedMargin)
            let result = RWRunner.run(image: image, baseHorizonY: baseY, params: rwParams)
            return MaskScorer.score(computed: result, reference: refMask).combinedScore
        }
    }

    /// Evaluate combined (median of all three) + RW across samples in parallel.
    static func evaluateCombinedComboStatic(
        brushRadius: Int,
        seedMargin: Int = 0,
        samples: [TestSample],
        dpParams: DPParams,
        otsuCrop: Double,
        concurrency: Int
    ) async -> Double {
        await evaluateSamplesParallel(samples: samples, concurrency: concurrency) {
            image, refMask in
            let otsuMask = try? await OtsuRunner.run(image: image,
                params: OtsuParams(bottomPercentage: otsuCrop))
            let dpMask = try? DPRunner.runSingle(image: image, params: dpParams)
            let sioxMask = await SIOXRunner.run(image: image)

            var arrays: [[Int?]] = []
            if let m = otsuMask { arrays.append(BandSimulator.horizonYFromMask(m)) }
            if let m = dpMask { arrays.append(BandSimulator.horizonYFromMask(m)) }
            arrays.append(BandSimulator.horizonYFromMask(sioxMask))
            guard !arrays.isEmpty else { return nil }
            let combinedY = BandSimulator.medianCombine(arrays)

            let rwParams = RWParams(brushRadius: brushRadius, seedMargin: seedMargin)
            let result = RWRunner.run(image: image, baseHorizonY: combinedY, params: rwParams)
            return MaskScorer.score(computed: result, reference: refMask).combinedScore
        }
    }

    // MARK: - Core parallel sample evaluator

    /// Run a scoring closure on each sample in parallel (bounded by concurrency),
    /// return the average score. The closure returns nil to skip a sample.
    static func evaluateSamplesParallel(
        samples: [TestSample],
        concurrency: Int,
        scorer: @Sendable @escaping (PixelatedImage, PixelatedImage) async -> Double?
    ) async -> Double {
        let semaphore = AsyncSemaphore(value: concurrency)

        let scores: [Double] = await withTaskGroup(of: Double?.self) { group in
            for sample in samples {
                group.addTask {
                    await semaphore.wait()
                    defer { semaphore.signal() }

                    guard let image = PixelatedImage(filename: sample.imagePath),
                          let refMask = PixelatedImage(filename: sample.maskPath) else {
                        return nil
                    }
                    return await scorer(image, refMask)
                }
            }
            var results: [Double] = []
            for await score in group {
                if let s = score { results.append(s) }
            }
            return results
        }

        return scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)
    }
}
