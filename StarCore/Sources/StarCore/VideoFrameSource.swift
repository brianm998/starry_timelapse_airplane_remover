import Foundation
import logging

/// What `<frames folder>/extraction.json` records, so that a folder of frames can be told from a short image sequence and a
/// half-extracted video can be resumed.  The source of truth for "this folder is a video's frames" for all the clients.
public struct FrameExtractionSidecar: Codable, Sendable, Equatable {
    public static let fileName = "extraction.json"
    public static let currentVersion = 1

    public var version: Int = FrameExtractionSidecar.currentVersion
    public var videoPath: String
    public var videoSize: Int64
    /// Seconds since 1970.
    public var videoModified: Double
    public var frameCount: Int
    /// Whether `frameCount` is the video's own count.  An estimate may be settled when the extraction reaches the end.
    public var countIsExact: Bool
    public var digits: Int
    public var format: FrameDecodeFormat
    public var accessKind: FrameAccessKind
    public var complete: Bool

    public static func path(inFolder folder: String) -> String { "\(folder)/\(fileName)" }

    public static func read(inFolder folder: String) -> FrameExtractionSidecar? {
        guard let data = FileManager.default.contents(atPath: path(inFolder: folder)) else { return nil }
        return try? JSONDecoder().decode(FrameExtractionSidecar.self, from: data)
    }

    public func write(inFolder folder: String) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Atomic, so a crash while writing leaves the previous version rather than half of this one.
            try encoder.encode(self).write(to: URL(fileURLWithPath: Self.path(inFolder: folder)), options: .atomic)
        } catch {
            Log.w("could not write \(Self.fileName) in \(folder): \(error)")
        }
    }

    /// The size and modification time of the video the sidecar was written for, or nil if the video is not there.
    static func identity(ofVideoAt path: String) -> (size: Int64, modified: Double)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let date = attributes[.modificationDate] as? Date else { return nil }
        return (size, date.timeIntervalSince1970.rounded())
    }

    /// Whether the video at `videoPath` is the one this was written for.
    public func matchesVideo() -> Bool {
        guard let now = Self.identity(ofVideoAt: videoPath) else { return false }
        return now.size == videoSize && abs(now.modified - videoModified) < 1
    }
}

/// Extracts a video's frames in the background, and says which of them are there.
///
/// One in-order sweep, starting at the first frame, plus "jumps": other ffmpeg processes that extract a range somewhere else
/// first, because a client asked for it (`prioritize`).  An intra-only video (`FrameAccessKind.seekable`) gives up any frame cheaply
/// so any priority starts a jump; a long-GOP one is too slow to seek for the pipeline's out-of-order reads, so only the frame the
/// user is looking at does.  How many may run at once is `FrameExtractionSettings`.
///
/// Every ffmpeg writes into its own staging folder (`-atomic_writing`, so a file with its final name is complete) and the source
/// moves a frame into the frames folder only if it is not there yet.  So a worker that runs into frames another one extracted
/// never rewrites them, and a frame that exists in the folder is always complete, which is what makes a resume safe.
public final class VideoFrameSource: FrameSource, @unchecked Sendable {

    // MARK: configuration

    public let videoPath: String
    public let outputFolder: String
    public let format: FrameDecodeFormat
    public let accessKind: FrameAccessKind
    public let settings: FrameExtractionSettings
    public let digits: Int
    /// Whether this source made `outputFolder` (so a user who gives up during the import takes it back).
    public let createdOutputFolder: Bool
    /// Whether the frame count was the video's own count rather than an estimate.
    public private(set) var countIsExact: Bool

    private let ffmpegPath: String
    private let times: VideoFrameTimes?
    private let book: FrameAvailabilityBook

    /// The ffmpeg's own pace, in frames per second, is measured; before there is a measurement the estimate is unknown.
    private let estimator = LockedBox(Estimate())

    // MARK: scheduler state, confined to `queue`

    private let queue = DispatchQueue(label: "VideoFrameSource", qos: .utility)
    private var requests: [Int: FramePriorityReason] = [:]
    private var sweep: Worker?
    private var jumps: [Worker] = []
    private var failedJumpFrames = IndexSet()
    private var stopped = false
    private var started = false
    private var nextWorkerID = 0
    private var sweepRate: Double?
    private var jumpRate: Double?
    private var jumpLatency: [FrameAccessKind: Double] = [:]
    private var lastUserApply = Date.distantPast
    private var pendingUserWork: DispatchWorkItem?
    private var userViewing: [Int] = []
    private var userNearby: [Int] = []
    private var finishWaiters: [CheckedContinuation<Void, Never>] = []
    private var completionRecorded = false
    /// Whether a sweep has run to the end of the video, which is what makes an estimated count the real one.
    private var endOfVideoSeen = false

