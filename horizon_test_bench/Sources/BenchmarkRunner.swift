/*
 BenchmarkRunner.swift — Run all methods on test data and collect scores.

 Orchestrates: load image, run method(s), score against reference, tabulate.
*/

import Foundation
import StarCore
import KHTSwift
import kht_bridge

// MARK: - Result types

struct MethodResult: Sendable {
    let method: HorizonMethod
    let sample: TestSample
    let score: MaskScore
    let durationMs: Double
}

struct BenchmarkReport: Sendable {
    let results: [MethodResult]

    /// Average scores per method
    func averageScores() -> [(method: HorizonMethod, avg: MaskScore, count: Int)] {
        var grouped: [HorizonMethod: [MaskScore]] = [:]
        for r in results {
            grouped[r.method, default: []].append(r.score)
        }
        return grouped.map { (method, scores) in
            let avg = MaskScore(
                pixelAccuracy: scores.map(\.pixelAccuracy).reduce(0, +) / Double(scores.count),
                skyIoU: scores.map(\.skyIoU).reduce(0, +) / Double(scores.count),
                meanHorizonError: scores.map(\.meanHorizonError).reduce(0, +) / Double(scores.count),
                columnsWithin5px: scores.map(\.columnsWithin5px).reduce(0, +) / Double(scores.count),
                columnsWithin10px: scores.map(\.columnsWithin10px).reduce(0, +) / Double(scores.count),
                validColumns: scores.map(\.validColumns).reduce(0, +) / scores.count
            )
            return (method, avg, scores.count)
        }.sorted { $0.avg.combinedScore > $1.avg.combinedScore }
    }

    /// Print a formatted report
    func printReport() {
        let avgs = averageScores()
        print("\n" + String(repeating: "=", count: 100))
        print("HORIZON DETECTION BENCHMARK RESULTS")
        print(String(repeating: "=", count: 100))
        print()
        print(String(format: "%-18s %6s %8s %8s %8s %8s %8s %8s",
                     "Method", "N", "Combined", "PxAcc", "IoU", "MeanErr", "±5px", "±10px"))
        print(String(repeating: "-", count: 100))

        for (method, avg, count) in avgs {
            print(String(format: "%-18s %6d %8.4f %8.4f %8.4f %8.1f %8.3f %8.3f",
                         method.rawValue, count,
                         avg.combinedScore, avg.pixelAccuracy, avg.skyIoU,
                         avg.meanHorizonError, avg.columnsWithin5px, avg.columnsWithin10px))
        }
        print(String(repeating: "=", count: 100))

        // Per-sample details for worst performers
        print("\nWorst 10 results (by combined score):")
        let sorted = results.sorted { $0.score.combinedScore < $1.score.combinedScore }
        for r in sorted.prefix(10) {
            print("  \(r.method.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) " +
                  "\(r.sample.description.padding(toLength: 40, withPad: " ", startingAt: 0)) " +
                  r.score.shortDescription)
        }
    }
}

// MARK: - Benchmark runner

