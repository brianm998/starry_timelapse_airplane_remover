/*
 BenchmarkRunner.swift — Run all methods on test data and collect scores.

 Orchestrates: load image, run method(s), score against reference, tabulate.
 Runs samples in parallel with bounded concurrency, logs in original order.
*/

import Foundation
import StarCore
import KHTSwift
import kht_bridge
import Semaphore

// MARK: - Result types

struct MethodResult: Sendable {
    let method: HorizonMethod
    let sampleIndex: Int
    let sampleDescription: String
    let score: MaskScore
    let durationMs: Double
}

/// All results for a single sample (one image tested against all methods).
struct SampleResults: Sendable {
    let sampleIndex: Int
    let sampleDescription: String
    let imageSize: String  // "WxH"
    let methodResults: [MethodResult]
    let error: String?  // non-nil if image/mask failed to load
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
                validColumns: scores.map(\.validColumns).reduce(0, +) / scores.count,
                signedMeanError: scores.map(\.signedMeanError).reduce(0, +) / Double(scores.count)
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

        // Header
        let header = "Method".padding(toLength: 18, withPad: " ", startingAt: 0) +
            "N".padding(toLength: 8, withPad: " ", startingAt: 0) +
            "Combined".padding(toLength: 10, withPad: " ", startingAt: 0) +
            "PxAcc".padding(toLength: 10, withPad: " ", startingAt: 0) +
            "IoU".padding(toLength: 10, withPad: " ", startingAt: 0) +
            "MeanErr".padding(toLength: 10, withPad: " ", startingAt: 0) +
            "±5px".padding(toLength: 10, withPad: " ", startingAt: 0) +
            "±10px"
        print(header)
        print(String(repeating: "-", count: 100))

        for (method, avg, count) in avgs {
            let line = method.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0) +
                "\(count)".padding(toLength: 8, withPad: " ", startingAt: 0) +
                String(format: "%.4f", avg.combinedScore).padding(toLength: 10, withPad: " ", startingAt: 0) +
                String(format: "%.4f", avg.pixelAccuracy).padding(toLength: 10, withPad: " ", startingAt: 0) +
                String(format: "%.4f", avg.skyIoU).padding(toLength: 10, withPad: " ", startingAt: 0) +
                String(format: "%.1f", avg.meanHorizonError).padding(toLength: 10, withPad: " ", startingAt: 0) +
                String(format: "%.3f", avg.columnsWithin5px).padding(toLength: 10, withPad: " ", startingAt: 0) +
                String(format: "%.3f", avg.columnsWithin10px)
            print(line)
        }
        print(String(repeating: "=", count: 100))

        // Per-sample details for worst performers
        print("\nWorst 10 results (by combined score):")
        let sorted = results.sorted { $0.score.combinedScore < $1.score.combinedScore }
        for r in sorted.prefix(10) {
            let line = "  " +
                r.method.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0) + " " +
                r.sampleDescription.padding(toLength: 40, withPad: " ", startingAt: 0) + " " +
                r.score.shortDescription
            print(line)
        }
    }
}

// MARK: - Benchmark runner

/// Process a single sample: load image + mask, run all requested methods, return results.
/// This is a pure function (no shared state) so it's safe to call from any task.
enum SampleProcessor {

    static func process(
        sample: TestSample,
        index: Int,
        total: Int,
        includeCombined: Bool,
        saveMasks: String?,
        brushRadii: [Int] = [40, 80, 160]
    ) async -> SampleResults {
        guard let image = PixelatedImage(filename: sample.imagePath) else {
            return SampleResults(
                sampleIndex: index,
                sampleDescription: sample.description,
                imageSize: "?",
                methodResults: [],
                error: "Cannot load image: \(sample.imagePath)"
            )
        }
        guard let refMask = PixelatedImage(filename: sample.maskPath) else {
            return SampleResults(
                sampleIndex: index,
                sampleDescription: sample.description,
                imageSize: "\(image.width)x\(image.height)",
                methodResults: [],
                error: "Cannot load mask: \(sample.maskPath)"
            )
        }

        let imageSize = "\(image.width)x\(image.height)"
        var methodResults: [MethodResult] = []

        // Run base methods
        for method in HorizonMethod.baseMethods {
            let result = await runMethod(
                method, image: image, refMask: refMask,
                sample: sample, index: index
            )
            if let r = result {
                methodResults.append(r)

                // Save mask if requested
                if let dir = saveMasks {
                    let mask = computeMask(method: method, image: image)
                    if let m = mask {
                        saveMaskToDisk(mask: m, method: method, sample: sample, dir: dir)
                    }
                }
            }
        }

        // Run combined methods if requested
        if includeCombined {
            let comboResults = await runCombinedMethods(
                image: image, refMask: refMask, sample: sample,
                index: index, brushRadii: brushRadii, saveMasks: saveMasks
            )
            methodResults.append(contentsOf: comboResults)
        }

        return SampleResults(
            sampleIndex: index,
            sampleDescription: sample.description,
            imageSize: imageSize,
            methodResults: methodResults,
            error: nil
        )
    }

