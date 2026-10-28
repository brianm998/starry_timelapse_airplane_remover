import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// One frame's horizon consensus line — see `HorizonConsensus` — written and drawn as a
/// `.consensusHorizon` mask, after alignment validation (it needs the ground homographies
/// that leaves behind) and before the frame's outlier subtraction and merge, which
/// composite with it.
///
/// One op per frame, so the step counts frames in the progress display like the others,
/// and so a frame's outliers and merge can start as soon as its own line is written instead
/// of waiting for every frame's.  Nothing a frame composites with reads another frame's
/// consensus line: the earth-aligned merge warps its neighbours by their first-round
/// detections.
///
/// What every frame's line is built from — every detection in reach, the ground fits, the
/// calibrated focal length — is gathered once for the sequence by the `HorizonConsensusBuild`
/// the ops share, by whichever op asks first; the rest wait on it.  The ops of a graph
/// depend on one barrier rather than on every horizon op each (`inputsReady`), which keeps
/// the dependency count linear in the sequence.
///
/// An op without a build only draws its frame's line: one an earlier run wrote but never
/// drew (`imageTargets`).
final class HorizonConsensusOp: AsyncOperation, @unchecked Sendable {
    let frame: FrameAirplaneRemover
    /// Nil for a frame whose line is already written and only needs drawing.
    let build: HorizonConsensusBuild?
    let rawImageBytes: UInt64
    let errorClosure: (String) -> Void

    init(
      frame: FrameAirplaneRemover,
      build: HorizonConsensusBuild?,
      rawImageBytes: UInt64,
      errorClosure: @escaping (String) -> Void
    ) {
        self.frame = frame
        self.build = build
        self.rawImageBytes = rawImageBytes
        self.errorClosure = errorClosure
        // No reservation for the op as a whole: every op of the sequence waits on the shared
        // build while it gathers its inputs, and holding a frame's worth each while they did
        // would starve everything else of budget for nothing.  The build and the drawing
        // reserve what they decode, while they decode it.
        super.init(for: .horizonConsensus)
        self.name = "horizon consensus frame \(frame.frameIndex)"
    }

    /// One op per frame of `targets` (built and drawn) and of `imageTargets` (only drawn),
    /// in frame order, sharing one build over `frames` — the whole sequence, since every
    /// frame's detection votes, not only the ones being written.
    static func ops(
      frames: [FrameAirplaneRemover],
      targets: [Int],
      imageTargets: [Int] = [],
      configManager: ConfigManager,
      rawImageBytes: UInt64,
      parameters: HorizonConsensus.Parameters = HorizonConsensus.Parameters(),
      errorClosure: @escaping @Sendable (String) -> Void
    ) -> [HorizonConsensusOp] {
        let build = targets.isEmpty ? nil : HorizonConsensusBuild(
          frames: frames, targets: targets, configManager: configManager,
          rawImageBytes: rawImageBytes, parameters: parameters, errorClosure: errorClosure)
        let byIndex = Dictionary(frames.map { ($0.frameIndex, $0) },
                                 uniquingKeysWith: { first, _ in first })
        let built = Set(targets)
        return built.union(imageTargets).sorted().compactMap { frameIndex in
            guard let frame = byIndex[frameIndex] else { return nil }
            return HorizonConsensusOp(frame: frame,
                                      build: built.contains(frameIndex) ? build : nil,
                                      rawImageBytes: rawImageBytes,
                                      errorClosure: errorClosure)
        }
    }

    override func cancel() {
        super.cancel()
        // Only a whole graph is ever cancelled, so the build no other op will want either.
        if let build { Task { await build.cancel() } }
    }

    override func asyncExecute() async {
        do {
            try await run()
        } catch is CancellationError {
            Log.d("horizon consensus of frame \(frame.frameIndex) cancelled")
        } catch {
            // Not fatal: without a consensus line the frame composites with its merged
            // mask, which is what every run did before this existed.
            let message = "horizon consensus of frame \(frame.frameIndex) failed, keeping " +
              "its merged horizon: \(error)"
            Log.e(message)
            errorClosure(message)
        }
    }