    /// How long a moving scrub is collapsed for before its next frame is acted on.
    static let userDebounce: TimeInterval = 0.15
    /// How far in front of the viewed frame a jump extracts, so one seek pays for the cluster.
    static let userForwardFrames = 8
    /// Longest range one jump extracts for a request that is not the user's.
    static let maxJumpFrames = 64
    /// A frame this close to the sweep is not worth a jump: the sweep gets there first.
    static let nearSweepFrames = 3

    // MARK: construction

    init(videoPath: String,
         outputFolder: String,
         format: FrameDecodeFormat,
         frameCount: Int,
         countIsExact: Bool,
         accessKind: FrameAccessKind,
         times: VideoFrameTimes?,
         settings: FrameExtractionSettings,
         digits: Int,
         existingFrames: IndexSet,
         createdOutputFolder: Bool,
         ffmpegPath: String = ToolPaths.ffmpeg)
    {
        self.videoPath = videoPath
        self.outputFolder = outputFolder
        self.format = format
        self.countIsExact = countIsExact
        self.accessKind = accessKind
        self.times = times
        self.settings = settings
        self.digits = digits
        self.createdOutputFolder = createdOutputFolder
        self.ffmpegPath = ffmpegPath
        self.book = FrameAvailabilityBook(frameCount: frameCount, available: existingFrames)
    }

    /// Begins extracting.  Idempotent.
    public func start() {
        queue.async {
            guard !self.started, !self.stopped else { return }
            self.started = true
            self.writeSidecar(complete: false)
            self.clearStaging()
            self.reschedule()
        }
    }

    // MARK: FrameSource

    public var frameCount: Int { book.frameCount }

    public func path(forFrame index: Int) -> String {
        "\(outputFolder)/\(FrameNaming.fileName(forFrame: index, digits: digits, fileExtension: format.fileExtension))"
    }

    public func isAvailable(_ index: Int) -> Bool { book.isAvailable(index) }
    public func availability(_ index: Int) -> FrameAvailability { book.availability(index) }
    public var availableFrames: IndexSet { book.availableSet }

    @discardableResult
    public func whenAvailable(_ index: Int, _ callback: @escaping @Sendable (Result<Void, Error>) -> Void) -> FrameWaitToken {
        book.addWaiter(index, callback)
    }

    public func prioritize(_ indices: [Int], reason: FramePriorityReason) {
        guard !indices.isEmpty else { return }
        queue.async { self.applyRequest(indices, reason: reason) }
    }

    public func events() -> AsyncStream<FrameSourceEvent> {
        book.events { [weak self] in self?.progress ?? FrameExtractionProgress(extracted: 0, total: 0, isComplete: false) }
    }

    public var progress: FrameExtractionProgress {
        let total = book.frameCount
        let have = min(book.availableCount, total)
        return FrameExtractionProgress(
          extracted: have,
          total: total,
          framesPerSecond: estimator.get().overallRate,
          isComplete: have >= total && total > 0 && book.error == nil,
          accessKind: accessKind,
          error: book.error)
    }

    public var sweepHead: Int? { estimator.get().sweepCursor }

    public func isBeingJumpedTo(_ index: Int) -> Bool {
        estimator.get().jumps.contains { $0.range.contains(index) && index >= $0.cursor }
    }

    public func estimatedSecondsUntilAvailable(_ index: Int) -> Double? {
        if book.isAvailable(index) { return 0 }
        if book.error != nil { return nil }
        let estimate = estimator.get()
        if let jump = estimate.jumps.first(where: { $0.range.contains(index) && index >= $0.cursor }) {
            guard let rate = jump.rate ?? estimate.jumpRate, rate > 0 else { return nil }
            var latency = 0.0
            if !jump.hasProducedAFrame {
                let expected = estimate.jumpLatency[accessKind] ?? 0
                latency = max(0, expected - Date().timeIntervalSince(jump.launchedAt))
            }
            return latency + Double(index - jump.cursor + 1) / rate
        }
        guard let head = estimate.sweepCursor, let rate = estimate.sweepRate, rate > 0 else { return nil }
        return Double(max(0, index - head + 1)) / rate
    }