    // MARK: - Base method execution

    private static func runMethod(
        _ method: HorizonMethod,
        image: PixelatedImage,
        refMask: PixelatedImage,
        sample: TestSample,
        index: Int
    ) async -> MethodResult? {
        let start = CFAbsoluteTimeGetCurrent()

        let computedMask: PixelatedImage?
        switch method {
        case .otsu:
            computedMask = try? await OtsuRunner.run(image: image)
        case .dp:
            computedMask = try? await DPRunner.run(image: image, gridSearch: true)
        case .siox:
            computedMask = await SIOXRunner.run(image: image)
        case .gradProfile:
            computedMask = GradProfileRunner.run(image: image)
        default:
            computedMask = nil
        }

        let durationMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        guard let mask = computedMask else { return nil }

        let score = MaskScorer.score(computed: mask, reference: refMask)
        return MethodResult(
            method: method,
            sampleIndex: index,
            sampleDescription: sample.description,
            score: score,
            durationMs: durationMs
        )
    }

    private static func computeMask(method: HorizonMethod, image: PixelatedImage) -> PixelatedImage? {
        switch method {
        case .otsu:
            return try? syncRunOtsu(image: image)
        case .dp:
            return try? DPRunner.runSingle(image: image, params: DPParams())
        default:
            return nil
        }
    }

    // Synchronous otsu for save-only path (already computed above, but simpler than caching)
    private static func syncRunOtsu(image: PixelatedImage) throws -> PixelatedImage {
        // Just use default params for saving
        let (scaled, _, _) = ImageScaler.scaleForProcessing(image, maxDim: 512)
        if let mask = scaled.binaryOtsuImage {
            if let up = mask.mat.upScale(to: UInt(image.width), height: UInt(image.height)),
               let pi = PixelatedImage(mat: up) {
                return OtsuRunner.thresholdToBinary(pi)
            }
            return mask
        }
        throw "Otsu failed"
    }

    // MARK: - Combined methods

    private static func runCombinedMethods(
        image: PixelatedImage,
        refMask: PixelatedImage,
        sample: TestSample,
        index: Int,
        brushRadii: [Int],
        saveMasks: String?
    ) async -> [MethodResult] {
        // Get base horizons
        let otsuMask = try? await OtsuRunner.run(image: image)
        let dpMask = try? await DPRunner.run(image: image, gridSearch: true)
        let sioxMask = await SIOXRunner.run(image: image)
        let gradMask = GradProfileRunner.run(image: image)

        let otsuY = otsuMask.map { BandSimulator.horizonYFromMask($0) }
        let dpY = dpMask.map { BandSimulator.horizonYFromMask($0) }
        let sioxY = BandSimulator.horizonYFromMask(sioxMask)
        let gradY = BandSimulator.horizonYFromMask(gradMask)

        var results: [MethodResult] = []

        for combo in HorizonMethod.combinedMethods {
            var bestScore: MaskScore? = nil
            var bestMask: PixelatedImage? = nil

            for brush in brushRadii {
                let params = RWParams(brushRadius: brush)
                let baseY: [Int?]?

                switch combo {
                case .otsuThenRW:
                    baseY = otsuY
                case .dpThenRW:
                    baseY = dpY
                case .sioxThenRW:
                    baseY = sioxY
                case .gradThenRW:
                    baseY = gradY
                case .combinedThenRW:
                    let imgH = image.height
                    var weightedMethods: [([Int?], Double)] = []
                    if let y = otsuY {
                        let conf = BandSimulator.horizonConfidence(y, imageHeight: imgH)
                        if conf > 0.05 { weightedMethods.append((y, conf)) }
                    }
                    if let y = dpY {
                        let conf = BandSimulator.horizonConfidence(y, imageHeight: imgH)
                        if conf > 0.05 { weightedMethods.append((y, conf)) }
                    }
                    do {
                        let conf = BandSimulator.horizonConfidence(sioxY, imageHeight: imgH)
                        if conf > 0.05 { weightedMethods.append((sioxY, conf)) }
                    }
                    do {
                        let conf = BandSimulator.horizonConfidence(gradY, imageHeight: imgH)
                        if conf > 0.05 { weightedMethods.append((gradY, conf)) }
                    }
                    // Fallback: if all excluded, use equal weights
                    if weightedMethods.isEmpty {
                        if let y = otsuY { weightedMethods.append((y, 1.0)) }
                        if let y = dpY { weightedMethods.append((y, 1.0)) }
                        weightedMethods.append((sioxY, 1.0))
                        weightedMethods.append((gradY, 1.0))
                    }
                    baseY = weightedMethods.isEmpty ? nil :
                        BandSimulator.confidenceWeightedCombine(weightedMethods)
                case .bestOfRW, .oracleRW:
                    baseY = nil  // handled separately below
                default:
                    baseY = nil
                }

                guard let horizonY = baseY else { continue }

                let mask = RWRunner.run(image: image, baseHorizonY: horizonY, params: params)
                let score = MaskScorer.score(computed: mask, reference: refMask)

                if bestScore == nil || score.combinedScore > bestScore!.combinedScore {
                    bestScore = score
                    bestMask = mask
                }
            }

            // For bestOfRW: pick the best result from otsu+rw, dp+rw, siox+rw, grad+rw
            if combo == .bestOfRW {
                let candidates = results.filter {
                    [.otsuThenRW, .dpThenRW, .sioxThenRW, .gradThenRW].contains($0.method)
                }
                if let best = candidates.max(by: { $0.score.combinedScore < $1.score.combinedScore }) {
                    bestScore = best.score
                }
            }

            // For oracleRW: pick best of combined+rw, otsu+rw, dp+rw, siox+rw, grad+rw
            if combo == .oracleRW {
                let candidates = results.filter {
                    [.otsuThenRW, .dpThenRW, .sioxThenRW, .gradThenRW, .combinedThenRW].contains($0.method)
                }
                if let best = candidates.max(by: { $0.score.combinedScore < $1.score.combinedScore }) {
                    bestScore = best.score
                }
            }

            if let score = bestScore {
                results.append(MethodResult(
                    method: combo,
                    sampleIndex: index,
                    sampleDescription: sample.description,
                    score: score,
                    durationMs: 0
                ))

                if let dir = saveMasks, let mask = bestMask {
                    saveMaskToDisk(mask: mask, method: combo, sample: sample, dir: dir)
                }
            }
        }

        return results
    }

