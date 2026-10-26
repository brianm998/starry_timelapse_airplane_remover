import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// A moving sequence's horizons from every frame's detection, carried along the ground —
/// see `HorizonConsensus`.  One op for the sequence, after alignment validation (it needs
/// the ground homographies that leaves behind) and before anything composites with a
/// horizon: the outlier subtraction and the merge.
///
/// A step of its own (`OperationType.horizonConsensus`), with its own row in the progress
/// display: one op for the sequence, as a static tripod's horizon merge is.
///
/// Every line it writes is also drawn as a `.consensusHorizon` mask, so the consensus can
/// be looked at like the other horizons.  A frame whose line an earlier run wrote but never
/// drew (`imageTargets`) only has its drawing made.
final class HorizonConsensusOp: AsyncOperation, @unchecked Sendable {
    /// The whole sequence: every frame's detection votes, not only the ones being written.
    let frames: [FrameAirplaneRemover]
    /// The frames to write a consensus line for.
    let targets: [Int]
    /// Frames that have a line on disk and no `.consensusHorizon` image of it.
    let imageTargets: [Int]
    let configManager: ConfigManager
    let parameters: HorizonConsensus.Parameters
    let errorClosure: (String) -> Void

    /// Masks decoded at once.  Each is a full-resolution 8-bit plane until its line is read
    /// out of it; reads are paced per volume by `IOWork` regardless.
    static let concurrentDecodes = 4

    /// The lines, the chains and the per-target vote are small next to a frame; the
    /// reservation covers the masks being decoded.
    static let memoryMultiplier: UInt64 = 2

    init(
      frames: [FrameAirplaneRemover],
      targets: [Int],
      imageTargets: [Int] = [],
      configManager: ConfigManager,
      rawImageBytes: UInt64,
      parameters: HorizonConsensus.Parameters = HorizonConsensus.Parameters(),
      errorClosure: @escaping (String) -> Void
    ) {
        self.frames = frames.sorted { $0.frameIndex < $1.frameIndex }
        self.targets = targets.sorted()
        self.imageTargets = imageTargets.sorted()
        self.configManager = configManager
        self.parameters = parameters
        self.errorClosure = errorClosure
        super.init(for: .horizonConsensus, rawImageBytes: rawImageBytes,
                   memoryMultiplier: Self.memoryMultiplier)
        self.name = "horizon consensus"
    }

    override func asyncExecute() async {
        do {
            try await run()
        } catch is CancellationError {
            Log.d("horizon consensus cancelled")
        } catch {
            // Not fatal: without a consensus line each frame composites with its merged
            // mask, which is what every run did before this existed.
            let message = "horizon consensus failed, keeping the merged horizons: \(error)"
            Log.e(message)
            errorClosure(message)
        }
    }

    func run() async throws {
        if !targets.isEmpty { try await buildLines() }
        try Task.checkCancellation()
        try await drawLines(of: Set(targets).union(imageTargets).sorted())
    }

    private func buildLines() async throws {
        guard let firstFrame = frames.first, !targets.isEmpty else { return }
        let started = Date()
        let config = await configManager.config()
        let width = firstFrame.width, height = firstFrame.height

        // Which frames' detections are needed: the voters within reach of a target, and the
        // targets and the frames around them.  Voters sit on a grid anchored on the sequence's first frame,
        // so the same frames vote whichever part of the sequence is being written.
        let origin = firstFrame.frameIndex
        let stride = max(1, parameters.neighbourStride)
        let low = (targets.first ?? origin) - parameters.longSpan
        let high = (targets.last ?? origin) + parameters.longSpan
        // A target's line is averaged with its neighbours' (`temporalSmoothingRadius`), so
        // their detections are needed too.
        let radius = max(0, parameters.temporalSmoothingRadius)
        var wanted = Set<Int>()
        for target in targets {
            for index in (target - radius)...(target + radius) { wanted.insert(index) }
        }
        let sources = frames.filter { frame in
            let index = frame.frameIndex
            return wanted.contains(index)
              || (index >= low && index <= high && (index - origin) % stride == 0)
        }

        // The user's painted horizons within reach anchor the lines (`HorizonConsensus`
        // step 5); each needs its own frame's detection too, to measure the consensus there.
        let inReach = frames.filter { $0.frameIndex >= low && $0.frameIndex <= high }
        let references = try await paintedReferences(of: inReach, height: height)
        let sourceIndices = Set(sources.map(\.frameIndex))
        let allSources = sources + inReach.filter {
            references[$0.frameIndex] != nil && !sourceIndices.contains($0.frameIndex)
        }

        let lines = try await detectedLines(of: allSources, height: height)
        try Task.checkCancellation()
        let records = await groundFits(of: allSources)
        try Task.checkCancellation()

        let targets = self.targets
        let parameters = self.parameters
        let outcome = await NativeWork.run {
            HorizonConsensus.run(lines: lines, similarityRecords: records, targets: targets,
                                 width: width, height: height, voterOrigin: origin,
                                 references: references, parameters: parameters)
        }
        guard let outcome else {
            Log.w("horizon consensus: could not calibrate the ground rotations from " +
                  "\(lines.count) detections and \(records.count) ground records — keeping " +
                  "the merged horizons")
            return
        }

        for (frameIndex, line) in outcome.lines {
            try HorizonConsensusStore.write(line: line, frameIndex: frameIndex,
                                            width: width, height: height, config: config)
        }
        try HorizonConsensusStore.writeCalibration(outcome.calibration, config: config)

        // A final mask cached before this ran (validation reads one for its sky crops) is the
        // merged one; let the next reader build it from the consensus.
        for frame in frames where outcome.lines[frame.frameIndex] != nil {
            await frame.horizonProcessor.releaseCachedFinalHorizonMask()
        }

        let calibration = outcome.calibration
        let overridden = outcome.columns > 0
          ? 100 * Double(outcome.overriddenColumns) / Double(outcome.columns) : 0
        Log.i("horizon consensus: \(outcome.lines.count) of \(self.targets.count) frames from " +
              "\(lines.count) detections; focal length \(Int(calibration.focalLength)) px " +
              "(lines carried \(calibration.distance) frames land " +
              String(format: "%.3f", calibration.drift * 100) + "% of the height off), " +
              "\(calibration.rejectedEntries) of \(calibration.entries) ground fits left out " +
              "as no camera rotation; \(references.count) painted horizon(s) in reach, " +
              "\(outcome.paintedTargets) frame(s) painted, \(outcome.correctedTargets) " +
              "corrected by them; " +
              "the long span overrode " +
              String(format: "%.2f", overridden) + "% of columns; in " +
              String(format: "%.1f", Date().timeIntervalSince(started)) + "s")
    }

