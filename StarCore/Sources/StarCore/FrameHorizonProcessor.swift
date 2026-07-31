import Foundation
import StarCppBridge
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// FrameHorizonProcessor manages all horizon-detection and horizon-mask logic
// for a single frame.  It is a sub-actor of FrameAirplaneRemover (the parent
// coordinator) and holds a weak back-reference to it so it can forward state
// updates and read cross-domain values without creating a retain cycle.
//
// Horizon.swift contains standalone data structures (HorizonMask, HorizonBounds,
// HorizonStats) and extensions on PixelatedImage; those stay in Horizon.swift
// and are not moved here.

final public actor FrameHorizonProcessor {

    nonisolated public let frameIndex: Int
    nonisolated public let imageAccessor: ImageAccessor
    let configManager: ConfigManager
    private weak var imageSequence: ImageSequence?
    weak var frame: FrameAirplaneRemover?

    // Set by FrameGraphBuilder for static sequences; nil for moving sequences.
    var horizonAccumulator: HorizonAccumulator?

    // Cached result of loadOrCreateFinalHorizonMask().  The horizon mask is
    // computed once per frame and never changes during a processing run.
    // Cleared by recomputeMergedHorizon* whenever the mask is intentionally
    // regenerated (e.g. after a reference-horizon edit in the GUI).
    private var cachedFinalHorizonMask: HorizonMask?

    init(
        frameIndex: Int,
        imageAccessor: ImageAccessor,
        configManager: ConfigManager,
        imageSequence: ImageSequence?
    ) {
        self.frameIndex = frameIndex
        self.imageAccessor = imageAccessor
        self.configManager = configManager
        self.imageSequence = imageSequence
    }

    func setFrame(_ frame: FrameAirplaneRemover) {
        self.frame = frame
    }

    // Duplicated from FrameAirplaneRemover so horizon methods can call it
    // without hopping back to the parent actor.
    private var outputSizes: [ImageDisplaySize] {
        get async {
            var sizes: [ImageDisplaySize] = [.original]
            let config = await configManager.config()
            if config.writeFramePreviewFiles {
                sizes.append(.preview)
            }
            return sizes
        }
    }

    func setHorizonAccumulator(_ acc: HorizonAccumulator) {
        horizonAccumulator = acc
    }

    /// Called by HorizonDetectionOp after a first-round horizon mask is ready.
    /// No-op if no accumulator has been registered (moving sequences, or reference-horizon sequences).
    func accumulateDetectedHorizon(_ mask: HorizonMask) async {
        guard let horizonAccumulator else { return }
        await horizonAccumulator.accumulate(image: mask.image, frameIndex: frameIndex)
    }
    /// If the merged horizon has already been computed for this frame, deletes the
    /// cached image and recomputes it using the current staticNeighborFrames count.
    /// Call this after changing the per-frame staticNeighborFrames override so that
    /// already-processed frames get an updated merged horizon without a full reprocess.
    public func recomputeMergedHorizonIfExists() async throws {
        guard imageAccessor.imageExists(
          frameIndex: frameIndex,
          ofType: .mergedHorizon,
          atSize: .original
        ) else { return }
        cachedFinalHorizonMask = nil
        imageAccessor.deleteImages(
          frameIndex: frameIndex,
          ofTypes: [.mergedHorizon],
          atSizes: [.original, .preview]
        )
        _ = try await loadOrCreateFinalHorizonMask()
    }

    /// Unconditional variant of `recomputeMergedHorizonIfExists`: always creates
    /// a fresh merged horizon, saving it with overwrite:true.
    /// Does NOT delete the old file first — if creation fails, the old
    /// `.mergedHorizon` is preserved so the overlay stays blue instead of
    /// regressing to the raw `.horizon` (white) line.
    public func recomputeMergedHorizon() async throws {
        // Reference frames serve their painted mask directly; nothing to recompute.
        if (try await loadHorizonReferenceMask()) != nil { return }
        cachedFinalHorizonMask = nil
        // Bypass loadOrCreateMergedHorizonMask's "load if exists" check and go
        // straight to creation.  createMergedHorizonMask saves with overwrite:true.
        cachedFinalHorizonMask = try await createMergedHorizonMask()
    }
    /// Drop the cached final horizon mask.
    ///
    /// `loadOrCreateFinalHorizonMask()` rebuilds it from the merged (or raw) horizon on
    /// disk, so nothing is lost. At 42MP the mask is a full-frame 8-bit plane, ~40MB,
    /// held for the life of the frame and invisible to the MemoryMonitor.
    internal func releaseCachedFinalHorizonMask() {
        cachedFinalHorizonMask = nil
    }

    internal func loadOrCreateFinalHorizonMask() async throws -> HorizonMask? {
        if let cached = cachedFinalHorizonMask { return cached }
        let mask: HorizonMask?
        if let merged = try await loadOrCreateMergedHorizonMask() {
            mask = merged
        } else {
            // fall back to non-merged horizon mask
            mask = try await loadOrCreateHorizonMask()
        }
        cachedFinalHorizonMask = mask
        return mask
    }
    
    // this horizon mask has been calculated by a median merge of
    // possibly aligned horizon masks from neighbor frames.
    public func loadOrCreateMergedHorizonMask() async throws -> HorizonMask? {
        // If the user has painted a reference horizon, use it directly.
        if let referenceMask = try await loadHorizonReferenceMask() {
            Log.i("frame \(frameIndex) loadOrCreateMergedHorizonMask: using reference mask (skipping merge)")
            return referenceMask
        }
        Log.d("frame \(frameIndex) trying to load merged horizon mask")
        // load if possible
        do {
            if let horizonMaskImage = try await imageAccessor.load(
                 frameIndex: frameIndex,
                 type: .mergedHorizon,
                 atSize: .original
               )
            {
                Log.d("frame \(frameIndex) successfully loaded merged horizon mask")

                if let bounds = horizonMaskImage.horizonBounds() {
                    return HorizonMask(
                      image: horizonMaskImage,
                      horizonTopY: bounds.topY,
                      horizonBottomY: bounds.bottomY
                    )
                }
                Log.w("frame \(frameIndex) loaded merged horizon mask image but could not compute bounds")
            }
        } catch {
            Log.w("frame \(frameIndex) unable to load merged horizon mask")
        }

        Log.i("frame \(frameIndex) making merged horizon")

        return try await createMergedHorizonMask()
    }

    public func createMergedHorizonMask() async throws -> HorizonMask? {

        await frame?.set(state: .mergingHorizon)

        // get original horizon mask for this frame
        Log.d("frame \(frameIndex) calling loadOrCreateHorizonMask()")
        let mask = try await loadOrCreateHorizonMask()

        let config = await configManager.config()

        // Reference-horizon smoothing pass (moving sequences only).
        // When enabled and user-defined reference horizons exist within
        // referenceHorizonSmoothingMaxDistance frames, use them (interpolated
        // per-column when bracketing) to filter statistically implausible
        // column values and save as merged horizon.
        if config.useReferenceHorizonSmoothing, config.tripodHeadWasMoving {
            let allStats = try await referenceHorizonsWithStats(
              maxCount: 2,
              numBuckets: config.referenceHorizonBrightnessRefinementHistogramBuckets,
              neighborhoodSize: config.referenceHorizonNeighborhoodSize
            )
            let maxDist = config.referenceHorizonSmoothingMaxDistance
            let nearbyStats = allStats.filter { abs($0.frameIndex - frameIndex) <= maxDist }
            if !nearbyStats.isEmpty,
               let expectedY = interpolatedExpectedYPerColumn(
                 from: nearbyStats, width: mask.image.width
               ),
               let filtered = referenceSmoothedHorizonMask(
                 detected: mask, expectedYPerColumn: expectedY
               )
            {
                Log.i("frame \(frameIndex) createMergedHorizonMask: applying reference-horizon smoothing")
                let finalMask = try await referenceStatsBrightnessRefinementIfNeeded(
                  mask: filtered,
                  config: config
                )
                // Remove any black ground islands not connected to the bottom edge
                // (e.g. dark flag poles or terrain features above the horizon line).
                let cleanedImage = (try? finalMask.image.groundOnly()) ?? finalMask.image
                try await imageAccessor.save(
                  cleanedImage,
                  frameIndex: frameIndex,
                  as: .mergedHorizon,
                  atSizes: await outputSizes,
                  overwrite: true
                )
                return HorizonMask(cleanedImage) ?? finalMask
            }
            Log.w("frame \(frameIndex) reference smoothing skipped, falling through to normal merge")
        }

        var neighborIndices: [Int] = []

        if config.tripodHeadWasMoving {
            neighborIndices = await frame?.getHorizonMergeIndices() ?? []
        } else {
            // static video uses all frames
            if let imageSequence {
                neighborIndices = Array(0..<imageSequence.filenames.count)
            } else {
                Log.w("cannot get static neighbor indices without an image sequence")
            }
        }
        
        // get the names of neighboring horizon masks
        let neighboringHorizons = neighborIndices.compactMap {
            self.imageAccessor.nameForImage(frameIndex: $0,
                                            ofType: .horizon,
                                            atSize: .original)
        }

        Log.i("frame \(frameIndex) making merged horizon \(neighboringHorizons.count) neighboringHorizons")
        
        let mergedHorizonImage: PixelatedImage?
        if config.tripodHeadWasMoving {
            mergedHorizonImage = mask.image.medianMerge(
                with: neighboringHorizons,
                outlierThreshold: await configManager.config().pixelThreshold,
                includeAll: true,
                config: config)
        } else if let accumulator = horizonAccumulator {
            // Use the running accumulator that was populated by HorizonDetectionOps.
            // Any frames not yet accumulated will be loaded from disk here.
            let imageAccessor = self.imageAccessor
            mergedHorizonImage = await accumulator.finalize { idx in
                imageAccessor.nameForImage(frameIndex: idx, ofType: .horizon, atSize: .original)
            }
        } else {
            mergedHorizonImage = PixelatedImage.accumulatedHorizonMask(fromFilenames: neighboringHorizons)
        }
        if let mergedHorizon = mergedHorizonImage {
            // Apply stats-based brightness refinement for moving sequences.
            let imageToSave: PixelatedImage
            if config.tripodHeadWasMoving,
               let mergedMask = HorizonMask(mergedHorizon),
               let refined = try? await referenceStatsBrightnessRefinementIfNeeded(
                 mask: mergedMask,
                 config: config
               )
            {
                imageToSave = refined.image
            } else {
                imageToSave = mergedHorizon
            }

            // Remove any black ground islands not connected to the bottom edge
            // (e.g. dark flag poles or terrain features above the horizon line).
            let cleanedToSave = (try? imageToSave.groundOnly()) ?? imageToSave

            Log.d("saving merged horizon images")
            try await imageAccessor.save(
              cleanedToSave,
              frameIndex: frameIndex,
              as: .mergedHorizon,
              atSizes: await outputSizes,
              overwrite: true
            )
            if !config.tripodHeadWasMoving {
                // for static videos link all the merged horizons together here
                for size in await outputSizes {
                    if let fromName = imageAccessor.nameForImage(
                         frameIndex: frameIndex,
                         ofType: .mergedHorizon,
                         atSize: size
                       )
                    {
                        for neighborIndex in neighborIndices {
                            if neighborIndex != frameIndex {
                                if let toName = imageAccessor.nameForImage(
                                     frameIndex: neighborIndex,
                                     ofType: .mergedHorizon,
                                     atSize: size
                                   )
                                {
                                    do {
                                        try createHardLinkReplacingDestination(
                                          from: fromName,
                                          to: toName
                                        )
                                    } catch {
                                        Log.w("cannot hard link \(fromName) to \(toName), trying copy")
                                        try copyReplacingDestination(
                                          from: fromName,
                                          to: toName
                                        )
                                    }
                                } else {
                                    Log.w("unable to get name for merged horizon for frameIndex \(neighborIndex)")
                                }
                            }
                        }
                    } else {
                        Log.w("unable to get name for merged horizon for frameIndex \(frameIndex)")
                    }
                }

                // Also persist the median as the global reference horizon for the
                // whole sequence so loadHorizonReferenceMask() picks it up on
                // subsequent loads and re-runs can skip horizon detection entirely.
                if let mergedPath = imageAccessor.nameForImage(
                     frameIndex: frameIndex,
                     ofType: .mergedHorizon,
                     atSize: .original
                   )
                {
                    let referenceDir = URL(fileURLWithPath: mergedPath)
                        .deletingLastPathComponent()
                        .deletingLastPathComponent()
                        .appendingPathComponent("horizonReference")
                    do {
                        try FileManager.default.createDirectory(
                          at: referenceDir,
                          withIntermediateDirectories: true
                        )
                        let referencePath = referenceDir
                            .appendingPathComponent("reference.tiff").path
                        cleanedToSave.writeTIFFEncoding(toFilename: referencePath)
                        Log.i("frame \(frameIndex) saved median horizon as global reference \(referencePath)")
                    } catch {
                        Log.w("frame \(frameIndex) could not save global reference horizon: \(error)")
                    }
                }
            }
            
            if let bounds = cleanedToSave.horizonBounds() {
                return HorizonMask(
                  image: cleanedToSave,
                  horizonTopY: bounds.topY,
                  horizonBottomY: bounds.bottomY
                )
            }
            Log.w("frame \(frameIndex) merged horizon has no computable bounds")
        }

        Log.w("frame \(frameIndex) unable to calculate merged horizon")
        
        return nil
    }

    // MARK: - Reference horizon smoothing helpers

    /// Returns the (frameIndex, mask) of the nearest user-defined reference horizon
    /// within `maxDistance` frames of the current frame, or nil if none exists.
    /// Filter a detected horizon mask using a per-column expected Y (from interpolated
    /// bracketing reference horizons) to reject per-column Y values that are statistical
    /// outliers.
    ///
    /// For each column the delta between detected and expected horizon Y is computed.
    /// Columns whose delta deviates more than 2 standard deviations from the mean
    /// delta are replaced by the expected Y value.  This removes obviously wrong
    /// detections without clamping the entire mask to the expected curve.
    private func referenceSmoothedHorizonMask(
      detected: HorizonMask,
      expectedYPerColumn: [Int?]
    ) -> HorizonMask? {
        let w = detected.image.width
        let h = detected.image.height

        let detectedY = HorizonScoring.extractHorizonYPerColumn(from: detected.image)

        // Compute per-column deltas where both detected and expected have a Y value.
        var deltas: [Double] = []
        for x in 0..<w {
            if let dy = detectedY[x], x < expectedYPerColumn.count, let ey = expectedYPerColumn[x] {
                deltas.append(Double(dy - ey))
            }
        }

        guard !deltas.isEmpty else {
            Log.w("frame \(frameIndex) referenceSmoothedHorizonMask: no common columns, skipping")
            return nil
        }

        let mean = deltas.reduce(0, +) / Double(deltas.count)
        let variance = deltas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(deltas.count)
        let stddev = variance.squareRoot()
        let threshold = 2.0 * max(stddev, 1.0) // at least 1 px to avoid clamping tiny natural variation

        Log.d("frame \(frameIndex) referenceSmoothedHorizonMask: mean delta=\(String(format:"%.1f", mean)) stddev=\(String(format:"%.1f", stddev)) threshold=\(String(format:"%.1f", threshold))")

        // Build corrected per-column Y array.
        var correctedY = detectedY
        var replacedCount = 0
        for x in 0..<w {
            guard let dy = detectedY[x] else { continue }
            guard x < expectedYPerColumn.count, let ey = expectedYPerColumn[x] else { continue }
            let delta = Double(dy - ey)
            if abs(delta - mean) > threshold {
                correctedY[x] = ey
                replacedCount += 1
            }
        }

        Log.i("frame \(frameIndex) referenceSmoothedHorizonMask: replaced \(replacedCount)/\(w) columns")

        guard let maskImage = PixelatedImage.fromHorizonColumnY(width: w, height: h, columnY: correctedY),
              let result = HorizonMask(maskImage)
        else {
            Log.w("frame \(frameIndex) referenceSmoothedHorizonMask: failed to build mask image")
            return nil
        }

        return result
    }

    // MARK: - Reference stats brightness refinement

    /// Scan the sequence for reference horizon masks, return stats for up to `maxCount`
    /// nearest frames.  Stats are cached in `referenceHorizonStatsCache`.
    private func referenceHorizonsWithStats(maxCount: Int = 2, numBuckets: Int = 256, neighborhoodSize: Int = 1) async throws -> [ReferenceHorizonFrameStats] {
        guard let imageSequence else { return [] }
        guard let mergedPath = imageAccessor.nameForImage(
                frameIndex: frameIndex,
                ofType: .mergedHorizon,
                atSize: .original
              )
        else { return [] }

        let referenceDir = URL(fileURLWithPath: mergedPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("horizonReference")

        let fm = FileManager.default
        var candidates: [(distance: Int, index: Int, maskURL: URL)] = []

        for candidateIndex in 0..<imageSequence.filenames.count {
            guard candidateIndex != frameIndex else { continue }
            guard let candidatePath = imageAccessor.nameForImage(
                    frameIndex: candidateIndex,
                    ofType: .mergedHorizon,
                    atSize: .original
                  )
            else { continue }
            let candidateFileName = URL(fileURLWithPath: candidatePath).lastPathComponent
            let candidateURL = referenceDir.appendingPathComponent(candidateFileName)
            guard fm.fileExists(atPath: candidateURL.path) else { continue }
            candidates.append((
                distance: abs(candidateIndex - frameIndex),
                index: candidateIndex,
                maskURL: candidateURL
            ))
        }

        candidates.sort { $0.distance < $1.distance }

        // Prefer a bracketing pair: nearest ref with index < frameIndex, plus nearest with index > frameIndex.
        // Falls back to plain nearest-N when one side has no refs.
        var ordered: [(distance: Int, index: Int, maskURL: URL)] = []
        if maxCount >= 2,
           let prev = candidates.first(where: { $0.index < frameIndex }),
           let next = candidates.first(where: { $0.index > frameIndex })
        {
            ordered = [prev, next]
            for c in candidates where c.index != prev.index && c.index != next.index {
                if ordered.count >= maxCount { break }
                ordered.append(c)
            }
        } else {
            ordered = Array(candidates.prefix(maxCount))
        }

        var result: [ReferenceHorizonFrameStats] = []
        for candidate in ordered {
            if let cached = await referenceHorizonStatsCache.stats(for: candidate.index) {
                result.append(cached)
                continue
            }
            guard let maskImage = PixelatedImage(filename: candidate.maskURL.path)?.asHorizonMask,
                  let mask = HorizonMask(maskImage),
                  let original = try? await imageAccessor.load(
                    frameIndex: candidate.index,
                    type: .original,
                    atSize: .original
                  )
            else {
                Log.w("frame \(frameIndex) referenceHorizonsWithStats: skipping frame \(candidate.index)")
                continue
            }
            guard let stats = original.computeReferenceHorizonStats(frameIndex: candidate.index, mask: mask, numBuckets: numBuckets, neighborhoodSize: neighborhoodSize)
            else { continue }
            await referenceHorizonStatsCache.set(stats)
            result.append(stats)
        }
        return result
    }

    /// Build a per-column expected horizon Y by linearly interpolating between bracketing
    /// reference frames (one with frameIndex < self.frameIndex, one with > self.frameIndex).
    /// Falls back to a single ref's Y when only one side is available.  Returns nil if no
    /// reference Y data is available.
    ///
    /// For each column the result is the Y position the horizon is *expected* to occupy,
    /// based on the user's manually-specified neighboring horizons.  This is the per-column
    /// prior used by the smoothing filter and the brightness-refinement Y-position term.
    func interpolatedExpectedYPerColumn(
      from stats: [ReferenceHorizonFrameStats],
      width: Int
    ) -> [Int?]? {
        guard !stats.isEmpty else { return nil }
        let prev = stats.filter { $0.frameIndex < frameIndex }
                        .max(by: { $0.frameIndex < $1.frameIndex })
        let next = stats.filter { $0.frameIndex > frameIndex }
                        .min(by: { $0.frameIndex < $1.frameIndex })

        var result = [Int?](repeating: nil, count: width)
        if let p = prev, let n = next {
            let span = Double(n.frameIndex - p.frameIndex)
            let t = span > 0 ? Double(frameIndex - p.frameIndex) / span : 0.5
            let pYs = p.horizonYPerColumn
            let nYs = n.horizonYPerColumn
            let cols = min(width, min(pYs.count, nYs.count))
            for x in 0..<cols {
                switch (pYs[x], nYs[x]) {
                case let (py?, ny?):
                    result[x] = Int((Double(py) * (1.0 - t) + Double(ny) * t).rounded())
                case let (py?, nil): result[x] = py
                case let (nil, ny?): result[x] = ny
                default: break
                }
            }
            return result
        }
        // Only one side has refs — use the nearest single ref's Y values.
        let only = (prev ?? next) ?? stats.min(by: { abs($0.frameIndex - frameIndex) < abs($1.frameIndex - frameIndex) })!
        let ys = only.horizonYPerColumn
        let cols = min(width, ys.count)
        for x in 0..<cols { result[x] = ys[x] }
        return result
    }

    /// Per-pixel brightness + Y-position refinement of `detected` using reference frame stats.
    ///
    /// For each column we have a per-column `expectedY[x]` derived from linear interpolation
    /// between bracketing reference horizons.  Within `searchRadius` of `expectedY[x]` we
    /// blend a brightness-based sky score (from the reference histograms) with a Y-position
    /// score that snaps toward the expected Y as distance grows.  Pixels far from `expectedY`
    /// are dominated by the position prior; pixels near it are dominated by brightness so
    /// real terrain detail (rocks, ridges) is preserved.
    ///
    /// Pixels outside `[expectedY[x] - searchRadius, expectedY[x] + searchRadius]` are
    /// copied unchanged from `detected`.
    private func referenceStatsBrightnessRefinedHorizonMask(
      detected: HorizonMask,
      original: PixelatedImage,
      stats: [ReferenceHorizonFrameStats],
      expectedYPerColumn: [Int?],
      searchRadius: Int = 100,
      spikeRemovalEnabled: Bool = true,
      spikeMaxWidth: Int = 30,
      spikeMaxDeviationFraction: Double = 0.04,
      spikeWindowHalf: Int = 150,
      neighborhoodSize: Int = 1
    ) -> HorizonMask? {
        guard !stats.isEmpty else { return nil }

        let w = detected.image.width
        let h = detected.image.height

        // Precompute inverse-distance normalised weights for histogram lookups.
        let rawWeights: [Double] = stats.map { s in
            1.0 / max(1.0, Double(abs(s.frameIndex - frameIndex)))
        }
        let totalWeight = rawWeights.reduce(0, +)
        let normWeights = rawWeights.map { $0 / totalWeight }

        guard case .eightBit(let detectedBuf) = detected.image.imageData else {
            Log.w("frame \(frameIndex) referenceStatsBrightnessRefinedHorizonMask: mask not 8-bit")
            return nil
        }

        let maxVal = original.maxBrightnessValue
        var outputBytes = [UInt8](detectedBuf)

        var refinedCount = 0
        var minBandTop = h
        var maxBandBottom = 0
        // The position prior reaches full strength at this distance from expectedY.
        // Inside this radius colour evidence still has meaningful weight; beyond it
        // position dominates and pixels snap toward the expected horizon.
        let positionFullRadius = Double(max(1, searchRadius / 2))

        let halfSize = neighborhoodSize / 2

        // Precompute log-weights for distance-weighted averaging of per-frame
        // Gaussian likelihoods in log space.
        let logWeights: [Double] = normWeights.map { Foundation.log(max(1e-12, $0)) }

        for x in 0..<w {
            guard let expY = expectedYPerColumn[x] else { continue }
            let bandTop    = max(0,     expY - searchRadius)
            let bandBottom = min(h - 1, expY + searchRadius)
            if bandTop < minBandTop { minBandTop = bandTop }
            if bandBottom > maxBandBottom { maxBandBottom = bandBottom }

            for y in bandTop...bandBottom {
                let (r, g, bch) = original.neighborhoodAveragedRGB(
                  x: x, y: y, halfSize: halfSize, maxVal: maxVal
                )
                let lab = sRGBtoLAB(r, g, bch)

                // Per-frame log-likelihoods under the sky/ground LAB Gaussians,
                // weighted by inverse frame distance.  Combine via log-sum-exp
                // (numerically stable mixture) and turn into a sky probability.
                var maxSky    = -Double.infinity
                var maxGround = -Double.infinity
                var skyLLs    = [Double](repeating: -Double.infinity, count: stats.count)
                var groundLLs = [Double](repeating: -Double.infinity, count: stats.count)
                for i in 0..<stats.count {
                    if let sky = stats[i].skyGaussian {
                        let ll = logWeights[i] + sky.logLikelihood(lab.L, lab.a, lab.b)
                        skyLLs[i] = ll
                        if ll > maxSky { maxSky = ll }
                    }
                    if let gnd = stats[i].groundGaussian {
                        let ll = logWeights[i] + gnd.logLikelihood(lab.L, lab.a, lab.b)
                        groundLLs[i] = ll
                        if ll > maxGround { maxGround = ll }
                    }
                }
                let brightnessSkyScore: Double
                if maxSky == -Double.infinity || maxGround == -Double.infinity {
                    brightnessSkyScore = 0.5
                } else {
                    var skySum = 0.0, gndSum = 0.0
                    for i in 0..<stats.count {
                        if skyLLs[i]    > -Double.infinity { skySum += Foundation.exp(skyLLs[i]    - maxSky) }
                        if groundLLs[i] > -Double.infinity { gndSum += Foundation.exp(groundLLs[i] - maxGround) }
                    }
                    let logSky    = maxSky    + Foundation.log(skySum)
                    let logGround = maxGround + Foundation.log(gndSum)
                    let logRatio  = logSky - logGround
                    // sigmoid; clamp to avoid exp overflow on extreme distances.
                    let clamped = max(-50.0, min(50.0, logRatio))
                    brightnessSkyScore = 1.0 / (1.0 + Foundation.exp(-clamped))
                }

                // Position prior: weight grows quadratically with distance from expectedY,
                // capped at 1.0.  Above expectedY the prior says sky (1.0); below says ground (0.0).
                let dy = Double(y - expY)
                let absDy = abs(dy)
                let t = min(1.0, absDy / positionFullRadius)
                let yWeight = t * t
                let ySkyScore: Double = dy < 0 ? 1.0 : (dy > 0 ? 0.0 : 0.5)

                let combined = yWeight < 0.001
                    ? brightnessSkyScore
                    : (1.0 - yWeight) * brightnessSkyScore + yWeight * ySkyScore
                let newVal: UInt8 = combined >= 0.5 ? 255 : 0
                let idx = y * w + x
                if newVal != detectedBuf[idx] { refinedCount += 1 }
                outputBytes[idx] = newVal
            }
        }

        let definedExpY = expectedYPerColumn.compactMap { $0 }
        let expYMin = definedExpY.min() ?? -1
        let expYMax = definedExpY.max() ?? -1
        Log.i("frame \(frameIndex) referenceStatsBrightnessRefinedHorizonMask: " +
              "refined \(refinedCount) pixels in band y=[\(minBandTop),\(maxBandBottom)] " +
              "expectedY=[\(expYMin),\(expYMax)] " +
              "skyMedian=\(String(format:"%.4f", stats.first?.medianSkyBrightness ?? 0)) " +
              "groundMedian=\(String(format:"%.4f", stats.first?.medianGroundBrightness ?? 0))")

        // De-spike: extract per-column horizon Y from the refined output, remove narrow
        // upward protrusions (wind turbines, towers, etc.), then re-render the bytes.
        if spikeRemovalEnabled {
            let maxDev = Int((spikeMaxDeviationFraction * Double(h)).rounded())
            let despiked = despikeHorizonY(
              outputBytes,
              width: w, height: h,
              windowHalf: spikeWindowHalf,
              maxDeviation: maxDev,
              maxSpikeWidth: spikeMaxWidth
            )
            if let despiked {
                outputBytes = despiked
            }
        }

        return outputBytes.withUnsafeMutableBytes { ptr -> HorizonMask? in
            guard let base = ptr.baseAddress else { return nil }
            let mat = MatWrapper(
              width: w, height: h,
              cvType: 0,
              bytesPerRow: w,
              data: base,
              takeOwnership: false
            )
            guard let maskImage = PixelatedImage(mat: mat.clone()) else { return nil }
            return HorizonMask(maskImage)
        }
    }

    /// Remove narrow upward spikes and isolated misclassified pixels from a binary horizon
    /// mask stored as a flat byte array.
    ///
    /// Two-pronged approach:
    ///
    /// **Star pixels**: isolated bright pixels misclassified as ground appear as single black
    /// pixels in the sky. They are handled by computing a *robust* horizon Y that requires
    /// `minGroundRun` consecutive black pixels before accepting a column's horizon position.
    /// A lone star pixel is never part of a run of 3+, so it is ignored and the real ground
    /// boundary is used instead.
    ///
    /// **Narrow structures** (wind turbines, towers): these have genuine runs of consecutive
    /// black pixels but form narrow columns that deviate far above the local terrain median.
    /// They are detected by comparing each column's robust horizon Y to the local median over
    /// `windowHalf` columns; deviations greater than `maxDeviation` pixels in runs narrower
    /// than `maxSpikeWidth` columns are replaced by linear interpolation.
    ///
    /// After both corrections, each modified column is re-rendered cleanly: everything above
    /// the corrected horizon Y is set to sky (255), everything at or below is ground (0).
    ///
    /// Returns `nil` if nothing changed.
    func despikeHorizonY(
      _ bytes: [UInt8],
      width w: Int,
      height h: Int,
      windowHalf: Int,
      maxDeviation: Int,
      maxSpikeWidth: Int,
      minGroundRun: Int = 3
    ) -> [UInt8]? {
        // Step 1: extract two horizon Y arrays per column.
        //   firstBlack: first dark pixel encountered (may be an isolated star pixel)
        //   horizonY:   first position where minGroundRun consecutive dark pixels begin
        //               (robust against isolated star pixels)
        var firstBlack = [Int](repeating: h, count: w)
        var horizonY   = [Int](repeating: h, count: w)
        for x in 0..<w {
            var run = 0
            var gotFirst = false
            for y in 0..<h {
                if bytes[y * w + x] == 0 {
                    if !gotFirst { firstBlack[x] = y; gotFirst = true }
                    run += 1
                    if run >= minGroundRun, horizonY[x] == h {
                        horizonY[x] = y - minGroundRun + 1
                    }
                } else {
                    run = 0
                }
            }
        }

        // Step 2: local median of robust horizon Y per column.
        var localMedian = [Int](repeating: h / 2, count: w)
        for x in 0..<w {
            let lo = max(0, x - windowHalf)
            let hi = min(w - 1, x + windowHalf)
            var window = [Int](horizonY[lo...hi])
            window.sort()
            localMedian[x] = window[window.count / 2]
        }

        // Step 3: mark columns where robust horizonY spikes above the local median.
        var isSpike = [Bool](repeating: false, count: w)
        for x in 0..<w {
            if horizonY[x] < localMedian[x] - maxDeviation {
                isSpike[x] = true
            }
        }

        // Step 4a: un-mark wide runs — those are legitimate terrain features, not spikes.
        var x = 0
        while x < w {
            if isSpike[x] {
                var runEnd = x
                while runEnd < w && isSpike[runEnd] { runEnd += 1 }
                if runEnd - x > maxSpikeWidth {
                    for j in x..<runEnd { isSpike[j] = false }
                }
                x = runEnd
            } else {
                x += 1
            }
        }

        // Step 4b: interpolate horizon Y over spike columns.
        var fixedY = horizonY  // robust Y; star columns already corrected vs firstBlack
        for x in 0..<w where isSpike[x] {
            var leftX = x - 1
            while leftX >= 0 && isSpike[leftX] { leftX -= 1 }
            var rightX = x + 1
            while rightX < w && isSpike[rightX] { rightX += 1 }
            let ly = leftX >= 0 ? horizonY[leftX]  : (rightX < w ? horizonY[rightX] : h)
            let ry = rightX < w ? horizonY[rightX] : ly
            if leftX < 0 {
                fixedY[x] = ry
            } else if rightX >= w {
                fixedY[x] = ly
            } else {
                let t = Double(x - leftX) / Double(rightX - leftX)
                fixedY[x] = Int((Double(ly) * (1 - t) + Double(ry) * t).rounded())
            }
        }

        // Determine what actually changed (spike corrections + star-pixel cleanups).
        let spikeCount = isSpike.filter { $0 }.count
        let starCount  = zip(firstBlack, fixedY).filter { $0 < $1 }.count
        guard spikeCount > 0 || starCount > 0 else { return nil }

        Log.i("frame \(frameIndex) despikeHorizonY: fixed \(spikeCount) spike columns, " +
              "\(starCount) isolated-pixel columns " +
              "(maxDev=\(maxDeviation) maxWidth=\(maxSpikeWidth) minRun=\(minGroundRun))")

        // Step 5: re-render changed columns.
        // For each column the intended boundary is fixedY[x].  We update the range between
        // firstBlack[x] (first affected pixel) and fixedY[x] (new boundary).
        var out = bytes
        for x in 0..<w {
            let newY  = fixedY[x]
            let oldFirst = firstBlack[x]
            guard oldFirst != newY else { continue }

            if oldFirst < newY {
                // Sky restored: rows [oldFirst, newY) should be white (255).
                for row in oldFirst..<min(newY, h) { out[row * w + x] = 255 }
            } else {
                // Ground extended down: rows [newY, oldFirst) should be black (0).
                for row in newY..<min(oldFirst, h) { out[row * w + x] = 0 }
            }
        }
        return out
    }

    /// Apply `referenceStatsBrightnessRefinedHorizonMask` if the config enables it and
    /// reference stats are available.  Returns the original mask unchanged on failure.
    private func referenceStatsBrightnessRefinementIfNeeded(
      mask: HorizonMask,
      config: Config
    ) async throws -> HorizonMask {
        guard config.tripodHeadWasMoving,
              config.useReferenceHorizonBrightnessRefinement
        else { return mask }

        let stats = try await referenceHorizonsWithStats(
          maxCount: 2,
          numBuckets: config.referenceHorizonBrightnessRefinementHistogramBuckets,
          neighborhoodSize: config.referenceHorizonNeighborhoodSize
        )
        guard !stats.isEmpty else { return mask }

        guard let expectedY = interpolatedExpectedYPerColumn(from: stats, width: mask.image.width)
        else { return mask }

        guard let original = try? await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original
              )
        else {
            Log.w("frame \(frameIndex) referenceStatsBrightnessRefinementIfNeeded: cannot load original")
            return mask
        }

        return referenceStatsBrightnessRefinedHorizonMask(
          detected: mask,
          original: original,
          stats: stats,
          expectedYPerColumn: expectedY,
          searchRadius: config.referenceHorizonBrightnessRefinementSearchRadius,
          spikeRemovalEnabled: config.horizonSpikeRemovalEnabled,
          spikeMaxWidth: config.horizonSpikeMaxWidth,
          spikeMaxDeviationFraction: config.horizonSpikeMaxDeviationFraction,
          spikeWindowHalf: config.horizonSpikeWindowHalf,
          neighborhoodSize: config.referenceHorizonNeighborhoodSize
        ) ?? mask
    }

    /// Look for a user-painted reference horizon mask on disk and return it if found.
    ///
    /// Search order:
    /// Loads the per-frame reference mask only (does NOT fall back to the global
    /// `reference.tiff`).  Returns non-nil only when this specific frame has its
    /// own painted reference file in `horizonReference/`.
    private func loadPerFrameHorizonReferenceMask() async throws -> HorizonMask? {
        guard let mergedPath = imageAccessor.nameForImage(
                frameIndex: frameIndex,
                ofType: .mergedHorizon,
                atSize: .original
              )
        else { return nil }

        let mergedURL   = URL(fileURLWithPath: mergedPath)
        let frameRefURL = mergedURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("horizonReference")
            .appendingPathComponent(mergedURL.lastPathComponent)

        guard FileManager.default.fileExists(atPath: frameRefURL.path),
              let refImage = PixelatedImage(filename: frameRefURL.path)?.asHorizonMask
        else { return nil }

        return HorizonMask(refImage)
    }

    /// 1. `{horizonReference}/{frameFileName}` — per-frame reference (moving sequences)
    /// 2. `{horizonReference}/reference.tiff`   — global reference (static sequences)
    private func loadHorizonReferenceMask() async throws -> HorizonMask? {
        guard let mergedPath = imageAccessor.nameForImage(
                frameIndex: frameIndex,
                ofType: .mergedHorizon,
                atSize: .original
              )
        else { return nil }

        let mergedURL       = URL(fileURLWithPath: mergedPath)
        let frameFileName   = mergedURL.lastPathComponent
        let referenceDir    = mergedURL
            .deletingLastPathComponent()    // …/mergedHorizon
            .deletingLastPathComponent()    // …/output (tempOutputPath)
            .appendingPathComponent("horizonReference")

        // 1. Per-frame reference
        let frameRefURL = referenceDir.appendingPathComponent(frameFileName)
        if FileManager.default.fileExists(atPath: frameRefURL.path),
           let refImage = PixelatedImage(filename: frameRefURL.path)?.asHorizonMask
        {
            Log.d("frame \(frameIndex) loadHorizonReferenceMask: found per-frame reference")
            return HorizonMask(refImage)
        }

        // 2. Global reference
        let globalRefURL = referenceDir.appendingPathComponent("reference.tiff")
        if FileManager.default.fileExists(atPath: globalRefURL.path),
           let refImage = PixelatedImage(filename: globalRefURL.path)?.asHorizonMask
        {
            Log.d("frame \(frameIndex) loadHorizonReferenceMask: found global reference")
            return HorizonMask(refImage)
        }

        return nil
    }

    // MARK: - Horizon parameter tuning

    /// Load the tuned horizon parameters for this sequence, returning defaults if none saved.
    public func loadTunedHorizonParameters() -> HorizonTunedParameters {
        guard let dir = tunedParametersDirectory() else { return HorizonTunedParameters() }
        return HorizonTunedParameters.load(fromDirectory: dir) ?? HorizonTunedParameters()
    }

    /// Save tuned horizon parameters for this sequence.
    public func saveTunedHorizonParameters(_ params: HorizonTunedParameters) throws {
        guard let dir = tunedParametersDirectory() else {
            throw "frame \(frameIndex): cannot determine tuned parameters directory"
        }
        try params.save(toDirectory: dir)
    }

    /// Returns the URL of the `horizonReference/` directory for this sequence,
    /// or `nil` if the path cannot be determined.
    private func tunedParametersDirectory() -> URL? {
        guard let mergedPath = imageAccessor.nameForImage(
                frameIndex: frameIndex,
                ofType: .mergedHorizon,
                atSize: .original
              )
        else { return nil }
        return URL(fileURLWithPath: mergedPath)
            .deletingLastPathComponent()    // …/mergedHorizon
            .deletingLastPathComponent()    // …/output
            .appendingPathComponent("horizonReference")
    }

    /// If `tuned_parameters.json` does not already exist, run coordinate-descent
    /// tuning against `referenceMask` and write the winner.
    private func maybeTuneHorizonParameters(referenceMask: HorizonMask) async {
        guard let paramsDir = tunedParametersDirectory() else { return }

        // Don't overwrite hand-tuned or previously auto-tuned parameters.
        let jsonURL = paramsDir.appendingPathComponent(HorizonTunedParameters.jsonFilename)
        guard !FileManager.default.fileExists(atPath: jsonURL.path) else {
            Log.d("frame \(frameIndex) maybeTuneHorizonParameters: tuned_parameters.json already exists — skipping")
            return
        }

        // Need homography results for prepare().
        var homographyResults = await frame?.getNeighborStarHomography()
        if homographyResults == nil {
            homographyResults = await frame?.readStarNeighborHomographyForThisFrame()
        }
        guard let homographyResults else {
            Log.w("frame \(frameIndex) maybeTuneHorizonParameters: no star homography — cannot tune")
            return
        }

        guard let mergedMask = try? await loadOrCreateMergedHorizonMask() else { return }
        let currentWidth  = mergedMask.image.width
        let currentHeight = mergedMask.image.height

        var neighborHorizonFilenames:   [String]   = []
        var neighborOriginalFilenames:  [String]   = []
        var neighborHomographies:       [[Double]] = []

        for warpInfo in homographyResults.neighborHomography {
            guard warpInfo.alignmentState == .homographySuccess ||
                  warpInfo.alignmentState == .usedExistingHomography,
                  let homography = warpInfo.homography
            else { continue }
            let neighborIndex = warpInfo.frameIndex
            guard let origFilename = imageAccessor.nameForImage(
                    frameIndex: neighborIndex, ofType: .original, atSize: .original),
                  let horizFilename = imageAccessor.nameForImage(
                    frameIndex: neighborIndex, ofType: .mergedHorizon, atSize: .original)
            else { continue }
            neighborOriginalFilenames.append(origFilename)
            neighborHorizonFilenames.append(horizFilename)
            neighborHomographies.append(homography)
        }

        guard !neighborHomographies.isEmpty else { return }

        let currentImage = try? await imageAccessor.load(
            frameIndex: frameIndex, type: .original, atSize: .original
        )

        // Prepare once — the expensive I/O stage.
        let seedDetector = HomographyHorizonDetector()
        let prepared = seedDetector.prepare(
            currentWidth:              currentWidth,
            currentHeight:             currentHeight,
            neighborHorizonFilenames:  neighborHorizonFilenames,
            neighborOriginalFilenames: neighborOriginalFilenames,
            neighborHomographies:      neighborHomographies,
            currentImage:              currentImage
        )

        let referenceY = HomographyHorizonDetector.horizonYPerColumn(in: referenceMask)
        let tunedParams = tuneDetector(seedDetector, prepared: prepared, referenceY: referenceY)

        do {
            try tunedParams.save(toDirectory: paramsDir)
            Log.i("frame \(frameIndex) maybeTuneHorizonParameters: saved tuned parameters " +
                  "(MAE: \(tunedParams.tuningMeanAbsoluteError.map { String(format: "%.1f", $0) } ?? "n/a"))")
        } catch {
            Log.w("frame \(frameIndex) maybeTuneHorizonParameters: could not save parameters: \(error)")
        }
    }

    /// Coordinate-descent search over the four detector parameters.
    ///
    /// Two passes: each pass cycles through all parameters and picks the best
    /// value within the candidate range while keeping the others fixed.
    /// About 40 evaluations total — all using the pre-built `prepared` data so
    /// no disk I/O is required.
    private func tuneDetector(
        _ initial: HomographyHorizonDetector,
        prepared: HomographyHorizonDetector.PreparedData,
        referenceY: [Int?]
    ) -> HorizonTunedParameters {

        var best = initial
        var bestScore = Double.infinity
        if let mask = best.detectFromPrepared(prepared) {
            bestScore = HomographyHorizonDetector.score(
                algorithmY: HomographyHorizonDetector.horizonYPerColumn(in: mask),
                referenceY: referenceY
            )
        }

        let errorThresholdFactors: [Double] = [0.5, 1.0, 2.0, 3.0, 4.0]
        let errorSearchRanges:     [Int]    = [150, 250, 400, 550]
        let errorBlurRadii:        [Int]    = [2, 5, 8]
        let smoothingRadii:        [Int]    = [25, 50, 75, 100]

        for _ in 0..<2 {
            // Tune errorThresholdFactor
            for v in errorThresholdFactors {
                var candidate = best
                candidate.errorThresholdFactor = v
                if let mask = candidate.detectFromPrepared(prepared) {
                    let s = HomographyHorizonDetector.score(
                        algorithmY: HomographyHorizonDetector.horizonYPerColumn(in: mask),
                        referenceY: referenceY
                    )
                    if s < bestScore { bestScore = s; best = candidate }
                }
            }
            // Tune errorSearchRange
            for v in errorSearchRanges {
                var candidate = best
                candidate.errorSearchRange = v
                if let mask = candidate.detectFromPrepared(prepared) {
                    let s = HomographyHorizonDetector.score(
                        algorithmY: HomographyHorizonDetector.horizonYPerColumn(in: mask),
                        referenceY: referenceY
                    )
                    if s < bestScore { bestScore = s; best = candidate }
                }
            }
            // Tune errorBlurRadius
            for v in errorBlurRadii {
                var candidate = best
                candidate.errorBlurRadius = v
                if let mask = candidate.detectFromPrepared(prepared) {
                    let s = HomographyHorizonDetector.score(
                        algorithmY: HomographyHorizonDetector.horizonYPerColumn(in: mask),
                        referenceY: referenceY
                    )
                    if s < bestScore { bestScore = s; best = candidate }
                }
            }
            // Tune smoothingRadius
            for v in smoothingRadii {
                var candidate = best
                candidate.smoothingRadius = v
                if let mask = candidate.detectFromPrepared(prepared) {
                    let s = HomographyHorizonDetector.score(
                        algorithmY: HomographyHorizonDetector.horizonYPerColumn(in: mask),
                        referenceY: referenceY
                    )
                    if s < bestScore { bestScore = s; best = candidate }
                }
            }
        }

        var params = HorizonTunedParameters()
        params.smoothingRadius      = best.smoothingRadius
        params.errorSearchRange     = best.errorSearchRange
        params.errorBlurRadius      = best.errorBlurRadius
        params.errorThresholdFactor = best.errorThresholdFactor
        params.errorSampleHalfWidth = best.errorSampleHalfWidth
        params.tuningMeanAbsoluteError = bestScore.isFinite ? bestScore : nil
        params.tuningFrameCount = 1
        return params
    }

    // MARK: - Live object-selection horizon preview

    /// Compute the snapped, interpolated per-column horizon Y for live preview
    /// in the horizon painter's "object selection" mode.
    ///
    /// **Algorithm** (adapted from GIMP's Foreground Select / SIOX):
    /// 1. Build a *sky centroid* in CIE L\*a\*b\* from the **bottom 20 %** of the
    ///    painted band (sky immediately adjacent to the ridgeline), and a *ground
    ///    centroid* from the bottom 5 % of the image (guaranteed terrain regardless
    ///    of how high up in the sky the user painted).
    /// 2. For each column scan **downward** from `bottomBoundaryY` computing the
    ///    SIOX ratio: `confidence = d_gnd / (d_sky + d_gnd)`.  The first row where
    ///    `confidence < 0.5` (closer to ground than sky) is the horizon.
    ///    The result is always at or below the painted bottom edge, so the
    ///    selection always expands *downward* toward terrain, never upward.
    ///
    /// Pixel colours are averaged over a ±20 px horizontal window (41 px total)
    /// before LAB conversion, suppressing stars (1–3 px wide) to ≤ 7 % of the
    /// window mean.  The scan additionally requires 3 consecutive terrain-like
    /// rows before declaring the horizon, eliminating false stops on the 1–2 px
    /// dark gaps between stars.
    ///
    /// - Parameters:
    ///   - topBoundaryY:    Per-column Y of the *top* edge of the painted area
    ///     (view coordinates, length = `viewWidth`).
    ///   - bottomBoundaryY: Per-column Y of the *bottom* edge of the painted area
    ///     (view coordinates, length = `viewWidth`).
    ///   - viewWidth:  Width of the frame view in points.
    ///   - viewHeight: Height of the frame view in points.
    /// - Returns: Per-column horizon Y in **view coordinates**
    ///   (length = `viewWidth`).  `nil` columns were not painted.
    /// SIOX three-region horizon detection.
    ///
    /// - Parameters:
    ///   - topBoundaryY: Per-column top of the horizon band (view coords).
    ///   - bottomBoundaryY: Per-column bottom of the horizon band (view coords).
    ///   - viewWidth: Width of the view.
    ///   - viewHeight: Height of the view.
    ///   - bandMode: Must be `true` for three-region SIOX.
    ///   - knownSkyFloorY: Per-column lowest Y known to be sky (view coords).
    ///     Defaults to `topBoundaryY` (initial band computation).
    ///   - knownGroundCeilingY: Per-column highest Y known to be ground (view coords).
    ///     Defaults to `bottomBoundaryY` (initial band computation).
    ///
    /// The algorithm classifies each pixel in the **unknown** region
    /// (between `knownSkyFloor` and `knownGroundCeiling`) by comparing its
    /// 4D feature vector (CIE L*a*b* colour + weighted linear luminance) to
    /// a single global sky centroid and a single global ground centroid,
    /// both computed from ALL known pixels.  The intensity channel provides
    /// Otsu-like brightness discrimination alongside perceptual colour.
    /// Known regions are never reclassified.
    public func computeLiveObjectSelection(
        topBoundaryY:    [Int?],
        bottomBoundaryY: [Int?],
        viewWidth:  Int,
        viewHeight: Int,
        bandMode: Bool = false,
        knownSkyFloorY:      [Int?]? = nil,
        knownGroundCeilingY: [Int?]? = nil
    ) async throws -> [Int?] {
        // 1. Load original image (async I/O — suspends without blocking).
        guard let original = try await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original
              )
        else {
            throw "computeLiveObjectSelection: cannot load original image for frame \(frameIndex)"
        }
        let imgW = original.width
        let imgH = original.height

        // 2. Scale the painted top + bottom boundaries: view coords → image pixel coords.
        let scaleX = Double(imgW) / Double(viewWidth)
        let scaleY = Double(imgH) / Double(viewHeight)

        // scaledTop[ix] / scaledBottom[ix]: image-pixel Y range painted in column ix.
        // Both are nil when the column was not painted at all.
        var scaledTop    = [Int?](repeating: nil, count: imgW)
        var scaledBottom = [Int?](repeating: nil, count: imgW)
        for ix in 0..<imgW {
            let vx  = Int((Double(ix) / scaleX).rounded())
            let col = min(max(vx, 0), topBoundaryY.count - 1)
            if let topVY = topBoundaryY[col] {
                scaledTop[ix]    = Int((Double(topVY) * scaleY).rounded())
            }
            if let botVY = bottomBoundaryY[col] {
                scaledBottom[ix] = Int((Double(botVY) * scaleY).rounded())
            }
        }

        // Scale known-region boundaries: view coords → image pixel coords.
        // knownSkyFloor defaults to topBoundaryY (initial band computation).
        // knownGroundCeiling defaults to bottomBoundaryY.
        let skyFloorSrc   = knownSkyFloorY      ?? topBoundaryY
        let gndCeilingSrc = knownGroundCeilingY  ?? bottomBoundaryY
        var scaledSkyFloor   = [Int?](repeating: nil, count: imgW)
        var scaledGndCeiling = [Int?](repeating: nil, count: imgW)
        for ix in 0..<imgW {
            let vx  = Int((Double(ix) / scaleX).rounded())
            let col = min(max(vx, 0), skyFloorSrc.count - 1)
            if let vy = skyFloorSrc[col] {
                scaledSkyFloor[ix] = Int((Double(vy) * scaleY).rounded())
            }
            if let vy = gndCeilingSrc[col] {
                scaledGndCeiling[ix] = Int((Double(vy) * scaleY).rounded())
            }
        }

        // 3. Horizon detection — SIOX-inspired LAB+intensity ratio
        //    (adapted from GIMP's Foreground Select tool; no Canny).
        //
        //    Stars make Canny unreliable: an isolated star produces the same
        //    high gradient as a mountain ridgeline.  Instead we use the SIOX
        //    "confidence" ratio from GIMP, applied per-column:
        //
        //        confidence = d_gnd / (d_sky + d_gnd)   (in CIE L*a*b* + I)
        //
        //    confidence > 0.5 → pixel closer to sky centroid   → still sky
        //    confidence < 0.5 → pixel closer to ground centroid → horizon found
        //
        //    The feature space is 4D: L*a*b* (perceptually uniform colour)
        //    plus linear luminance I (absolute brightness, Otsu-like).
        //    L* is a cube-root transform of luminance — perceptually uniform
        //    but compresses bright regions.  Adding linear luminance I as a
        //    4th channel preserves absolute brightness differences that help
        //    separate sky from terrain in difficult cases (similar-hue horizons,
        //    twilight scenes, very dark terrain against very dark sky).
        //
        //    Stars are suppressed by averaging pixels over a ±halfW horizontal
        //    window before converting to LAB+I.  A 3 px star in a 61 px window
        //    shifts the windowed mean by only ~5 %, not enough to flip the
        //    ratio.  The mountain silhouette causes a broad, sustained shift
        //    that reliably flips the ratio.
        //
        //    Implementation detail: prefix-sum trick gives O(imgW) per row
        //    instead of O(imgW × windowWidth) for the windowed cache.

        let halfW = 30   // horizontal window half-width (61 px total)
        // A 3 px star contributes only 3/61 ≈ 5 % of the window mean.
        // Even a 10 px star cluster = 16 %, insufficient to dominate a
        // region of continuous sky.  Mountain silhouettes are solid over
        // thousands of pixels and still dominate even with a 61 px window.

        // Weight for the linear-luminance intensity channel in the 4D
        // distance calculation.  Linear Y ranges [0,1]; L* ranges [0,100].
        // Multiplying Y by this weight puts it on a comparable scale to L*.
        // Higher values give more Otsu-like emphasis to raw brightness
        // differences; lower values rely more on perceptual colour.
        let intensityWeight: Float = 100.0

        let pixelData = Array(original.mat.buffer(of: UInt8.self))
        let pixStride = original.bytesPerRow
        let pxBpp     = max(1, original.bytesPerPixel)
        // OpenCV convention: channel order is [Blue=0, Green=1, Red=2, (Alpha=3)]

        let snapTop    = scaledTop
        let snapBottom = scaledBottom

        // Pre-compute the LAB band covering the full image height so we can
        // scan all the way down to terrain regardless of where the user painted.
        let globalTop = max(0, snapTop.compactMap { $0 }.min() ?? 0)
        let globalBot = imgH - 1   // always extend to the bottom of the image

        // `scaledY`: image-pixel horizon Y per image column (length = imgW).
        // Captures for Sendable closure.
        let skyFloor   = scaledSkyFloor
        let gndCeiling = scaledGndCeiling
        var scaledY: [Int?] = await Task.detached(priority: .userInitiated) {

            // ── Linearise LUT ─────────────────────────────────────────────────
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
                // L*a*b* for perceptual colour + linear luminance Y for
                // Otsu-like intensity discrimination.
                return (116.0*fy - 16.0,  500.0*(fx - fy),  200.0*(fy - fz),  Y)
            }

            // ── Phase A: build the windowed-LAB cache ──────────────────────────
            let rowStep = 2

            // Column range covering all painted columns.
            let colLeft  = snapTop.firstIndex(where: { $0 != nil }) ?? 0
            let colRight = snapTop.lastIndex(where:  { $0 != nil }) ?? (imgW - 1)
            guard colLeft <= colRight else { return [Int?](repeating: nil, count: imgW) }
            let colWidth = colRight - colLeft + 1

            let pxLeft  = max(0,        colLeft  - halfW)
            let pxRight = min(imgW - 1, colRight + halfW)
            let pxWidth = pxRight - pxLeft + 1

            let bandH = (globalBot - globalTop) / rowStep + 1
            var winL  = [Float](repeating: 0, count: bandH * colWidth)
            var winA  = [Float](repeating: 0, count: bandH * colWidth)
            var winBB = [Float](repeating: 0, count: bandH * colWidth)
            var winI  = [Float](repeating: 0, count: bandH * colWidth)

            for iy in stride(from: globalTop, through: globalBot, by: rowStep) {
                let ri = (iy - globalTop) / rowStep
                var prefR = [Float](repeating: 0, count: pxWidth + 1)
                var prefG = [Float](repeating: 0, count: pxWidth + 1)
                var prefB = [Float](repeating: 0, count: pxWidth + 1)
                for i in 0..<pxWidth {
                    let ix   = pxLeft + i
                    let base = iy * pixStride + ix * pxBpp
                    let bV   = linearLUT[Int(pixelData[base])]
                    let gV   = pxBpp > 1 ? linearLUT[Int(pixelData[base + 1])] : bV
                    let rV   = pxBpp > 2 ? linearLUT[Int(pixelData[base + 2])] : bV
                    prefR[i+1] = prefR[i] + rV
                    prefG[i+1] = prefG[i] + gV
                    prefB[i+1] = prefB[i] + bV
                }
                for ix in colLeft...colRight {
                    let i   = ix - pxLeft
                    let lo  = max(0,          i - halfW)
                    let hi  = min(pxWidth - 1, i + halfW)
                    let cnt = Float(hi - lo + 1)
                    let mr  = (prefR[hi+1] - prefR[lo]) / cnt
                    let mg  = (prefG[hi+1] - prefG[lo]) / cnt
                    let mb  = (prefB[hi+1] - prefB[lo]) / cnt
                    let (L, a, lab_b, intensity) = linRGBtoLABI(r: mr, g: mg, b: mb)
                    let idx = ri * colWidth + (ix - colLeft)
                    winL[idx] = L;  winA[idx] = a;  winBB[idx] = lab_b
                    winI[idx] = intensity * intensityWeight
                }
            }

            // ── Phase B: SIOX three-region scan ───────────────────────────────

            @inline(__always)
            func labiAt(ix: Int, iy: Int) -> (L: Float, a: Float, b: Float, I: Float) {
                let ri  = min((iy - globalTop) / rowStep, bandH - 1)
                let idx = ri * colWidth + (ix - colLeft)
                return (winL[idx], winA[idx], winBB[idx], winI[idx])
            }
            @inline(__always)
            func dist2(_ l1: Float, _ a1: Float, _ b1: Float, _ i1: Float,
                       _ l2: Float, _ a2: Float, _ b2: Float, _ i2: Float) -> Float {
                let dL = l1-l2, da = a1-a2, db = b1-b2, di = i1-i2
                return dL*dL + da*da + db*db + di*di
            }

            let centroidColStep = max(1, (colRight - colLeft + 1) / 40)

            // ── Global sky centroid (4D: L*a*b* + intensity) ──────────────
            //
            // Computed from ALL known-sky pixels: everything from row 0 down
            // to knownSkyFloor[col] for each column.  This is a single global
            // centroid (no per-group segmentation) to avoid banding effects.
            var skyLSum: Float = 0, skyASum: Float = 0, skyBBSum: Float = 0
            var skyISum: Float = 0
            var nSky = 0
            for ix in stride(from: colLeft, through: colRight, by: centroidColStep) {
                let floor = skyFloor[ix] ?? snapTop[ix] ?? globalTop
                guard floor > 0 else { continue }
                let yStep = max(1, floor / 20)
                for iy in stride(from: 0, to: floor, by: yStep) {
                    let base = iy * pixStride + ix * pxBpp
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
            let globalSkyL  = skyLSum  / nSkyF
            let globalSkyA  = skyASum  / nSkyF
            let globalSkyBB = skyBBSum / nSkyF
            let globalSkyI  = skyISum  / nSkyF

            // ── Global ground centroid (4D: L*a*b* + intensity) ──────────
            //
            // Computed from ALL known-ground pixels: everything from
            // knownGroundCeiling[col] down to imgH for each column.
            var gndLSum: Float = 0, gndASum: Float = 0, gndBBSum: Float = 0
            var gndISum: Float = 0
            var nGnd = 0
            for ix in stride(from: colLeft, through: colRight, by: centroidColStep) {
                let ceiling = gndCeiling[ix] ?? snapBottom[ix] ?? (imgH - 1)
                guard ceiling < imgH else { continue }
                let rowSpan = imgH - ceiling
                let yStep = max(1, rowSpan / 20)
                for iy in stride(from: ceiling, to: imgH, by: yStep) {
                    let base = iy * pixStride + ix * pxBpp
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
            let globalGndL  = gndLSum  / nGndF
            let globalGndA  = gndASum  / nGndF
            let globalGndBB = gndBBSum / nGndF
            let globalGndI  = gndISum  / nGndF

            // ── Per-column scan (unknown region only) ────────────────────────
            //
            // For each column, the scan region is the unknown gap:
            //   top  = knownSkyFloor[col]     (everything above is locked sky)
            //   bot  = knownGroundCeiling[col] (everything below is locked ground)
            //
            // We scan top-down through this gap.  The first run of
            // `minConsecutive` terrain-like rows marks the horizon.
            // If no terrain is found, the horizon defaults to the bottom
            // of the unknown gap (all unknown pixels are sky).

            let minConsecutive = 4
            var result = [Int?](repeating: nil, count: imgW)

            for ix in colLeft...colRight {
                guard let bandTop = snapTop[ix],
                      let bandBot = snapBottom[ix] else { continue }

                // Unknown region boundaries for this column.
                let unknownTop = max(0, skyFloor[ix]   ?? bandTop)
                let unknownBot = min(imgH - 1, gndCeiling[ix] ?? bandBot)

                guard unknownTop < unknownBot else {
                    // No unknown gap — horizon is at the sky floor.
                    result[ix] = unknownTop
                    continue
                }

                var consecutiveTerrain = 0
                var horizonY = unknownBot   // default: all unknown is sky
                for iy in unknownTop ..< unknownBot {
                    let (L, a, b, I) = labiAt(ix: ix, iy: iy)
                    if dist2(L, a, b, I, globalGndL, globalGndA, globalGndBB, globalGndI) <
                       dist2(L, a, b, I, globalSkyL, globalSkyA, globalSkyBB, globalSkyI) {
                        consecutiveTerrain += 1
                        if consecutiveTerrain >= minConsecutive {
                            horizonY = iy - minConsecutive + 1
                            break
                        }
                    } else {
                        consecutiveTerrain = 0
                    }
                }
                result[ix] = max(unknownTop, min(horizonY, unknownBot))
            }
            return result
        }.value

        // 4. Linear-interpolate gaps between painted image columns.
        var lastValidIdx: Int? = nil
        var lastValidY:   Int  = 0
        for ix in 0..<imgW {
            if let y = scaledY[ix] {
                if let prev = lastValidIdx, prev < ix - 1 {
                    let span = ix - prev
                    for gap in (prev + 1)..<ix {
                        let t = Double(gap - prev) / Double(span)
                        scaledY[gap] = Int((Double(lastValidY) * (1 - t) + Double(y) * t).rounded())
                    }
                }
                lastValidIdx = ix
                lastValidY   = y
            }
        }

        // 4b. Median filter — removes isolated per-column spikes caused by snow
        //     patches, bright terrain features, or stray dark/bright pixels that
        //     shift the SIOX ratio for only a few individual columns.
        //     A ±medW window replaces each column's value with the median of its
        //     neighbours, eliminating narrow outliers while preserving the broad
        //     horizon curve.
        let medW = 40
        var smoothedY = scaledY
        for ix in 0..<imgW {
            guard scaledY[ix] != nil else { continue }
            let lo = max(0, ix - medW)
            let hi = min(imgW - 1, ix + medW)
            var window: [Int] = []
            window.reserveCapacity(hi - lo + 1)
            for jx in lo...hi { if let y = scaledY[jx] { window.append(y) } }
            if !window.isEmpty {
                window.sort()
                smoothedY[ix] = window[window.count / 2]
            }
        }
        scaledY = smoothedY

        // 5. Convert image-pixel coords → view coords.
        //    `applyExpandedHorizonMask` renders into a Canvas sized at view dimensions,
        //    so the returned array MUST have `viewWidth` elements with view-coord Ys.
        var viewY = [Int?](repeating: nil, count: viewWidth)
        for vx in 0..<viewWidth {
            let ix = min(max(0, Int((Double(vx) * scaleX).rounded())), imgW - 1)
            if let iy = scaledY[ix] {
                viewY[vx] = Int((Double(iy) / scaleY).rounded())
            }
        }

        return viewY
    }

    // MARK: - Random Walker horizon detection

    // MARK: - CombinedHorizonDetector interactive detection

    /// Fill nil values at the leading and trailing edges of an array with
    /// nearest-neighbour extrapolation.  Interior nil runs are left unchanged.
    static func fillEdgeNils(_ arr: [Int?]) -> [Int?] {
        var result = arr
        if let first = result.first(where: { $0 != nil }) {
            for i in result.indices { if result[i] != nil { break }; result[i] = first }
        }
        if let last = result.last(where: { $0 != nil }) {
            for i in result.indices.reversed() { if result[i] != nil { break }; result[i] = last }
        }
        return result
    }

    /// Horizon detection within the user's painted band using `CombinedHorizonDetector`.
    ///
    /// Runs the full multi-method pipeline (Otsu, DP, SIOX, gradient, texture)
    /// constrained to the painted band region.  Locked sky/ground regions —
    /// set by user brush strokes during refinement — are honoured in the output
    /// and are never re-classified by the detector.  Edge columns that were not
    /// painted are filled by nearest-neighbour extrapolation so the horizon
    /// always covers the full frame width.
    ///
    /// - Parameters:
    ///   - topBoundaryY:         Per-column top of painted band (view coords).
    ///   - bottomBoundaryY:      Per-column bottom of painted band (view coords).
    ///   - viewWidth:            Width of the view in points.
    ///   - viewHeight:           Height of the view in points.
    ///   - knownSkyFloorY:       Per-column lowest Y confirmed as sky (view coords).
    ///   - knownGroundCeilingY:  Per-column highest Y confirmed as ground (view coords).
    /// - Returns: Per-column horizon Y in view coordinates, edge-extrapolated.
    public func computeCombinedHorizonInBand(
        topBoundaryY: [Int?],
        bottomBoundaryY: [Int?],
        viewWidth: Int,
        viewHeight: Int,
        knownSkyFloorY: [Int?]? = nil,
        knownGroundCeilingY: [Int?]? = nil
    ) async throws -> [Int?] {
        guard let original = try await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original
              )
        else {
            throw "computeCombinedHorizonInBand: cannot load original image for frame \(frameIndex)"
        }
        let imgW = original.width
        let imgH = original.height
        let scaleX = Double(imgW) / Double(viewWidth)
        let scaleY = Double(imgH) / Double(viewHeight)

        // Edge-fill the band boundaries so all columns have a value.
        let topFilled = FrameHorizonProcessor.fillEdgeNils(topBoundaryY)
        let botFilled = FrameHorizonProcessor.fillEdgeNils(bottomBoundaryY)

        // Per-column effective detection window:
        // top = max(knownSkyFloor, bandTop)   — narrowed by user painting sky downward
        // bot = min(knownGroundCeiling, bandBot) — narrowed by user erasing upward
        let skyFloorSrc = FrameHorizonProcessor.fillEdgeNils(
            knownSkyFloorY ?? topFilled
        )
        let gndCeilSrc = FrameHorizonProcessor.fillEdgeNils(
            knownGroundCeilingY ?? botFilled
        )

        var effectiveTop = [Int?](repeating: nil, count: viewWidth)
        var effectiveBot = [Int?](repeating: nil, count: viewWidth)
        for vx in 0..<viewWidth {
            let sf = skyFloorSrc[vx]
            let tb = topFilled[vx]
            effectiveTop[vx] = (sf != nil && tb != nil) ? max(sf!, tb!) : (sf ?? tb)

            let gc = gndCeilSrc[vx]
            let bb = botFilled[vx]
            effectiveBot[vx] = (gc != nil && bb != nil) ? min(gc!, bb!) : (gc ?? bb)
        }

        // Set SIOX band fractions from the global effective window.
        let globalTopView  = effectiveTop.compactMap { $0 }.min() ?? 0
        let globalBotView  = effectiveBot.compactMap { $0 }.max() ?? viewHeight
        var params = CombinedHorizonDetector.Params()
        params.sioxBandTopFraction    = max(0.0, Double(globalTopView)  / Double(viewHeight) - 0.02)
        params.sioxBandBottomFraction = min(1.0, Double(globalBotView)  / Double(viewHeight) + 0.02)

        // Run the full combined detection pipeline.
        let horizonMask = try await CombinedHorizonDetector.detect(image: original, params: params)

        // Extract per-column Y (image-pixel coords) from the binary mask.
        let detectedImgY = CombinedHorizonDetector.extractHorizonY(from: horizonMask.image)

        // Map to view coords and clamp each column to its effective window.
        var result = [Int?](repeating: nil, count: viewWidth)
        for vx in 0..<viewWidth {
            let ix = min(max(0, Int((Double(vx) * scaleX).rounded())), imgW - 1)
            guard var iy = detectedImgY[ix] else { continue }

            // Clamp to per-column effective window (image-pixel coords).
            if let topVY = effectiveTop[vx] {
                iy = max(iy, Int((Double(topVY) * scaleY).rounded()))
            }
            if let botVY = effectiveBot[vx] {
                iy = min(iy, Int((Double(botVY) * scaleY).rounded()))
            }

            result[vx] = Int((Double(iy) / scaleY).rounded())
        }

        // Edge-extrapolate so the horizon spans the full frame width.
        return FrameHorizonProcessor.fillEdgeNils(result)
    }

    /// Edge-aware Random Walker horizon detection within the user's painted band.
    ///
    /// This is an alternative to the SIOX method in `computeLiveObjectSelection`.
    /// It solves a graph-based diffusion problem where:
    /// - Above the band = sky seeds (probability 1.0)
    /// - Below the band = ground seeds (probability 0.0)
    /// - Within the band = unknown, solved via Gauss-Seidel iteration
    /// - Edge weights = exp(-beta * gradient^2): strong edges resist crossing
    ///
    /// The horizon is found by scanning **upward** from the ground seeds,
    /// locating where the sky probability crosses 0.5.  Results are edge-snapped
    /// to the nearest strong vertical gradient and median-filtered.
    ///
    /// The algorithm operates on a downsampled copy (max 2048px wide) for
    /// performance, with multi-scale solving for fast convergence.
    /// Stars are suppressed via Gaussian pre-blur.
    ///
    /// - Parameters:
    ///   - topBoundaryY:         Per-column top of painted band (view coords).
    ///   - bottomBoundaryY:      Per-column bottom of painted band (view coords).
    ///   - viewWidth:            Width of the view.
    ///   - viewHeight:           Height of the view.
    ///   - knownSkyFloorY:       Per-column lowest Y known sky (view coords).
    ///   - knownGroundCeilingY:  Per-column highest Y known ground (view coords).
    ///   - beta:                 Edge weight sensitivity (default 90).
    /// - Returns: Per-column horizon Y in view coordinates. `nil` = unpainted.
    public func computeRandomWalkerHorizon(
        topBoundaryY:    [Int?],
        bottomBoundaryY: [Int?],
        viewWidth:  Int,
        viewHeight: Int,
        knownSkyFloorY:      [Int?]? = nil,
        knownGroundCeilingY: [Int?]? = nil,
        beta: Double = 90.0
    ) async throws -> [Int?] {
        // 1. Load original image.
        guard let original = try await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original
              )
        else {
            throw "computeRandomWalkerHorizon: cannot load original image for frame \(frameIndex)"
        }
        let imgW = original.width
        let imgH = original.height

        // 2. Scale view coords → image pixel coords.
        let scaleX = Double(imgW) / Double(viewWidth)
        let scaleY = Double(imgH) / Double(viewHeight)

        let skyFloorSrc   = knownSkyFloorY     ?? topBoundaryY
        let gndCeilingSrc = knownGroundCeilingY ?? bottomBoundaryY

        // Build Int32 arrays for C bridge.  -1 = unpainted column.
        var bandTop    = [Int32](repeating: -1, count: imgW)
        var bandBottom = [Int32](repeating: -1, count: imgW)
        var skyFloor   = [Int32](repeating: -1, count: imgW)
        var gndCeiling = [Int32](repeating: -1, count: imgW)

        for ix in 0..<imgW {
            let vx  = Int((Double(ix) / scaleX).rounded())
            let col = min(max(vx, 0), topBoundaryY.count - 1)

            if let topVY = topBoundaryY[col] {
                bandTop[ix] = Int32(min(max(Int((Double(topVY) * scaleY).rounded()), 0), imgH - 1))
            }
            if let botVY = bottomBoundaryY[col] {
                bandBottom[ix] = Int32(min(max(Int((Double(botVY) * scaleY).rounded()), 0), imgH - 1))
            }
            if let skyVY = skyFloorSrc[col] {
                skyFloor[ix] = Int32(min(max(Int((Double(skyVY) * scaleY).rounded()), 0), imgH - 1))
            }
            if let gndVY = gndCeilingSrc[col] {
                gndCeiling[ix] = Int32(min(max(Int((Double(gndVY) * scaleY).rounded()), 0), imgH - 1))
            }
        }

        // 3. Call Random Walker C++ implementation.
        let horizonY = PixelatedImageBridge.randomWalkerHorizon(
            original.mat,
            bandTopY: bandTop,
            bandBottomY: bandBottom,
            skyFloorY: skyFloor,
            groundCeilY: gndCeiling,
            beta: beta
        )

        // 4. Convert image pixel coords → view coords.
        var viewY = [Int?](repeating: nil, count: viewWidth)
        for vx in 0..<viewWidth {
            let ix = min(max(0, Int((Double(vx) * scaleX).rounded())), imgW - 1)
            let iy = horizonY[ix]
            if iy >= 0 {
                viewY[vx] = Int((Double(iy) / scaleY).rounded())
            }
        }

        return viewY
    }

    // MARK: - Load existing reference horizon for interactive editing

    /// Return the existing user-painted reference horizon as per-column Y values
    /// in **view** coordinates, or `nil` if no reference mask exists on disk.
    ///
    /// Used by `HorizonPainterView` to pre-populate the painter when the user
    /// opens the tool on a frame that already has a saved reference, so they
    /// can jump straight into refinement rather than re-painting the band.
    public func loadExistingHorizonReferenceAsViewY(
        viewWidth:  Int,
        viewHeight: Int
    ) async throws -> [Int?]? {
        guard let mask = try await loadHorizonReferenceMask() else { return nil }
        return horizonMaskToViewY(mask, viewWidth: viewWidth, viewHeight: viewHeight)
    }

    /// Loads the best available existing horizon for this frame into view
    /// coordinates, without computing or creating anything.
    ///
    /// Search order (highest quality first):
    /// 1. User-painted reference in `horizonReference/`
    /// 2. Cached `mergedHorizon`
    /// 3. Raw `horizon`
    ///
    /// Returns `nil` if no horizon data exists for this frame.
    public func loadBestExistingHorizonAsViewY(
        viewWidth:  Int,
        viewHeight: Int
    ) async throws -> [Int?]? {
        if let result = try await loadExistingHorizonReferenceAsViewY(
               viewWidth: viewWidth, viewHeight: viewHeight) {
            return result
        }
        for type in [FrameViewMode.mergedHorizon, .horizon] {
            if let image = try? await imageAccessor.load(
                   frameIndex: frameIndex, type: type, atSize: .original),
               let horizonMask = image.asHorizonMask,
               let mask = HorizonMask(horizonMask)
            {
                return horizonMaskToViewY(mask,
                                          viewWidth:  viewWidth,
                                          viewHeight: viewHeight)
            }
        }
        return nil
    }

    private func horizonMaskToViewY(
        _ mask: HorizonMask,
        viewWidth:  Int,
        viewHeight: Int
    ) -> [Int?] {
        let imgW   = mask.image.width
        let imgH   = mask.image.height
        let scaleX = Double(imgW) / Double(viewWidth)
        let scaleY = Double(imgH) / Double(viewHeight)
        let imgY   = CombinedHorizonDetector.extractHorizonY(from: mask.image)
        var viewY  = [Int?](repeating: nil, count: viewWidth)
        for vx in 0..<viewWidth {
            let ix = min(max(0, Int((Double(vx) * scaleX).rounded())), imgW - 1)
            if let iy = imgY[ix] {
                viewY[vx] = Int((Double(iy) / scaleY).rounded())
            }
        }
        return FrameHorizonProcessor.fillEdgeNils(viewY)
    }

    // MARK: - Filmstrip horizon thumbnail overlay

    /// Returns `true` if a user-painted reference horizon file exists on disk
    /// for this frame (either per-frame or global).  Synchronous — no I/O beyond
    /// a file-existence check.
    public var hasHorizonReference: Bool {
        guard let mergedPath = imageAccessor.nameForImage(
                frameIndex: frameIndex,
                ofType: .mergedHorizon,
                atSize: .original
              )
        else { return false }
        let mergedURL     = URL(fileURLWithPath: mergedPath)
        let frameFileName = mergedURL.lastPathComponent
        let referenceDir  = mergedURL
            .deletingLastPathComponent()    // …/mergedHorizon
            .deletingLastPathComponent()    // …/output
            .appendingPathComponent("horizonReference")
        return FileManager.default.fileExists(
                   atPath: referenceDir.appendingPathComponent(frameFileName).path)
            || FileManager.default.fileExists(
                   atPath: referenceDir.appendingPathComponent("reference.tiff").path)
    }

    /// Loads `.mergedHorizon` for the overlay, retrying briefly when the file
    /// exists on disk but the load returns nil. Under heavy concurrent I/O
    /// during reprocessing, transient `cv::imread` failures would otherwise
    /// leave the overlay stuck on `.initial` (white) for ~1-3% of frames even
    /// though a valid merged horizon is on disk; a reload of the sequence
    /// would then "fix" them. See suspect #1 in the white-line investigation.
    private func loadMergedHorizonForOverlayWithRetry() async -> PixelatedImage? {
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            if let img = try? await imageAccessor.load(
                           frameIndex: frameIndex,
                           type: .mergedHorizon,
                           atSize: .original)
            {
                if attempt > 0 {
                    Log.w("frame \(frameIndex) merged-horizon overlay load succeeded on retry attempt \(attempt)")
                }
                return img
            }
            // Only retry when the file genuinely exists; if the merged horizon
            // hasn't been computed yet, falling through to .horizon is correct.
            guard imageAccessor.imageExists(
                    frameIndex: frameIndex,
                    ofType: .mergedHorizon,
                    atSize: .original)
            else { return nil }
            if attempt < maxAttempts - 1 {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            }
        }
        Log.w("frame \(frameIndex) merged-horizon overlay load failed \(maxAttempts) times despite file existing on disk; overlay will fall back to white")
        return nil
    }

    /// Load the best-available horizon for this frame and scale it to thumbnail
    /// dimensions, returning a `HorizonThumbnailOverlay` suitable for drawing
    /// directly on a filmstrip cell.
    ///
    /// Priority: **reference** (green) › **merged** (blue) › **initial** (white).
    /// Returns `nil` when no horizon of any kind has been computed yet.
    ///
    ///
    /// - Parameters:
    ///   - thumbnailWidth:  Width of the thumbnail in pixels.
    ///   - thumbnailHeight: Height of the thumbnail in pixels.
    public func loadHorizonThumbnailOverlay(
        thumbnailWidth:  Int,
        thumbnailHeight: Int
    ) async throws -> HorizonThumbnailOverlay? {

        // ── Choose the best available source ────────────────────────────────
        // Each load is individually guarded with try? so that a failure for
        // one type (e.g., a corrupt file) falls through to the next rather
        // than aborting the whole chain and leaving the overlay nil/stale.
        let pixImage: PixelatedImage
        let kind: HorizonThumbnailOverlay.Kind

        // Per-frame reference (the actual painted frame) → green.
        // Global-only reference (static timelapse, not the painted frame) → blue.
        if let refMask = try? await loadPerFrameHorizonReferenceMask() {
            pixImage = refMask.image
            kind     = .reference
        } else if let refMask = try? await loadHorizonReferenceMask() {
            pixImage = refMask.image
            kind     = .merged
        } else if let mergedImage = await loadMergedHorizonForOverlayWithRetry() {
            pixImage = mergedImage
            kind     = .merged
        } else if let initialImage = try? await imageAccessor.load(
                      frameIndex: frameIndex,
                      type: .horizon,
                      atSize: .original)
        {
            pixImage = initialImage
            kind     = .initial
        } else {
            return nil
        }

        // ── Scale image-space horizon Y → thumbnail Y ────────────────────
        let imgW   = pixImage.width
        let imgH   = pixImage.height
        let scaleX = Double(imgW) / Double(thumbnailWidth)
        let scaleY = Double(imgH) / Double(thumbnailHeight)

        let imgY   = CombinedHorizonDetector.extractHorizonY(from: pixImage)

        var thumbY = [Int](repeating: thumbnailHeight / 2, count: thumbnailWidth)
        for tx in 0..<thumbnailWidth {
            let ix = min(max(0, Int((Double(tx) * scaleX).rounded())), imgW - 1)
            if let iy = imgY[ix] {
                thumbY[tx] = min(thumbnailHeight - 1,
                                 max(0, Int((Double(iy) / scaleY).rounded())))
            }
        }

        return HorizonThumbnailOverlay(kind: kind, yPerColumn: thumbY, height: thumbnailHeight)
    }

    // MARK: - Save user-painted reference horizon mask

    /// Convert a painted horizon (from `HorizonPainterView`) into a binary
    /// `HorizonMask` TIFF and write it to the `horizonReference/` directory.
    ///
    /// - Parameters:
    ///   - paintedYPerColumn: Per-column painted horizon Y in *view* coordinates.
    ///   - viewWidth:  Width of the frame view in points (view coordinate space).
    ///   - viewHeight: Height of the frame view in points.
    public func saveHorizonReferenceMask(
        paintedYPerColumn: [Int?],
        viewWidth:  Int,
        viewHeight: Int
    ) async throws {
        // 1. Load original image to get actual pixel dimensions.
        guard let original = try await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original
              )
        else {
            throw "saveHorizonReferenceMask: cannot load original image for frame \(frameIndex)"
        }
        let imgW = original.width
        let imgH = original.height

        // 2. Scale painted Y from view coordinates → image pixel coordinates.
        let scaleX = Double(imgW) / Double(viewWidth)
        let scaleY = Double(imgH) / Double(viewHeight)

        var scaledY = [Int?](repeating: nil, count: imgW)
        for ix in 0..<imgW {
            // Map image column back to nearest painted column.
            let vx = Int((Double(ix) / scaleX).rounded())
            let paintedCol = min(max(vx, 0), paintedYPerColumn.count - 1)
            if let vy = paintedYPerColumn[paintedCol] {
                scaledY[ix] = Int((Double(vy) * scaleY).rounded())
            }
        }

        // 3. Linear-interpolate gaps between painted columns.
        var lastValidIdx: Int? = nil
        var lastValidY:   Int  = 0
        for ix in 0..<imgW {
            if let y = scaledY[ix] {
                if let prev = lastValidIdx, prev < ix - 1 {
                    let span = ix - prev
                    for gap in (prev + 1)..<ix {
                        let t = Double(gap - prev) / Double(span)
                        scaledY[gap] = Int((Double(lastValidY) * (1 - t) + Double(y) * t).rounded())
                    }
                }
                lastValidIdx = ix
                lastValidY   = y
            }
        }

        // 4. Build the binary mask image.
        let maskMat = PixelatedImageBridge.binaryHorizonMask(
            width:  Int32(imgW),
            height: Int32(imgH),
            horizonY: scaledY
        )
        guard let maskPixelated = PixelatedImage(mat: maskMat) else {
            throw "saveHorizonReferenceMask: could not create mask image for frame \(frameIndex)"
        }

        // 5. Determine save path inside horizonReference/.
        guard let mergedPath = imageAccessor.nameForImage(
                frameIndex: frameIndex,
                ofType: .mergedHorizon,
                atSize: .original
              )
        else {
            throw "saveHorizonReferenceMask: cannot determine output path for frame \(frameIndex)"
        }
        let mergedURL     = URL(fileURLWithPath: mergedPath)
        let frameFileName = mergedURL.lastPathComponent
        let referenceDir  = mergedURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("horizonReference")

        try FileManager.default.createDirectory(
            at: referenceDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let config = await configManager.config()
        let saveName = config.tripodHeadWasMoving ? frameFileName : "reference.tiff"
        let savePath = referenceDir.appendingPathComponent(saveName).path

        maskPixelated.writeTIFFEncoding(toFilename: savePath)
        Log.i("frame \(frameIndex) saveHorizonReferenceMask: saved \(savePath)")

        // For static sequences, also write a per-frame marker so this specific frame
        // can be identified as the painted reference (shown green; others show blue).
        if !config.tripodHeadWasMoving {
            let perFramePath = referenceDir.appendingPathComponent(frameFileName).path
            maskPixelated.writeTIFFEncoding(toFilename: perFramePath)
            Log.i("frame \(frameIndex) saveHorizonReferenceMask: saved per-frame marker \(perFramePath)")
        }
    }

    // this horizon mask is calculated based upon this frame only.
    // Uses adaptive parameter search: runs horizon detection at reduced resolution
    // with multiple parameter combinations, scores each result, then applies the
    // best parameters at full resolution.
    internal func loadOrCreateHorizonMask() async throws -> HorizonMask {
        // If the user has painted a reference horizon, use it directly.
        if let referenceMask = try await loadHorizonReferenceMask() {
            Log.i("frame \(frameIndex) loadOrCreateHorizonMask: using reference mask (skipping base detection)")
            return referenceMask
        }
        Log.d("frame \(frameIndex) trying to load horizon mask")
        // load if possible
        do {
            if let horizonMaskImage = try await imageAccessor.load(
                 frameIndex: frameIndex,
                 type: .horizon,
                 atSize: .original
               )
            {
                Log.d("frame \(frameIndex) successfully loaded horizon mask")
                if let mask = HorizonMask(horizonMaskImage) {
                    return mask
                }
                Log.w("frame \(frameIndex) loaded horizon mask image but could not compute bounds")
            }
        } catch {
            Log.i("frame \(frameIndex) unable to load horizon mask: \(error)")
        }
        Log.d("frame \(frameIndex) trying to create horizon mask")

        await frame?.set(state: .horizonDetection)
        let config = await configManager.config()
        let adaptiveState = configManager.adaptiveHorizonState

        guard let original = try await imageAccessor.load(
                frameIndex: frameIndex,
                type: .original,
                atSize: .original
              )
        else {
            throw "cannot load original image for horizon detection"
        }

        let horizonMask: HorizonMask

        if config.useCombinedHorizonDetection {
            // Combined+RW pipeline: run Otsu, DP, SIOX in parallel, median-combine,
            // then refine with Random Walker. Best-performing method as of 2026-03.
            Log.i("frame \(frameIndex) using combined+RW horizon detection")
            horizonMask = try await CombinedHorizonDetector.detect(image: original)
        } else {
            // Legacy adaptive search: Otsu multi-crop + DP grid search
            let useAdaptiveSearch = config.horizonSearchCropBounds.count >= 2

            if useAdaptiveSearch {
                horizonMask = try await adaptiveHorizonSearch(
                  original: original,
                  config: config,
                  adaptiveState: adaptiveState
                )
            } else {
                // Fallback: single parameter set, same as original behavior
                let bottomPercentage: Double = 50
                guard let mask = try await original.horizonMask(
                        at: frameIndex,
                        bottomPercentage: bottomPercentage,
                        useCannyEdgeDetection: config.useCannyForHorizonDetection,
                        cannyMinThreshold: config.cannyMinThreshold,
                        cannyMaxThreshold: config.cannyMaxThreshold,
                        useL2Gradient: config.cannyUseL2Gradient
                      )
                else {
                    throw "cannot create horizon mask"
                }
                horizonMask = mask
            }
        }

        Log.d("frame \(frameIndex) horizon mask image \(horizonMask.image) created")
        try await imageAccessor.save(
          horizonMask.image,
          frameIndex: frameIndex,
          as: .horizon,
          atSizes: await outputSizes,
          overwrite: true
        )

        await frame?.set(state: .horizonDetected)
        return horizonMask
    }

    /// Run horizon detection at reduced resolution with a two-pass parameter search,
    /// score each result, then apply the best parameters at full resolution.
    ///
    /// Pass 1: Coarse search across the full crop bounds range with horizonSearchCropCount1
    ///         steps, testing all strip width combinations.
    /// Pass 2: Refined search centered on the pass-1 best crop value, spanning one
    ///         pass-1 step in each direction, divided into horizonSearchCropCount2 steps.
    ///         Only the best strip width from pass 1 is used.
    private func adaptiveHorizonSearch(
      original: PixelatedImage,
      config: Config,
      adaptiveState: AdaptiveHorizonState
    ) async throws -> HorizonMask {
        let shrunkWidth = UInt(config.horizonSearchSize[0])
        let shrunkHeight = UInt(config.horizonSearchSize[1])

        // Step 1: Create reduced-resolution image for parameter search
        guard let shrunkImage = original.downScaleTo(
                width: shrunkWidth,
                height: shrunkHeight
              )
        else {
            Log.w("frame \(frameIndex) unable to downscale for adaptive horizon search, falling back")
            throw "cannot downscale image for adaptive horizon search"
        }

        // Pre-compute Canny edges on the shrunk image once for scoring all candidates.
        let shrunkEdgeImage: PixelatedImage? = try? shrunkImage.cannyEdgeDetect(
          minThreshold: config.cannyMinThreshold,
          maxThreshold: config.cannyMaxThreshold,
          useL2Gradient: config.cannyUseL2Gradient
        )

        // Step 2: Determine first-pass parameter search space.
        // After the first frame, narrow the bounds based on what worked before.
        let cropBounds: [Double] = await adaptiveState.narrowedCropBounds(
          defaults: config.horizonSearchCropBounds,
          narrowingRange: config.horizonSearchNarrowingRange
        )
        let pass1CropAmounts = HorizonCropAmounts.firstPass(
          bounds: cropBounds,
          count: config.horizonSearchCropCount1
        )
        let pass1Step = HorizonCropAmounts.firstPassStep(
          bounds: cropBounds,
          count: config.horizonSearchCropCount1
        )

        Log.i("frame \(frameIndex) adaptive horizon pass 1: " +
              "cropAmounts=\(pass1CropAmounts), ")

        // Step 3: Run first-pass combinations in parallel at reduced resolution
        let pass1Results = try await runScoredHorizonSearch(
          cropAmounts: pass1CropAmounts,
          shrunkImage: shrunkImage,
          shrunkEdgeImage: shrunkEdgeImage,
          shrunkWidth: shrunkWidth,
          config: config
        )

        // Tie-break on equal total score: prefer larger cropAmount (more conservative
        // sky crop). A larger crop is less likely to bite into the real horizon; when
        // the algorithm can't distinguish candidates by score it should stay safe.
        guard let pass1Best = pass1Results.max(by: {
            if $0.score.totalScore != $1.score.totalScore {
                return $0.score.totalScore < $1.score.totalScore
            }
            return $0.cropAmount < $1.cropAmount   // higher cropAmount wins
        })
        else {
            throw "adaptive horizon search pass 1 produced no valid results"
        }

        Log.i("frame \(frameIndex) pass 1 best: " +
              "cropAmount=\(pass1Best.cropAmount), " +
              "score=\(pass1Best.score)")

        for result in pass1Results.sorted(by: { $0.score.totalScore > $1.score.totalScore }) {
            Log.d("frame \(frameIndex) pass 1 result: " +
                  "crop=\(result.cropAmount)" +
                  "score=\(result.score)")
        }

        // Step 4: Second pass - refine the crop amount around the pass-1 best.
        // The search area spans one pass-1 step in each direction, divided into
        // horizonSearchCropCount2 evenly spaced values.
        // Strip width is fixed to the pass-1 best.
        let pass2CropAmounts = HorizonCropAmounts.secondPass(
          bestCrop: pass1Best.cropAmount,
          firstPassStep: pass1Step,
          count: config.horizonSearchCropCount2
        )

        Log.i("frame \(frameIndex) adaptive horizon pass 2: " +
              "cropAmounts=\(pass2CropAmounts)")

        let pass2Results = try await runScoredHorizonSearch(
          cropAmounts: pass2CropAmounts,
          shrunkImage: shrunkImage,
          shrunkEdgeImage: shrunkEdgeImage,
          shrunkWidth: shrunkWidth,
          config: config
        )

        // Same tie-break as pass 1: prefer larger cropAmount on equal scores.
        guard let pass2Best = pass2Results.max(by: {
            if $0.score.totalScore != $1.score.totalScore {
                return $0.score.totalScore < $1.score.totalScore
            }
            return $0.cropAmount < $1.cropAmount   // higher cropAmount wins
        })
        else {
            throw "adaptive horizon search pass 2 produced no valid results"
        }

        Log.i("frame \(frameIndex) pass 2 best: " +
              "cropAmount=\(pass2Best.cropAmount), " +
              "score=\(pass2Best.score)")

        for result in pass2Results.sorted(by: { $0.score.totalScore > $1.score.totalScore }) {
            Log.d("frame \(frameIndex) pass 2 result: " +
                  "crop=\(result.cropAmount)," +
                  "score=\(result.score)")
        }

        // Step 5: DP grid search on the shrunk image (if enabled).
        // Run DP across all combinations of smoothnessLambda, sobelWeight, cannyWeight
        // defined by the range+count config parameters. Each candidate is scored on the
        // shrunk image using the same pre-computed Canny edge image used for Otsu scoring,
        // so all candidates (Otsu and DP) are comparable on equal footing.
        //
        var dpBestShrunkResult: HorizonSearchResult? = nil


        let dpSearchTop    = pass2Best.cropAmount/100
        let dpSearchBottom = 1.0

        let lambdaValues = config.dpHorizonSmoothnessLambdaValues
        let sobelValues  = config.dpHorizonSobelWeightValues
        let cannyValues  = config.dpHorizonCannyWeightValues
        let dpTotal      = lambdaValues.count * sobelValues.count * cannyValues.count

        Log.i("frame \(frameIndex) DP shrunk-image grid: " +
                "\(dpTotal) combinations " +
                "(lambda×\(lambdaValues.count), sobel×\(sobelValues.count), canny×\(cannyValues.count)), " +
                "search \(String(format:"%.0f",dpSearchTop*100))%–" +
                "\(String(format:"%.0f",dpSearchBottom*100))% of image height")

        // Run all DP combinations in parallel on the shrunk image.
        struct DPShrunkResult {
            let mask: HorizonMask
            let lambda: Double
            let sobelW: Double
            let cannyW: Double
        }

        let dpShrunkResults: [DPShrunkResult] = try await withThrowingTaskGroup(
          of: DPShrunkResult?.self
        ) { taskGroup in
            for lambda in lambdaValues {
                for sobelW in sobelValues {
                    for cannyW in cannyValues {
                        taskGroup.addTask { [frameIndex] in
                            guard let mask = try? await shrunkImage.dpHorizonMask(
                                    at: frameIndex,
                                    searchTopFraction: dpSearchTop,
                                    searchBottomFraction: dpSearchBottom,
                                    cannyMinThreshold: config.cannyMinThreshold,
                                    cannyMaxThreshold: config.cannyMaxThreshold,
                                    useL2Gradient: config.cannyUseL2Gradient,
                                    smoothnessLambda: lambda,
                                    sobelWeight: sobelW,
                                    cannyWeight: cannyW
                                  )
                            else { return nil }
                            return DPShrunkResult(mask: mask, lambda: lambda,
                                                  sobelW: sobelW, cannyW: cannyW)
                        }
                    }
                }
            }
            var results: [DPShrunkResult] = []
            for try await result in taskGroup {
                if let r = result { results.append(r) }
            }
            return results
        }

        // Score each DP shrunk result and find the best.
        for dpResult in dpShrunkResults {
            let score: HorizonScore
            if let edges = shrunkEdgeImage {
                score = HorizonScoring.score(horizonMask: dpResult.mask, edgeImage: edges)
            } else {
                score = HorizonScoring.score(
                  horizonMask: dpResult.mask,
                  originalImage: shrunkImage,
                  cannyMinThreshold: config.cannyMinThreshold,
                  cannyMaxThreshold: config.cannyMaxThreshold,
                  useL2Gradient: config.cannyUseL2Gradient
                )
            }
            Log.d("frame \(frameIndex) DP shrunk score=\(score) " +
                    "lambda=\(dpResult.lambda) sobel=\(dpResult.sobelW) canny=\(dpResult.cannyW)")

            // Store as a HorizonSearchResult using cropAmount=-1 as a sentinel
            // (DP doesn't have a crop amount; the sentinel is only used for logging).
            let candidate = HorizonSearchResult(
              cropAmount: -1, 
              horizonMask: dpResult.mask, score: score,
              lambda: dpResult.lambda, sobelW: dpResult.sobelW, cannyW: dpResult.cannyW
            )
            if let current = dpBestShrunkResult {
                if score.totalScore > current.score.totalScore {
                    dpBestShrunkResult = candidate
                }
            } else {
                dpBestShrunkResult = candidate
            }
        }

        if let best = dpBestShrunkResult {
            Log.i("frame \(frameIndex) DP shrunk best score=\(best.score) " +
                    "lambda=\(best.lambda ?? -1) sobel=\(best.sobelW ?? -1) " +
                    "canny=\(best.cannyW ?? -1)")
        } else {
            Log.w("frame \(frameIndex) DP shrunk grid produced no valid results")
        }


        // Step 6: Run BOTH Otsu and DP at full and shrunk resolutions,
        // then combine and score all of them.
        //
        // We always generate:
        //   (a) otsuMask   — Otsu + Canny at full res with pass-2 best parameters
        //   (b) shrunkOtsu — Otsu + Canny at smaller res with pass-2 best parameters
        //   (c) dpMask     — DP at full res with shrunk-grid-best parameters (if enabled)
        //   (d) shrunkDp   — DP at shrunk res with shrunk-grid-best parameters (if enabled)
        //
        // Each of the four is scored independently; the highest-scoring one is returned.
        // When DP is disabled only (a) is produced.

        // --- 6d: DP at smaller resolution ---
        if let dpBest = dpBestShrunkResult,
           let lambda = dpBest.lambda,
           let sobelW = dpBest.sobelW,
           let cannyW = dpBest.cannyW
        {
            let dpSearchTop    = pass2Best.cropAmount / 100.0
            let dpSearchBottom = 1.0

            Log.i("frame \(frameIndex) running DP at smaller resolution: " +
                  "lambda=\(lambda), sobel=\(sobelW), canny=\(cannyW), " +
                  "search \(String(format:"%.0f",dpSearchTop*100))%–" +
                  "\(String(format:"%.0f",dpSearchBottom*100))%")

            if let ogdpShrunkMask = try? await shrunkImage.dpHorizonMask(
                 at: frameIndex,
                 searchTopFraction: dpSearchTop,
                 searchBottomFraction: dpSearchBottom,
                 cannyMinThreshold: config.cannyMinThreshold,
                 cannyMaxThreshold: config.cannyMaxThreshold,
                 useL2Gradient: config.cannyUseL2Gradient,
                 smoothnessLambda: lambda,
                 sobelWeight: sobelW,
                 cannyWeight: cannyW
               )
            {
                // re-scale it back up
                let dpFullResMask = HorizonMask(
                  image: ogdpShrunkMask.image
                    .upScaleTo(
                      width: UInt(original.width),
                      height: UInt(original.height)
                    )!,
                  horizonTopY: ogdpShrunkMask.horizonTopY,
                  horizonBottomY: ogdpShrunkMask.horizonBottomY
                )
                let dpFullResScore: HorizonScore
/*
                if let edges = shrunkEdgeImage {
                    dpFullResScore = HorizonScoring.score(
                      horizonMask: dpFullResMask,
                      edgeImage: edges
                    )
                } else {*/
                    dpFullResScore = HorizonScoring.score(
                      horizonMask: dpFullResMask,
                      originalImage: original,
                      cannyMinThreshold: config.cannyMinThreshold,
                      cannyMaxThreshold: config.cannyMaxThreshold,
                      useL2Gradient: config.cannyUseL2Gradient
                    )
//                }
                Log.i("frame \(frameIndex) DP full resolution score=\(dpFullResScore)")


                let bestMask   = dpFullResMask
                let bestScore  = dpFullResScore
                let bestMethod = "shrunkDp"


                Log.i("frame \(frameIndex) final horizon method=\(bestMethod), score=\(bestScore)")

                // Step 7: Record the best parameters for narrowing subsequent frames
                await adaptiveState.recordBest(
                  cropAmount: pass2Best.cropAmount,
                  firstPassStep: pass1Step
                )

                return bestMask
                
            }
        }

        // --- 6b: Otsu at shrunk resolution

        guard let ogShrunkOtsuMask = try await shrunkImage.horizonMask(
                at: frameIndex,
                bottomPercentage: pass2Best.cropAmount,
                useCannyEdgeDetection: config.useCannyForHorizonDetection,
                cannyMinThreshold: config.cannyMinThreshold,
                cannyMaxThreshold: config.cannyMaxThreshold,
                useL2Gradient: config.cannyUseL2Gradient
              )
        else {
            throw "cannot create full resolution Otsu horizon mask"
        }

        // re-scale it back up
        let shrunkOtsuMask = HorizonMask(
          image: ogShrunkOtsuMask.image
            .upScaleTo(
              width: UInt(original.width),
              height: UInt(original.height)
            )!,
          horizonTopY: ogShrunkOtsuMask.horizonTopY,
          horizonBottomY: ogShrunkOtsuMask.horizonBottomY
        )
        
        let shrunkResCropBoundaryY = Int(Double(shrunkImage.height) * pass2Best.cropAmount / 100)
        /*
         if let edges = shrunkEdgeImage {
         shrunkOtsuScore = HorizonScoring.score(
         horizonMask: shrunkOtsuMask,
         edgeImage: edges,
         cropBoundaryY: shrunkResCropBoundaryY
         )
         } else {*/

        let shrunkOtsuScore = HorizonScoring.score(
          horizonMask: shrunkOtsuMask,
          originalImage: shrunkImage,
          cannyMinThreshold: config.cannyMinThreshold,
          cannyMaxThreshold: config.cannyMaxThreshold,
          useL2Gradient: config.cannyUseL2Gradient,
          cropBoundaryY: shrunkResCropBoundaryY
        )
        //        }
        Log.i("frame \(frameIndex) Otsu full resolution score=\(shrunkOtsuScore)")

        // Step 7: Record the best parameters for narrowing subsequent frames
        await adaptiveState.recordBest(
          cropAmount: pass2Best.cropAmount,
          firstPassStep: pass1Step
        )

        return shrunkOtsuMask
        
    }

    /// Run horizon detection and scoring for all combinations of crop amounts and
    /// strip widths on a reduced-resolution image. Returns scored results.
    ///
    /// Strip width handling:
    /// - A value of 0 means "full image width" and is always kept as-is.
    /// - Other values are scaled down by shrinkFactor for the reduced-res search,
    ///   with a minimum of 20 pixels at reduced resolution.
    /// - To ensure different full-res strip widths produce meaningfully different
    ///   reduced-res strip widths, we deduplicate shrunk widths. When multiple
    ///   full-res values map to the same shrunk width, we keep only the largest
    ///   full-res value (since it will produce the same reduced-res result but
    ///   will perform better at full resolution).
    private func runScoredHorizonSearch(
      cropAmounts: [Double],
      shrunkImage: PixelatedImage,
      shrunkEdgeImage: PixelatedImage?,
      shrunkWidth: UInt,
      config: Config
    ) async throws -> [HorizonSearchResult] {
        // Deduplicate: when multiple full-res widths map to the same shrunk width,
        // keep only the largest full-res width (it produces the same reduced-res
        // result but will work better at full resolution).
        // The special value 0 (full width) is always kept as a separate entry.

        return try await withThrowingTaskGroup(
          of: Optional<HorizonSearchResult>.self
        ) { taskGroup in
            for cropAmount in cropAmounts {
                taskGroup.addTask { [frameIndex] in
                    if let mask = try await shrunkImage.horizonMask(
                            at: frameIndex,
                            bottomPercentage: cropAmount,
                            useCannyEdgeDetection: config.useCannyForHorizonDetection,
                            cannyMinThreshold: config.cannyMinThreshold,
                            cannyMaxThreshold: config.cannyMaxThreshold,
                            useL2Gradient: config.cannyUseL2Gradient
                          )
                    {

                        // The crop boundary is the first row of the cropped region
                        // in the mask's coordinate space.  The mask has the same
                        // height as the shrunk image; the top `cropAmount`% rows
                        // were assumed to be sky and were filled white (not processed
                        // by Otsu). The boundary between assumed-sky and the Otsu
                        // region sits at this Y coordinate.
                        let shrunkCropBoundaryY = Int(Double(shrunkImage.height) * cropAmount / 100.0)

                        let score: HorizonScore
                        if let edges = shrunkEdgeImage {
                            score = HorizonScoring.score(
                              horizonMask: mask,
                              edgeImage: edges,
                              cropBoundaryY: shrunkCropBoundaryY
                            )
                        } else {
                            score = HorizonScoring.score(
                              horizonMask: mask,
                              originalImage: shrunkImage,
                              cannyMinThreshold: config.cannyMinThreshold,
                              cannyMaxThreshold: config.cannyMaxThreshold,
                              useL2Gradient: config.cannyUseL2Gradient,
                              cropBoundaryY: shrunkCropBoundaryY
                            )
                        }

                        return HorizonSearchResult(
                          cropAmount: cropAmount,
                          horizonMask: mask,
                          score: score
                        )
                    }
                    return nil
                }
            }

            var results: [HorizonSearchResult] = []
            for try await result in taskGroup {
                if let result { results.append(result) }
            }
            return results
        }
    }
    public func deleteHorizonImages() {
        try? self.imageAccessor.deleteImage(
          frameIndex: self.frameIndex,
          ofType: .horizon,
          atSize: .preview
        )
        try? self.imageAccessor.deleteImage(
          frameIndex: self.frameIndex,
          ofType: .horizon,
          atSize: .original
        )
        try? self.imageAccessor.deleteImage(
          frameIndex: self.frameIndex,
          ofType: .mergedHorizon,
          atSize: .preview
        )
        try? self.imageAccessor.deleteImage(
          frameIndex: self.frameIndex,
          ofType: .mergedHorizon,
          atSize: .original
        )

    }

}