    /// Stops every ffmpeg.  What is already extracted stays, and the sidecar says the folder is not complete, so a reopen resumes.
    public func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.pendingUserWork?.cancel()
            for worker in self.allWorkers { self.stop(worker) }
            self.writeSidecar(complete: false)
            self.book.cancelAll()
            self.resumeFinishWaiters()
        }
    }

    /// Returns once extraction has finished, failed or been stopped.  Throws the failure.
    public func waitUntilFinished() async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    if self.stopped || self.book.isFinished || self.book.error != nil {
                        continuation.resume()
                    } else {
                        self.finishWaiters.append(continuation)
                    }
                }
            }
        } onCancel: {
            self.stop()
        }
        try Task.checkCancellation()
        if let message = book.error { throw FrameSourceError(message) }
    }

    // MARK: requests

    private func applyRequest(_ indices: [Int], reason: FramePriorityReason) {
        guard !stopped else { return }
        switch reason {
        case .userViewing:
            // A new viewing frame replaces the old one, and the neighbourhood that went with it.
            userViewing = indices
            userNearby = []
            scheduleUserApply()
        case .userNearby:
            userNearby = indices
            scheduleUserApply()
        default:
            for index in indices where index >= 0 && index < book.frameCount && !book.isAvailable(index) {
                if (requests[index] ?? .background) < reason { requests[index] = reason }
            }
            reschedule()
        }
    }

    /// The scrubber moving must not queue every frame it passed over: the user's requests are acted on at once if none was in the
    /// last debounce interval, and otherwise at the end of it, with whatever the latest were.  So the frame where a scrub stops
    /// takes effect within the interval, and a scrub that is still moving costs one jump per interval at most.
    private func scheduleUserApply() {
        pendingUserWork?.cancel()
        let sinceLast = Date().timeIntervalSince(lastUserApply)
        if sinceLast >= Self.userDebounce {
            pendingUserWork = nil
            applyUserRequests()
        } else {
            let work = DispatchWorkItem { [self] in
                pendingUserWork = nil
                applyUserRequests()
            }
            pendingUserWork = work
            queue.asyncAfter(deadline: .now() + (Self.userDebounce - sinceLast), execute: work)
        }
    }

    private func applyUserRequests() {
        guard !stopped else { return }
        lastUserApply = Date()
        for (index, priority) in requests where priority.isUserRequest { requests[index] = nil }
        let count = book.frameCount
        for (indices, reason) in [(userNearby, FramePriorityReason.userNearby), (userViewing, .userViewing)] {
            for index in indices where index >= 0 && index < count && !book.isAvailable(index) {
                if (requests[index] ?? .background) < reason { requests[index] = reason }
            }
        }
        reschedule()
    }

    // MARK: workers

    private enum WorkerKind { case sweep, jump }

    /// One ffmpeg process extracting frames `start ..< start + limit` (to the end of the video when `limit` is nil).
    private final class Worker: @unchecked Sendable {
        let id: Int
        let kind: WorkerKind
        let start: Int
        let limit: Int?
        let priority: FramePriorityReason
        let stagingFolder: String
        let launchedAt = Date()
        /// The next frame this worker's ffmpeg has yet to write.
        var cursor: Int
        var run: FFmpegRun?
        var stopRequested = false
        var firstFrameAt: Date?
        var lastSampleAt: Date?
        var rate: Double?

        init(id: Int, kind: WorkerKind, start: Int, limit: Int?, priority: FramePriorityReason, stagingFolder: String) {
            self.id = id
            self.kind = kind
            self.start = start
            self.limit = limit
            self.priority = priority
            self.stagingFolder = stagingFolder
            self.cursor = start
        }

        var end: Int? { limit.map { start + $0 } }
        /// Frames this worker still has to write.
        var remaining: Range<Int> { cursor..<(end ?? Int.max) }
    }

    private var allWorkers: [Worker] { (sweep.map { [$0] } ?? []) + jumps }

    private var stagingRoot: String { "\(outputFolder)/.extracting" }

    private func clearStaging() {
        try? FileManager.default.removeItem(atPath: stagingRoot)
    }

    private func stop(_ worker: Worker) {
        guard !worker.stopRequested else { return }
        worker.stopRequested = true
        worker.run?.cancel()
    }

    private func launch(kind: WorkerKind, start: Int, limit: Int?, priority: FramePriorityReason) {
        let id = nextWorkerID
        nextWorkerID += 1
        let staging = "\(stagingRoot)/\(id)"
        let worker = Worker(id: id, kind: kind, start: start, limit: limit, priority: priority, stagingFolder: staging)
        try? FileManager.default.createDirectory(atPath: staging, withIntermediateDirectories: true)

        var arguments = FFmpegHardware.decodeArguments()
        arguments += ["-stats_period", "0.1"]
        if start > 0 {
            let seek = times?.seekTime(forFrame: start) ?? 0
            arguments += ["-ss", String(format: "%.6f", seek)]
        }
        arguments += ["-i", videoPath]
        var output = format.ffmpegOutputArguments(in: staging, digits: digits)
        // `-fps_mode passthrough`: one picture out for every picture decoded, so a jump and the sweep select exactly the same
        // frames.  image2's default is to duplicate and drop frames to hold a constant rate, which a seek would not reproduce on a
        // variable-rate video.
        var extra = ["-fps_mode", "passthrough", "-start_number", "\(start + 1)", "-atomic_writing", "1"]
        if let limit { extra += ["-frames:v", "\(limit)"] }
        let pattern = output.removeLast()
        output += extra + [pattern]
        arguments += output

        let run: FFmpegRun
        do {
            run = try FFmpegRun(arguments: arguments, totalFrames: nil, ffmpegPath: ffmpegPath, outputFolder: outputFolder) {
                [weak self, weak worker] _, _, _ in
                guard let self, let worker else { return }
                self.queue.async { self.scan(worker) }
            }
        } catch {
            try? FileManager.default.removeItem(atPath: staging)
            Log.e("could not start ffmpeg for frames \(start)...: \(error)")
            if kind == .sweep {
                fail("could not start ffmpeg: \(error.localizedDescription)")
            } else {
                failedJumpFrames.insert(integersIn: start..<(start + (limit ?? 1)))
            }
            return
        }
        worker.run = run
        switch kind {
        case .sweep: sweep = worker
        case .jump:  jumps.append(worker)
        }
        publishEstimate()
        Log.d("extraction worker \(id) (\(kind)) frames \(start)..<\(limit.map { "\(start + $0)" } ?? "end") for \(priority)")

        Task.detached { [self] in
            await run.exit()
            let failure: Error?
            do { try run.finish(); failure = nil } catch { failure = error }
            queue.async { self.workerExited(worker, failure: failure) }
        }
    }

    /// Moves what a worker's ffmpeg has finished writing into the frames folder, in order, and tells whoever is waiting.
    private func scan(_ worker: Worker) {
        guard !stopped else { return }
        var arrived = IndexSet()
        let fileManager = FileManager.default
        while worker.end.map({ worker.cursor < $0 }) ?? true {
            let index = worker.cursor
            let name = FrameNaming.fileName(forFrame: index, digits: digits, fileExtension: format.fileExtension)
            let staged = "\(worker.stagingFolder)/\(name)"
            guard fileManager.fileExists(atPath: staged) else { break }
            if book.isAvailable(index) {
                // Another worker got here first: leave its frame as it is, and stop decoding what is already extracted.
                try? fileManager.removeItem(atPath: staged)
                if !worker.stopRequested { stop(worker) }
                break
            }
            let destination = path(forFrame: index)
            try? fileManager.removeItem(atPath: destination)
            do {
                try fileManager.moveItem(atPath: staged, toPath: destination)
            } catch {
                Log.e("could not move extracted frame \(index) into place: \(error)")
                fail("could not move extracted frame \(index) into place: \(error.localizedDescription)")
                return
            }
            arrived.insert(index)
            worker.cursor += 1
        }
        guard !arrived.isEmpty else { return }

        let now = Date()
        if worker.firstFrameAt == nil {
            worker.firstFrameAt = now
            if worker.kind == .jump { jumpLatency[accessKind] = now.timeIntervalSince(worker.launchedAt) }
            worker.lastSampleAt = now
        } else if let last = worker.lastSampleAt {
            let seconds = now.timeIntervalSince(last)
            if seconds > 0.05 {
                let instantaneous = Double(arrived.count) / seconds
                worker.rate = worker.rate.map { 0.7 * $0 + 0.3 * instantaneous } ?? instantaneous
                worker.lastSampleAt = now
            }
        }
        if let rate = worker.rate {
            if worker.kind == .sweep { sweepRate = rate } else { jumpRate = rate }
        }
        for index in arrived { requests[index] = nil }
        publishEstimate()
        book.markAvailable(arrived, progress: progress)
        // A jump ahead of the sweep fills frames the sweep will reach: it stops when it does (see above) rather than here.
        if let sweep, !sweep.stopRequested, book.isAvailable(sweep.cursor) { stop(sweep) }
        reschedule()
    }

    private func workerExited(_ worker: Worker, failure: Error?) {
        if !stopped { scan(worker) }
        try? FileManager.default.removeItem(atPath: worker.stagingFolder)
        if sweep === worker { sweep = nil }
        jumps.removeAll { $0 === worker }
        publishEstimate()
        guard !stopped else { return }

        if let failure, !worker.stopRequested {
            let message = Self.message(for: failure)
            if worker.kind == .sweep {
                Log.e("frame extraction failed: \(message)")
                fail(message)
                return
            }
            // A jump that failed costs only its range, which the sweep will still get to.
            Log.w("a jump to frames \(worker.start)..<\(worker.end ?? worker.start + 1) failed: \(message)")
            failedJumpFrames.insert(integersIn: worker.cursor..<(worker.end ?? worker.cursor + 1))
        } else if !worker.stopRequested, worker.kind == .sweep {
            // ffmpeg ended normally having written fewer (or more) frames than it was asked for: the video ends where it did, and
            // the count we were given (an estimate from the duration, say) was wrong.
            let reachedEnd = worker.end.map { worker.cursor < $0 } ?? true
            if reachedEnd { endOfVideoSeen = true }
            if reachedEnd, worker.cursor != book.frameCount {
                Log.i("video has \(worker.cursor) frames, not \(book.frameCount)")
                countIsExact = true
                book.settleCount(worker.cursor)
                writeSidecar(complete: false)
            }
        }
        reschedule()
    }

    private static func message(for error: Error) -> String {
        let ns = error as NSError
        if let stderr = ns.userInfo["stderr"] as? String, !stderr.isEmpty {
            let lines = stderr.split(whereSeparator: \.isNewline).suffix(6).joined(separator: "\n")
            return "\(ns.localizedDescription): \(lines)"
        }
        return error.localizedDescription
    }

    private func fail(_ message: String) {
        for worker in allWorkers { stop(worker) }
        writeSidecar(complete: false)
        book.failEverything(message)
        resumeFinishWaiters()
    }

    // MARK: scheduling

    private func reschedule() {
        guard !stopped, started, book.error == nil else { return }
        let count = book.frameCount
        for index in requests.keys where index >= count || book.isAvailable(index) { requests[index] = nil }

        if let sweep, !sweep.stopRequested, book.isAvailable(sweep.cursor) { stop(sweep) }
        planJumps()
        if sweep == nil { launchSweepIfNeeded() }
        recordCompletionIfDone()
    }

    private func firstUnavailable() -> Int? {
        let count = book.frameCount
        let have = book.availableSet
        guard count > 0 else { return nil }
        var index = 0
        for range in have.rangeView {
            if range.lowerBound > index { break }
            index = max(index, range.upperBound)
        }
        return index < count ? index : nil
    }

    private func launchSweepIfNeeded() {
        guard let head = firstUnavailable() else { return }
        let count = book.frameCount
        let have = book.availableSet
        // The run of missing frames from the head: the sweep stops where the next extracted one starts.
        let nextAvailable = have.integerGreaterThan(head) ?? count
        // To the end of the video, with no frame limit, when nothing extracted lies in the way: that is also how the true
        // length of a video whose count was only an estimate shows itself.
        let limit: Int? = nextAvailable >= count ? nil : nextAvailable - head
        launch(kind: .sweep, start: head, limit: limit, priority: .background)
    }

    private var jumpLimit: Int {
        accessKind == .seekable ? settings.maxJumpWorkers : settings.maxLongGOPJumpWorkers
    }

    private func planJumps() {
        guard jumpLimit > 0, times != nil else { return }
        let have = book.availableSet
        let count = book.frameCount

        // A jump for a frame the user has since left is not worth finishing.
        for jump in jumps where jump.priority.isUserRequest && !jump.stopRequested {
            let stillWanted = requests.contains { index, _ in jump.remaining.contains(index) }
            if !stillWanted { stop(jump) }
        }

        var candidates = requests
            .filter { accessKind == .seekable || $0.value.isUserRequest }
            .filter { !failedJumpFrames.contains($0.key) }
            .map { (index: $0.key, priority: $0.value) }
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.index < $1.index }

        while let candidate = candidates.first {
            candidates.removeFirst()
            let live = jumps.filter { !$0.stopRequested }
            if live.contains(where: { $0.remaining.contains(candidate.index) }) { continue }
            if isSoonReachedBySweep(candidate.index) { continue }

            if live.count >= jumpLimit {
                // Replace the least important running jump, if this one matters more.
                guard let weakest = live.min(by: { $0.priority < $1.priority }), weakest.priority < candidate.priority else {
                    continue
                }
                stop(weakest)
            }

            // The range is the requested frames from here on that are contiguous and not yet extracted.
            var end = candidate.index + 1
            let cap = candidate.priority.isUserRequest ? Self.userForwardFrames + 1 : Self.maxJumpFrames
            while end < count, end - candidate.index < cap, !have.contains(end),
                  requests[end] != nil || candidate.priority.isUserRequest
            {
                end += 1
            }
            if candidate.priority.isUserRequest { end = min(end, candidate.index + 1 + Self.userForwardFrames) }
            end = min(end, count)
            launch(kind: .jump, start: candidate.index, limit: end - candidate.index, priority: candidate.priority)
            // The candidates the new range covers need nothing of their own.
            candidates.removeAll { $0.index >= candidate.index && $0.index < end }
            if jumps.filter({ !$0.stopRequested }).count >= jumpLimit { break }
        }
    }

    /// A frame the sweep will reach before a jump could deliver it.
    private func isSoonReachedBySweep(_ index: Int) -> Bool {
        guard let sweep, !sweep.stopRequested else { return false }
        let ahead = index - sweep.cursor
        if ahead < 0 { return false }
        if ahead <= Self.nearSweepFrames { return true }
        if accessKind == .longGOP, let rate = sweepRate, rate > 0, let latency = jumpLatency[.longGOP] {
            return Double(ahead) / rate < latency
        }
        return false
    }

    // MARK: completion and the sidecar

    private func recordCompletionIfDone() {
        guard firstUnavailable() == nil, book.frameCount > 0, !completionRecorded else { return }
        // An estimated count is not known to be the whole video until a sweep has run off the end of it.
        guard countIsExact || endOfVideoSeen else { return }
        completionRecorded = true
        for worker in allWorkers { stop(worker) }
        clearStaging()
        writeSidecar(complete: true)
        book.finish()
        resumeFinishWaiters()
    }

    private func resumeFinishWaiters() {
        let waiters = finishWaiters
        finishWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    private func writeSidecar(complete: Bool) {
        guard let identity = FrameExtractionSidecar.identity(ofVideoAt: videoPath) else { return }
        FrameExtractionSidecar(
          videoPath: videoPath,
          videoSize: identity.size,
          videoModified: identity.modified,
          frameCount: book.frameCount,
          countIsExact: countIsExact,
          digits: digits,
          format: format,
          accessKind: accessKind,
          complete: complete
        ).write(inFolder: outputFolder)
    }

    // MARK: estimates

    private struct Estimate {
        struct Jump {
            var range: Range<Int>
            var cursor: Int
            var rate: Double?
            var launchedAt: Date
            var hasProducedAFrame: Bool
        }
        var sweepCursor: Int?
        var sweepRate: Double?
        var jumpRate: Double?
        var jumpLatency: [FrameAccessKind: Double] = [:]
        var jumps: [Jump] = []

        var overallRate: Double? {
            sweepRate.map { $0 + (jumpRate ?? 0) } ?? jumpRate
        }
    }

    private func publishEstimate() {
        var estimate = Estimate()
        estimate.sweepCursor = sweep?.cursor ?? firstUnavailable()
        estimate.sweepRate = sweepRate
        estimate.jumpRate = jumpRate
        estimate.jumpLatency = jumpLatency
        estimate.jumps = jumps.filter { !$0.stopRequested }.map {
            Estimate.Jump(range: $0.start..<($0.end ?? $0.start + 1), cursor: $0.cursor, rate: $0.rate,
                          launchedAt: $0.launchedAt, hasProducedAFrame: $0.firstFrameAt != nil)
        }
        estimator.set(estimate)
    }
}
