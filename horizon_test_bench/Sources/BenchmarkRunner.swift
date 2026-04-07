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
        brushRadii: [Int] = [40]
    ) async -> SampleResults {
        let startTime = CFAbsoluteTimeGetCurrent()
        FileHandle.standardError.write("  START [\(index+1)/\(total)] \(sample.description)\n".data(using: .utf8)!)
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            FileHandle.standardError.write("  DONE  [\(index+1)/\(total)] \(sample.description) (\(String(format: "%.1f", elapsed))s)\n".data(using: .utf8)!)
        }
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

        // Compute all base masks ONCE and share them
        let t0 = CFAbsoluteTimeGetCurrent()
        let baseMasks = await computeAllBaseMasks(image: image)
        let baseTime = CFAbsoluteTimeGetCurrent() - t0
        FileHandle.standardError.write("    base masks [\(index+1)] in \(String(format: "%.1f", baseTime))s\n".data(using: .utf8)!)

        // Score base methods
        for method in HorizonMethod.baseMethods {
            guard let mask = baseMasks[method] else { continue }
            let score = MaskScorer.score(computed: mask, reference: refMask)
            methodResults.append(MethodResult(
                method: method,
                sampleIndex: index,
                sampleDescription: sample.description,
                score: score,
                durationMs: 0
            ))
            if let dir = saveMasks {
                saveMaskToDisk(mask: mask, method: method, sample: sample, dir: dir)
            }
        }

        // Run combined methods if requested, reusing base masks
        if includeCombined {
            let comboResults = await runCombinedMethods(
                image: image, refMask: refMask, sample: sample,
                index: index, brushRadii: brushRadii, saveMasks: saveMasks,
                baseMasks: baseMasks
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

    /// Compute all 7 base method masks once.
    private static func computeAllBaseMasks(image: PixelatedImage) async -> [HorizonMethod: PixelatedImage] {
        var masks: [HorizonMethod: PixelatedImage] = [:]
        if let m = try? await OtsuRunner.run(image: image) { masks[.otsu] = m }
        if let m = try? await DPRunner.run(image: image, gridSearch: true) { masks[.dp] = m }
        masks[.siox] = await SIOXRunner.run(image: image)
        masks[.gradProfile] = GradProfileRunner.run(image: image)
        masks[.texture] = TextureRunner.run(image: image)
        masks[.grabCut] = GrabCutRunner.run(image: image)
        masks[.fft] = FFTRunner.run(image: image)
        return masks
    }

    // MARK: - Combined methods

    private static func runCombinedMethods(
        image: PixelatedImage,
        refMask: PixelatedImage,
        sample: TestSample,
        index: Int,
        brushRadii: [Int],
        saveMasks: String?,
        baseMasks: [HorizonMethod: PixelatedImage]
    ) async -> [MethodResult] {
        // Use pre-computed base masks
        let otsuMask = baseMasks[.otsu]
        let dpMask = baseMasks[.dp]
        let sioxMask = baseMasks[.siox]
        let gradMask = baseMasks[.gradProfile]
        let texMask = baseMasks[.texture]
        let gcMask = baseMasks[.grabCut]
        let fftMask = baseMasks[.fft]

        let otsuY = otsuMask.map { BandSimulator.horizonYFromMask($0) }
        let dpY = dpMask.map { BandSimulator.horizonYFromMask($0) }
        let sioxY = sioxMask.map { BandSimulator.horizonYFromMask($0) }
        let gradY = gradMask.map { BandSimulator.horizonYFromMask($0) }
        let texY = texMask.map { BandSimulator.horizonYFromMask($0) }
        let gcY = gcMask.map { BandSimulator.horizonYFromMask($0) }
        let fftY = fftMask.map { BandSimulator.horizonYFromMask($0) }

        var results: [MethodResult] = []
        // Cache best masks from individual method+rw runs for selectBestRW
        var cachedBestMasks: [HorizonMethod: PixelatedImage] = [:]

        for combo in HorizonMethod.combinedMethods {
            var bestScore: MaskScore? = nil
            var bestMask: PixelatedImage? = nil

            for brush in brushRadii {
                let params = RWParams(maxWorkingWidth: 512, brushRadius: brush)
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
                case .textureThenRW:
                    baseY = texY
                case .grabCutThenRW:
                    baseY = gcY
                case .fftThenRW:
                    baseY = fftY
                case .combinedThenRW:
                    let imgH = image.height
                    var weightedMethods: [([Int?], Double)] = []
                    // 5 production methods: otsu, dp, siox, grad, tex
                    let prodMethods: [(y: [Int?]?, name: String)] = [
                        (otsuY, "otsu"), (dpY, "dp"), (sioxY, "siox"),
                        (gradY, "grad"), (texY, "tex")
                    ]
                    for (yOpt, _) in prodMethods {
                        if let y = yOpt {
                            let conf = BandSimulator.horizonConfidence(y, imageHeight: imgH)
                            if conf > 0.05 { weightedMethods.append((y, conf)) }
                        }
                    }
                    // Note: gc and fft are excluded from the combine — benchmarking
                    // showed they hurt the confidence-weighted average.
                    // Fallback: if all excluded, use equal weights
                    if weightedMethods.isEmpty {
                        for (yOpt, _) in prodMethods {
                            if let y = yOpt { weightedMethods.append((y, 1.0)) }
                        }
                    }
                    baseY = weightedMethods.isEmpty ? nil :
                        BandSimulator.confidenceWeightedCombine(weightedMethods)
                case .bestOfRW, .oracleRW, .selectBestRW, .selectEdgeRW, .select7RW:
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

            // Cache the best mask for single method+rw runs
            let singleMethodRWs: Set<HorizonMethod> = [
                .otsuThenRW, .dpThenRW, .sioxThenRW, .gradThenRW,
                .textureThenRW, .grabCutThenRW, .fftThenRW
            ]
            if singleMethodRWs.contains(combo), let mask = bestMask {
                cachedBestMasks[combo] = mask
            }

            // For select* methods: self-score each method+rw mask (no reference),
            // pick the one with the highest self-score, then report its reference score.
            if combo == .selectBestRW || combo == .selectEdgeRW || combo == .select7RW {
                let imgH = image.height
                let candidates: [HorizonMethod]
                if combo == .select7RW {
                    // All 7 methods
                    candidates = [
                        .otsuThenRW, .dpThenRW, .sioxThenRW, .gradThenRW,
                        .textureThenRW, .grabCutThenRW, .fftThenRW
                    ]
                } else {
                    // 5 production methods only
                    candidates = [
                        .otsuThenRW, .dpThenRW, .sioxThenRW, .gradThenRW, .textureThenRW
                    ]
                }
                var bestSelfScore: Double = -1.0
                var selectedMethod: HorizonMethod? = nil
                for method in candidates {
                    guard let mask = cachedBestMasks[method] else { continue }
                    let selfScore: Double
                    if combo == .selectBestRW {
                        // Basic self-score (smoothness × coverage × plausibility)
                        selfScore = BandSimulator.selfScoreMask(mask, imageHeight: imgH)
                    } else {
                        // Edge-aware self-score (also checks image gradients)
                        selfScore = BandSimulator.selfScoreWithImage(mask, image: image)
                    }
                    if selfScore > bestSelfScore {
                        bestSelfScore = selfScore
                        selectedMethod = method
                    }
                }
                // Look up the reference score for the selected method
                if let sel = selectedMethod,
                   let selResult = results.first(where: { $0.method == sel }) {
                    bestScore = selResult.score
                    bestMask = cachedBestMasks[sel]
                }
            }

            // For bestOfRW: pick the best result from all single+rw methods
            if combo == .bestOfRW {
                let candidates = results.filter {
                    [.otsuThenRW, .dpThenRW, .sioxThenRW, .gradThenRW, .textureThenRW, .grabCutThenRW, .fftThenRW].contains($0.method)
                }
                if let best = candidates.max(by: { $0.score.combinedScore < $1.score.combinedScore }) {
                    bestScore = best.score
                }
            }

            // For oracleRW: pick best of combined+rw and all single+rw methods
            if combo == .oracleRW {
                let candidates = results.filter {
                    [.otsuThenRW, .dpThenRW, .sioxThenRW, .gradThenRW, .textureThenRW, .grabCutThenRW, .fftThenRW, .combinedThenRW].contains($0.method)
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
