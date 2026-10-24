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
/// Typed `.alignmentValidation`, like the op it follows: it is a sequence-wide step between
/// the per-frame ones, which the progress display does not break out (`ProcessingSteps`),
/// and a step of its own there would reach the daemon's protocol for no gain.
final class HorizonConsensusOp: AsyncOperation, @unchecked Sendable {
    /// The whole sequence: every frame's detection votes, not only the ones being written.
    let frames: [FrameAirplaneRemover]
    /// The frames to write a consensus line for.
    let targets: [Int]
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
      configManager: ConfigManager,
      rawImageBytes: UInt64,
      parameters: HorizonConsensus.Parameters = HorizonConsensus.Parameters(),
      errorClosure: @escaping (String) -> Void
    ) {
        self.frames = frames.sorted { $0.frameIndex < $1.frameIndex }
        self.targets = targets.sorted()
        self.configManager = configManager
        self.parameters = parameters
        self.errorClosure = errorClosure
        super.init(for: .alignmentValidation, rawImageBytes: rawImageBytes,
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
        guard let firstFrame = frames.first, !targets.isEmpty else { return }
        let started = Date()
        let config = await configManager.config()
        let width = firstFrame.width, height = firstFrame.height

        // Which frames' detections are needed: the voters within reach of a target, and the
        // targets themselves.  Voters sit on a grid anchored on the sequence's first frame,
        // so the same frames vote whichever part of the sequence is being written.
        let origin = firstFrame.frameIndex
        let stride = max(1, parameters.neighbourStride)
        let low = (targets.first ?? origin) - parameters.longSpan
        let high = (targets.last ?? origin) + parameters.longSpan
        let wanted = Set(targets)
        let sources = frames.filter { frame in
            let index = frame.frameIndex
            return wanted.contains(index)
              || (index >= low && index <= high && (index - origin) % stride == 0)
        }

        let lines = try await detectedLines(of: sources, height: height)
        try Task.checkCancellation()
        let records = await groundFits(of: sources)
        try Task.checkCancellation()

        let targets = self.targets
        let parameters = self.parameters
        let outcome = await NativeWork.run {
            HorizonConsensus.run(lines: lines, similarityRecords: records, targets: targets,
                                 width: width, height: height, voterOrigin: origin,
                                 parameters: parameters)
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
              "as no camera rotation; the long span overrode " +
              String(format: "%.2f", overridden) + "% of columns; in " +
              String(format: "%.1f", Date().timeIntervalSince(started)) + "s")
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