    /// Write the `.consensusHorizon` image of each of `frameIndices`' lines, for the view
    /// modes.  A frame that got no line (it could not be calibrated) simply has none.
    private func drawLines(of frameIndices: [Int]) async throws {
        let byIndex = Dictionary(frames.map { ($0.frameIndex, $0) },
                                 uniquingKeysWith: { first, _ in first })
        var pending = frameIndices.compactMap { byIndex[$0] }[...]
        guard !pending.isEmpty else { return }
        var drawn = 0
        try await withThrowingTaskGroup(of: Bool.self) { group in
            func addNext() {
                guard let frame = pending.popFirst() else { return }
                group.addTask { await frame.horizonProcessor.saveHorizonConsensusImage() }
            }
            for _ in 0..<Self.concurrentDecodes { addNext() }
            while let saved = try await group.next() {
                try Task.checkCancellation()
                if saved { drawn += 1 }
                addNext()
            }
        }
        Log.i("horizon consensus: drew \(drawn) line(s) as horizon consensus images")
    }

    /// The user's own painted horizon of each of `frames` that has one, as a grid line.
    private func paintedReferences(of frames: [FrameAirplaneRemover],
                                   height: Int) async throws -> [Int: [Float]] {
        let gridWidth = parameters.gridWidth
        var references: [Int: [Float]] = [:]
        try await withThrowingTaskGroup(of: (Int, [Float]?).self) { group in
            var pending = frames[...]
            func addNext() {
                guard let frame = pending.popFirst() else { return }
                group.addTask {
                    guard let columns = await frame.horizonProcessor.paintedReferenceColumns()
                    else { return (frame.frameIndex, nil) }
                    return (frame.frameIndex,
                            HorizonConsensus.gridLine(fromColumns: columns, height: height,
                                                      gridWidth: gridWidth))
                }
            }
            for _ in 0..<Self.concurrentDecodes { addNext() }
            while let (frameIndex, line) = try await group.next() {
                try Task.checkCancellation()
                if let line { references[frameIndex] = line }
                addNext()
            }
        }
        return references
    }

    /// Each frame's detected horizon, as a grid line, for the frames whose first-round mask
    /// is on disk.  A frame without one simply does not vote.
    private func detectedLines(of frames: [FrameAirplaneRemover],
                               height: Int) async throws -> [Int: [Float]] {
        let gridWidth = parameters.gridWidth
        var lines: [Int: [Float]] = [:]
        try await withThrowingTaskGroup(of: (Int, [Float]?).self) { group in
            var pending = frames[...]
            func addNext() {
                guard let frame = pending.popFirst() else { return }
                group.addTask {
                    guard frame.horizonMaskExistsOnDisk(),
                          let mask = try await frame.imageAccessor.load(
                            frameIndex: frame.frameIndex, type: .horizon, atSize: .original)
                    else { return (frame.frameIndex, nil) }
                    let line = await NativeWork.run {
                        HorizonConsensus.gridLine(
                          fromColumns: CombinedHorizonDetector.extractHorizonY(from: mask),
                          height: height, gridWidth: gridWidth)
                    }
                    return (frame.frameIndex, line)
                }
            }
            for _ in 0..<Self.concurrentDecodes { addNext() }
            while let (frameIndex, line) = try await group.next() {
                try Task.checkCancellation()
                if let line { lines[frameIndex] = line }
                addNext()
            }
        }
        return lines
    }

    /// Every usable stored ground fit among `frames`: frame index → neighbour index → the
    /// row-major 3x3 carrying the neighbour into the frame.  What validation left in memory
    /// first, since its corrections reach the database asynchronously; the database for a
    /// frame this session never aligned.
    private func groundFits(of frames: [FrameAirplaneRemover]) async -> [Int: [Int: [Double]]] {
        let database = configManager.homographyDatabase
        var records: [Int: [Int: [Double]]] = [:]
        for frame in frames {
            var results = await frame.getNeighborEarthHomography()
            if results == nil {
                results = try? await database.read(frameIndex: frame.frameIndex, type: .earth)
            }
            guard let results else { continue }
            var row: [Int: [Double]] = [:]
            for warp in results.neighborHomography {
                guard let homography = warp.homography, homography.count == 9 else { continue }
                switch warp.alignmentState {
                case .homographySuccess, .usedExistingHomography:
                    row[warp.frameIndex] = homography
                default:
                    continue
                }
            }
            if !row.isEmpty { records[frame.frameIndex] = row }
        }
        return records
    }
}