    // MARK: - Disk I/O

    private static func saveMaskToDisk(
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

// MARK: - Parallel benchmark orchestrator

/// Runs all samples in parallel with bounded concurrency, prints results in order.
enum ParallelBenchmark {

    /// Default concurrency: physical CPU count (activeProcessorCount).
    static var defaultConcurrency: Int {
        ProcessInfo.processInfo.activeProcessorCount
    }

    static func run(
        samples: [TestSample],
        maxConcurrency: Int,
        verbose: Bool,
        includeCombined: Bool,
        saveMasks: String?
    ) async -> [MethodResult] {
        let total = samples.count
        let semaphore = AsyncSemaphore(value: maxConcurrency)

        print("Running \(total) samples with max \(maxConcurrency) concurrent tasks...\n")

        // We'll collect SampleResults keyed by index, then print in order.
        // Use an actor to collect results and print them in sequence.
        let printer = OrderedPrinter(total: total, verbose: verbose)

        await withTaskGroup(of: SampleResults.self) { group in
            for (i, sample) in samples.enumerated() {
                group.addTask {
                    await semaphore.wait()
                    defer { semaphore.signal() }

                    return await SampleProcessor.process(
                        sample: sample,
                        index: i,
                        total: total,
                        includeCombined: includeCombined,
                        saveMasks: saveMasks
                    )
                }
            }

            for await result in group {
                await printer.received(result)
            }
        }

        return await printer.allResults()
    }
}

// MARK: - Ordered printer

/// Collects results from parallel tasks and prints them in original sample order.
/// As results arrive (possibly out of order), it buffers them and flushes
/// any contiguous block starting from the next expected index.
actor OrderedPrinter {
    private let total: Int
    private let verbose: Bool
    private var nextToPrint: Int = 0
    private var buffer: [Int: SampleResults] = [:]
    private var collectedResults: [MethodResult] = []

    init(total: Int, verbose: Bool) {
        self.total = total
        self.verbose = verbose
    }

    func received(_ result: SampleResults) {
        // Store results
        collectedResults.append(contentsOf: result.methodResults)
        buffer[result.sampleIndex] = result

        // Flush contiguous block
        while let sr = buffer[nextToPrint] {
            printSampleResult(sr)
            buffer.removeValue(forKey: nextToPrint)
            nextToPrint += 1
        }
    }

    func allResults() -> [MethodResult] { collectedResults }

    private func printSampleResult(_ sr: SampleResults) {
        let prefix = "[\(sr.sampleIndex + 1)/\(total)]"

        if let error = sr.error {
            print("\(prefix) \(sr.sampleDescription)")
            print("  ERROR: \(error)")
            return
        }

        if verbose {
            print("\(prefix) \(sr.sampleDescription) (\(sr.imageSize))")
            for mr in sr.methodResults {
                print("    \(mr.method.rawValue): \(mr.score.shortDescription) (\(Int(mr.durationMs))ms)")
            }
        } else {
            // Compact one-line summary
            let scores = sr.methodResults.map { mr in
                "\(mr.method.rawValue)=\(String(format: "%.3f", mr.score.combinedScore))"
            }.joined(separator: " ")
            print("\(prefix) \(sr.sampleDescription) (\(sr.imageSize)) \(scores)")
        }
    }
}