    func run() async throws {
        if let build {
            guard try await build.writeLine(of: frame) else { return }
        }
        try Task.checkCancellation()
        // The mask drawn from the line, full size, and its smaller sizes.
        let bytes = UInt64(frame.width * frame.height) * 2
        await MemoryMonitor.shared.reserve(bytes: bytes)
        _ = await frame.horizonProcessor.saveHorizonConsensusImage()
        await MemoryMonitor.shared.release(bytes: bytes)
    }
}

/// The sequence-wide half of the horizon consensus, shared by one graph's
/// `HorizonConsensusOp`s: the detections, painted references and ground fits in reach of
/// the frames being written, prepared once (`HorizonConsensus.prepare`), and then each
/// frame's line on request.
///
/// A frame's line is the mean of its neighbours' unsmoothed lines
/// (`Parameters.temporalSmoothingRadius`), so those are kept as they are built, for the
/// neighbours that ask next; each is a few hundred floats.
actor HorizonConsensusBuild {
    /// The whole sequence: every frame's detection votes, not only the ones being written.
    let frames: [FrameAirplaneRemover]
    /// The frames to write a consensus line for.
    let targets: [Int]
    let configManager: ConfigManager
    let rawImageBytes: UInt64
    let parameters: HorizonConsensus.Parameters
    let errorClosure: @Sendable (String) -> Void

    /// Masks decoded at once while gathering the detections.  Each is a full-resolution
    /// 8-bit plane until its line is read out of it; reads are paced per volume by `IOWork`
    /// regardless.
    static let concurrentDecodes = 4

    /// What the decodes above hold at once, in frames: the lines, the chains and the votes
    /// are small next to them.
    static let memoryMultiplier: UInt64 = 2

    private struct Preparation: Sendable {
        let prepared: HorizonConsensus.Prepared
        let config: Config
    }

    private var preparation: Task<Preparation?, Error>?
    private var unsmoothed: [Int: Task<HorizonConsensus.Prepared.Unsmoothed?, Never>] = [:]
    private var cancelled = false

    // for the summary logged once every target has been asked for
    private var started: Date?
    private var answered = 0
    private var written = 0
    private var overriddenColumns = 0
    private var corrected = 0
    private var painted = 0

    init(
      frames: [FrameAirplaneRemover],
      targets: [Int],
      configManager: ConfigManager,
      rawImageBytes: UInt64,
      parameters: HorizonConsensus.Parameters = HorizonConsensus.Parameters(),
      errorClosure: @escaping @Sendable (String) -> Void
    ) {
        self.frames = frames.sorted { $0.frameIndex < $1.frameIndex }
        self.targets = targets.sorted()
        self.configManager = configManager
        self.rawImageBytes = rawImageBytes
        self.parameters = parameters
        self.errorClosure = errorClosure
    }

    func cancel() {
        cancelled = true
        preparation?.cancel()
    }

    /// Build `frame`'s consensus line and write it.  False when it has none: the
    /// sequence could not be calibrated, or the frame has no detection of its own.
    func writeLine(of frame: FrameAirplaneRemover) async throws -> Bool {
        guard let preparation = try await prepared() else {
            answer(nil, of: frame.frameIndex, prepared: nil)
            return false
        }
        let prepared = preparation.prepared
        let target = frame.frameIndex
        var lines: [Int: [Float]] = [:]
        var own: HorizonConsensus.Prepared.Unsmoothed?
        for source in prepared.smoothingSources(of: target) {
            guard let result = await unsmoothedLine(of: source, prepared) else { continue }
            lines[source] = result.line
            if source == target { own = result }
        }
        try Task.checkCancellation()
        let sources = lines
        let line = await NativeWork.run { prepared.smoothed(target, unsmoothed: sources) }
        guard let line else {
            answer(nil, of: target, prepared: prepared)
            return false
        }
        try HorizonConsensusStore.write(line: line, frameIndex: target,
                                        width: prepared.width, height: prepared.height,
                                        config: preparation.config)
        // A final mask cached before this ran (validation reads one for its sky crops) is the
        // merged one; let the next reader build it from the consensus.
        await frame.horizonProcessor.releaseCachedFinalHorizonMask()
        answer(own, of: target, prepared: prepared)
        return true
    }

    private func unsmoothedLine(
      of frame: Int,
      _ prepared: HorizonConsensus.Prepared
    ) async -> HorizonConsensus.Prepared.Unsmoothed? {
        if let existing = unsmoothed[frame] { return await existing.value }
        let task = Task { await NativeWork.run { prepared.unsmoothed(frame) } }
        unsmoothed[frame] = task
        return await task.value
    }

    /// The sequence's preparation, made by the first caller and shared with the rest.
    /// Nil when it could not be calibrated or failed, which is reported once, here.
    private func prepared() async throws -> Preparation? {
        if cancelled { throw CancellationError() }
        if preparation == nil {
            started = Date()
            preparation = Task { try await prepare() }
        }
        do {
            return try await preparation?.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// Record one target's answer, and log the summary once every target has one.
    private func answer(_ result: HorizonConsensus.Prepared.Unsmoothed?, of target: Int,
                        prepared: HorizonConsensus.Prepared?) {
        answered += 1
        if let result {
            written += 1
            overriddenColumns += result.overridden
            if result.corrected { corrected += 1 }
            if prepared?.isPainted(target) == true { painted += 1 }
        }
        guard answered == targets.count, let prepared, let started else { return }
        let calibration = prepared.calibration
        let columns = written * parameters.gridWidth
        let overridden = columns > 0 ? 100 * Double(overriddenColumns) / Double(columns) : 0
        Log.i("horizon consensus: \(written) of \(targets.count) frames from " +
              "\(prepared.detections) detections; focal length \(Int(calibration.focalLength)) px " +
              "(lines carried \(calibration.distance) frames land " +
              String(format: "%.3f", calibration.drift * 100) + "% of the height off), " +
              "\(calibration.rejectedEntries) of \(calibration.entries) ground fits left out " +
              "as no camera rotation; \(prepared.paintedReferences) painted horizon(s) in reach, " +
              "\(painted) frame(s) painted, \(corrected) corrected by them; " +
              "the long span overrode " +
              String(format: "%.2f", overridden) + "% of columns; in " +
              String(format: "%.1f", Date().timeIntervalSince(started)) + "s")
    }

    private func prepare() async throws -> Preparation? {
        let bytes = rawImageBytes * Self.memoryMultiplier
        if bytes > 0 { await MemoryMonitor.shared.reserve(bytes: bytes) }
        let result: Result<Preparation?, Error>
        do {
            result = .success(try await gatherAndPrepare())
        } catch {
            result = .failure(error)
        }
        if bytes > 0 { await MemoryMonitor.shared.release(bytes: bytes) }
        do {
            return try result.get()
        } catch is CancellationError {
            Log.d("horizon consensus cancelled")
            throw CancellationError()
        } catch {
            let message = "horizon consensus failed, keeping the merged horizons: \(error)"
            Log.e(message)
            errorClosure(message)
            throw error
        }
    }

    private func gatherAndPrepare() async throws -> Preparation? {
        guard let firstFrame = frames.first, !targets.isEmpty else { return nil }
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
        let prepared = await NativeWork.run {
            HorizonConsensus.prepare(lines: lines, similarityRecords: records, targets: targets,
                                     width: width, height: height, voterOrigin: origin,
                                     references: references, parameters: parameters)
        }
        guard let prepared else {
            Log.w("horizon consensus: could not calibrate the ground rotations from " +
                  "\(lines.count) detections and \(records.count) ground records — keeping " +
                  "the merged horizons")
            return nil
        }
        try HorizonConsensusStore.writeCalibration(prepared.calibration, config: config)
        return Preparation(prepared: prepared, config: config)
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