actor BenchmarkRunner {
    private var results: [MethodResult] = []
    private let verbose: Bool
    private let saveMasks: String?  // optional directory to save computed masks

    init(verbose: Bool = false, saveMasks: String? = nil) {
        self.verbose = verbose
        self.saveMasks = saveMasks
    }

    func addResult(_ result: MethodResult) {
        results.append(result)
    }

    func getResults() -> [MethodResult] { results }

    /// Run all base methods on a single sample.
    func runBaseMethods(sample: TestSample) async {
        guard let image = PixelatedImage(filename: sample.imagePath) else {
            print("  ERROR: Cannot load image: \(sample.imagePath)")
            return
        }
        guard let refMask = PixelatedImage(filename: sample.maskPath) else {
            print("  ERROR: Cannot load reference mask: \(sample.maskPath)")
            return
        }

        if verbose {
            print("  Processing \(sample.description) (\(image.width)x\(image.height))...")
        }

        // Run Otsu
        await runMethod(.otsu, image: image, refMask: refMask, sample: sample)

        // Run DP (with grid search for best params)
        await runMethod(.dp, image: image, refMask: refMask, sample: sample)

        // Run SIOX
        await runMethod(.siox, image: image, refMask: refMask, sample: sample)
    }

    /// Run combined methods on a single sample.
    func runCombinedMethods(sample: TestSample, brushRadii: [Int] = [20, 40, 60, 80]) async {
        guard let image = PixelatedImage(filename: sample.imagePath) else { return }
        guard let refMask = PixelatedImage(filename: sample.maskPath) else { return }

        if verbose {
            print("  Running combined methods on \(sample.description)...")
        }

        // First run base methods to get their horizon lines
        let otsuMask = try? await OtsuRunner.run(image: image)
        let dpMask = try? await DPRunner.run(image: image, gridSearch: true)
        let sioxMask = await SIOXRunner.run(image: image)

        let otsuY = otsuMask.map { BandSimulator.horizonYFromMask($0) }
        let dpY = dpMask.map { BandSimulator.horizonYFromMask($0) }
        let sioxY = BandSimulator.horizonYFromMask(sioxMask)

        // Test each brush radius and pick the best for each combination
        for combo in HorizonMethod.combinedMethods {
            var bestScore: MaskScore? = nil
            var bestMask: PixelatedImage? = nil

            for brush in brushRadii {
                let params = RWParams(brushRadius: brush)
                var baseY: [Int?]? = nil

                switch combo {
                case .otsuThenRW:
                    baseY = otsuY
                case .dpThenRW:
                    baseY = dpY
                case .sioxThenRW:
                    baseY = sioxY
                case .combinedThenRW:
                    // Median of all three
                    var arrays: [[Int?]] = []
                    if let y = otsuY { arrays.append(y) }
                    if let y = dpY { arrays.append(y) }
                    arrays.append(sioxY)
                    if !arrays.isEmpty {
                        baseY = BandSimulator.medianCombine(arrays)
                    }
                default:
                    continue
                }

                guard let horizonY = baseY else { continue }

                let mask = RWRunner.run(image: image, baseHorizonY: horizonY, params: params)
                let score = MaskScorer.score(computed: mask, reference: refMask)

                if bestScore == nil || score.combinedScore > bestScore!.combinedScore {
                    bestScore = score
                    bestMask = mask
                }
            }

            if let score = bestScore {
                let result = MethodResult(
                    method: combo,
                    sample: sample,
                    score: score,
                    durationMs: 0 // not timing combos individually
                )
                results.append(result)

                if verbose {
                    print("    \(combo.rawValue): \(score.shortDescription)")
                }

                // Save mask if requested
                if let dir = saveMasks, let mask = bestMask {
                    saveMaskToDisk(mask: mask, method: combo, sample: sample, dir: dir)
                }
            }
        }
    }

    /// Run a single base method, score it, and record the result.
    private func runMethod(
        _ method: HorizonMethod,
        image: PixelatedImage,
        refMask: PixelatedImage,
        sample: TestSample
    ) async {
        let start = CFAbsoluteTimeGetCurrent()

        let computedMask: PixelatedImage?
        switch method {
        case .otsu:
            computedMask = try? await OtsuRunner.run(image: image)
        case .dp:
            computedMask = try? await DPRunner.run(image: image, gridSearch: true)
        case .siox:
            computedMask = await SIOXRunner.run(image: image)
        default:
            computedMask = nil
        }

        let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        guard let mask = computedMask else {
            if verbose { print("    \(method.rawValue): FAILED") }
            return
        }

        let score = MaskScorer.score(computed: mask, reference: refMask)
        let result = MethodResult(
            method: method,
            sample: sample,
            score: score,
            durationMs: durationMs
        )
        results.append(result)

        if verbose {
            print("    \(method.rawValue): \(score.shortDescription) (\(Int(durationMs))ms)")
        }

        // Save mask if requested
        if let dir = saveMasks {
            saveMaskToDisk(mask: mask, method: method, sample: sample, dir: dir)
        }
    }

    private nonisolated func saveMaskToDisk(
        mask: PixelatedImage,
        method: HorizonMethod,
        sample: TestSample,
        dir: String
    ) {
        let fm = FileManager.default
        let methodDir = (dir as NSString).appendingPathComponent(method.rawValue)
        try? fm.createDirectory(atPath: methodDir, withIntermediateDirectories: true)

        let baseName = (sample.imagePath as NSString).lastPathComponent
        let seqSafe = sample.sequenceName.replacingOccurrences(of: "/", with: "_")
        let outName = "\(seqSafe)_\(baseName)"
        let outPath = (methodDir as NSString).appendingPathComponent(outName)
        mask.mat.write(to: outPath)
    }
}
