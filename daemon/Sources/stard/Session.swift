import Foundation
import StarCore
import StarDaemonMessages
import logging
import Semaphore

// Mirrors cli/Processor but lives in the daemon and stays resident.
actor Session {
    let sessionID: String
    let scratchSessionDir: String

    /// Where this session's config.json is, which is what a client hands back to
    /// `Session.OpenConfig` to resume it.  Not always under `scratchSessionDir`: a session
    /// opened from a config keeps writing to the caller's own file.
    let configJsonPath: String

    private(set) var configManager: ConfigManager
    private(set) var imageSequence: ImageSequence
    private(set) var frames: [FrameAirplaneRemover] = []
    private(set) var imageInfo: ImageInfo
    private(set) var videoInfo: VideoInfo?     // set for sessions opened from a video file

    /// Every open progress stream, keyed by a token its handler holds.  `Processing.StreamProgress`
    /// is the long-lived one; `Export.RenderSequence` and `Horizon.Reprocess` add a short-lived
    /// one for their own duration.  Each handler removes only its own token when its stream ends,
    /// so one ending can never take another's subscription with it.
    private var progressSubscribers: [UUID: AsyncStream<Star_V1_ProgressEvent>.Continuation] = [:]

    /// The processing run in flight, if any.  Bumped for every run started and every run
    /// stopped, so a completion that arrives late from a run that was stopped or replaced is
    /// recognisably not the current one and does nothing.
    private var runGeneration = 0
    private var activeRun: Int?

    /// The task that builds the frame graph for `activeRun`; a stop waits for it so it never
    /// cancels the queue before the run's operations have been put on it.
    private var buildTask: Task<Void, Never>?

    /// A stop in progress.  A start waits for it rather than building a second graph
    /// alongside the operations the stop is still draining.
    private var stopTask: Task<Void, Never>?

    /// Set once `close()` begins.  From then on nothing starts work on this session and a
    /// stream that tries to attach is ended at once.
    private var closed = false

    /// Where a user's edits are written down.  StarCore's own queue, the one the macOS app uses:
    /// a frame is put in "purgatory" when it is edited, and ten seconds after the last edit its
    /// finished image and decisions are written.  Built with the frame graph because the class
    /// is main-actor isolated.
    private var saveQueue: FrameSaveQueue?

    init(
        sessionID: String,
        scratchSessionDir: String,
        configJsonPath: String,
        configManager: ConfigManager,
        imageSequence: ImageSequence,
        imageInfo: ImageInfo,
        videoInfo: VideoInfo? = nil
    ) {
        self.sessionID = sessionID
        self.scratchSessionDir = scratchSessionDir
        self.configJsonPath = configJsonPath
        self.configManager = configManager
        self.imageSequence = imageSequence
        self.imageInfo = imageInfo
        self.videoInfo = videoInfo
    }

    // Build FrameAirplaneRemover graph (does not start processing).
    func buildFrameGraph() async throws {
        let config = await configManager.config()
        let filenames = await imageSequence.filenames
        var frameIndexToBaseNameMap: [Int: String] = [:]
        for (i, fn) in filenames.enumerated() {
            frameIndexToBaseNameMap[i] = removePath(fromString: fn)
        }

        let imageAccessor = ImageAccessor(
            config: config,
            imageSequence: imageSequence,
            frameIndexToBaseNameMap: frameIndexToBaseNameMap
        )

        let weakSelf = WeakSessionRef(self)
        var callbacks = Callbacks()
        callbacks.frameStateChangeCallback = { frame, state in
            Task { await weakSelf.session?.onFrameStateChange(frame: frame, state: state) }
        }
        callbacks.frameSavingStateChangeCallback = { frame, old, new in
            Task { await weakSelf.session?.onFrameSavingStateChange(frame: frame, old: old, new: new) }
        }
        callbacks.exisingFrameStateChangeCallback = { frameIndex in
            Task { await weakSelf.session?.onExistingFrameStateChange(frameIndex: frameIndex) }
        }
        callbacks.frameOutliersLoadedCallback = { frameIndex, loadingState in
            Task { await weakSelf.session?.onOutliersLoaded(frameIndex: frameIndex, state: loadingState) }
        }

        saveQueue = await MainActor.run { FrameSaveQueue() }

        var built: [FrameAirplaneRemover] = []
        for (frameIndex, filename) in filenames.enumerated() {
            let basename = removePath(fromString: filename)
            let frame = try await FrameAirplaneRemover(
                with: configManager,
                initialConfig: config,
                width: imageInfo.imageWidth,
                height: imageInfo.imageHeight,
                componentsPerPixel: imageInfo.componentsPerPixel,
                callbacks: callbacks,
                imageSequence: imageSequence,
                atIndex: frameIndex,
                outputFilename: "\(config.outputPath)/\(config.basename)",
                baseName: basename,
                writeOutputFiles: true,
                imageAccessor: imageAccessor
            )
            built.append(frame)
        }
        await doublyLink(frames: built)
        frames = built
    }

    var frameCount: Int { frames.count }

    func frame(at index: Int) -> FrameAirplaneRemover? {
        guard index >= 0, index < frames.count else { return nil }
        return frames[index]
    }

    // Current config snapshot.
    func config() async -> Config { await configManager.config() }

    /// Apply the settings a client sent (`Sequence.UpdateConfig`) and persist them.  Returns the
    /// config as it now stands.
    func updateConfig(from proto: Star_V1_Config) async -> Config {
        var config = await configManager.config()
        config.cleanMethod = Mapping.cleanMethod(from: proto)
        config.detectionType = Mapping.detectionType(from: proto.detectionType)
        config.horizonDetectionEnabled = proto.horizonDetectionEnabled
        config.tripodHeadWasMoving = proto.tripodHeadWasMoving
        if proto.numberOfFramesToProcessConcurrently > 0 {
            config.numberOfFramesToProcessConcurrently = Int(proto.numberOfFramesToProcessConcurrently)
        }
        Mapping.applyExpertConfig(&config, from: proto)
        await configManager.update(config)
        // The client is told the config is applied; make that include the
        // file, since update() writes asynchronously now.
        await configManager.flush()
        // The outlier stage reads the detection strength from the global `constants`, not from
        // the config, so a change only reaches the frames still to be processed through this
        // (macOS sets it on change too).
        await constants.set(detectionType: config.detectionType)
        return config
    }

    // Set/clear the static reference-horizon flag and persist config.json (resume/interop).
    func setStaticReferenceHorizon(_ enabled: Bool) async {
        var cfg = await configManager.config()
        cfg.hasStaticReferenceHorizon = enabled
        await configManager.update(cfg)   // saves to configJsonPath
        await configManager.flush()       // ...asynchronously, so wait for it
    }

    // Start processing (calls frameGraphBuilder.build).
    // startIndex/endIndex are 0-based inclusive frame indices; pass nil endIndex to process to the last frame.
    func startProcessing(startIndex: Int = 0, endIndex: Int? = nil) async {
        await stopTask?.value
        guard !closed, activeRun == nil else { return }
        await frameGraphBuilder.set(configManager: configManager)
        // The stop that was awaited above, or a concurrent start, may have got in while this
        // was suspended on the builder.
        guard !closed, activeRun == nil else { return }
        runGeneration += 1
        let generation = runGeneration
        activeRun = generation
        let fs = frames
        let weakSelf = WeakSessionRef(self)
        buildTask = Task {
            await frameGraphBuilder.build(
                frames: fs,
                startIndex: startIndex,
                endIndex: endIndex
            ) { errorList in
                // Not called at all if the run is cancelled; see stopRun.
                Task { await weakSelf.session?.runCompleted(generation: generation, errors: errorList) }
            } errorClosure: { errorString in
                Log.e("stard: op error: \(errorString)")
            }
        }
    }

    /// The graph's completion handler.  Ignored unless `generation` is still the current run.
    private func runCompleted(generation: Int, errors errorList: [String]) {
        guard activeRun == generation else {
            Log.i("stard: ignoring the completion of a stopped processing run")
            return
        }
        activeRun = nil
        buildTask = nil
        if errorList.isEmpty {
            Log.i("stard: processing finished cleanly")
            emitSequenceState("done")
        } else {
            let joined = errorList.joined(separator: "\n")
            Log.e("stard: processing finished with \(errorList.count) error(s):\n\(joined)")
            try? joined.write(toFile: "\(scratchSessionDir)/processing_errors.log", atomically: true, encoding: .utf8)
            // A run with failed operations did not finish; the client must not offer to render it.
            emitSequenceState("error", message: joined)
        }
    }

    /// Stop the run in flight and return once what it had running has stopped (macOS
    /// `cancelAllOperationsAndWait`).  Emits `cancelled` unless `announce` is false, which is
    /// for a stop that is only the first half of a restart.
    func cancelProcessing() async {
        await stopRun(announce: true)
    }

    private func stopRun(announce: Bool) async {
        if let inFlight = stopTask {
            await inFlight.value
            if announce { emitSequenceState("cancelled") }
            return
        }
        // From here nothing the old run reports counts, whatever order it arrives in.
        runGeneration += 1
        activeRun = nil
        let building = buildTask
        buildTask = nil
        let stop = Task {
            // Let the build finish putting its operations on the queue before cancelling it.
            await building?.value
            await frameGraphBuilder.cancelAllOperationsAndWait()
        }
        stopTask = stop
        await stop.value
        stopTask = nil
        if announce { emitSequenceState("cancelled") }
    }

    // Re-run the whole frame graph after a reference-horizon change. With hasStaticReferenceHorizon
    // set, the graph skips per-frame horizon detection and reads reference.tiff directly.
    func reprocessWithReferenceHorizon() async {
        guard !closed else { return }
        await stopRun(announce: false)
        await startProcessing(startIndex: 0, endIndex: nil)
    }

    // Throw away what a reprocess of `type` must redo, so the frame graph recomputes it.  The
    // per-type work is StarCore's `FrameAirplaneRemover.resetForReprocessing`, which the macOS
    // gui calls too: `.none` deletes nothing, `.horizons` only the horizon images, `.everything`
    // every processed image and the outliers as well.
    func resetFrames(indices: [Int], type: FrameReprocessingType) async {
        for i in indices {
            guard let frame = frame(at: i) else { continue }
            await frame.resetForReprocessing(type)
        }
    }

    // Force-reprocess a contiguous range: reset the frames, then run the graph over [start, end].
    func forceReprocess(startIndex: Int, endIndex: Int?) async {
        guard !closed else { return }
        await stopRun(announce: false)
        let lo = max(0, startIndex)
        let hi = min(frames.count - 1, endIndex ?? (frames.count - 1))
        guard lo <= hi else { return }
        await resetFrames(indices: Array(lo...hi), type: .everything)
        await startProcessing(startIndex: startIndex, endIndex: endIndex)
    }

    // Granular reprocess of a specific (possibly non-contiguous) set of frames. Untouched .complete
    // frames in [min,max] are skipped by the ops' state check, so only the reset frames recompute.
    func reprocessFrames(indices: [Int], type: FrameReprocessingType) async {
        guard !closed, !indices.isEmpty else { return }
        await stopRun(announce: false)
        await resetFrames(indices: indices, type: type)
        await startProcessing(startIndex: indices.min()!, endIndex: indices.max()!)
    }

    // MARK: - Closing

    /// End the session (`Session.Close`): stop the run in flight and wait for it to drain, write
    /// out what is still pending, and end every progress stream, so that nothing keeps running
    /// against a session that is about to be dropped (the frame-graph builder is shared, and the
    /// next session repoints it).  Safe to call more than once.
    func close() async {
        closed = true
        // Only a session with a run of its own has anything to stop: the frame-graph builder is
        // shared, and stopping it would also stop a run that belongs to another session.
        if activeRun != nil || stopTask != nil {
            await stopRun(announce: false)
        }
        await flushSaves()
        await configManager.flush()
        let subscribers = progressSubscribers.values
        progressSubscribers.removeAll()
        for cont in subscribers { cont.finish() }
    }

    // MARK: - Saving edits

    /// A user edit has been made to `frame`: write its decisions down now, so that a crash before
    /// the save timer fires still keeps them, and queue the frame for saving once the user has
    /// left it alone for a while (what leaving a frame does in the macOS app).  Every edit
    /// restarts that wait, so a burst of clicks is one save.
    func frameEdited(_ frame: FrameAirplaneRemover) async {
        guard !closed, let saveQueue else { return }
        await frame.writeOutliersRemoveReasons()
        await saveQueue.readyToSave(frame: frame) { }
    }

    /// Save every frame whose edits are still waiting (in purgatory, or already queued or being
    /// saved) and return once they have all been written.  A frame is never saved twice: one
    /// that is already past purgatory is only waited for.  Gives up after `timeout` rather than
    /// holding a close or a shutdown hostage to a save that never ends.
    func flushSaves(timeout: Duration = .seconds(120)) async {
        guard let saveQueue else { return }
        var waiting: [FrameAirplaneRemover] = []
        for frame in frames {
            switch await frame.savingState() {
            case .notSaving:
                continue
            case .inPurgatory:
                // Claim it before the queue's own timer can: it only saves a frame that is
                // still in purgatory when it fires.
                await frame.set(frameSavingState: .savePending)
                do {
                    try await saveQueue.saveNow(frame: frame) { }
                } catch {
                    Log.e("stard: could not save frame \(frame.frameIndex): \(error)")
                    await frame.set(frameSavingState: .notSaving)
                    continue
                }
            case .savePending, .saving:
                break
            }
            waiting.append(frame)
        }
        guard !waiting.isEmpty else { return }
        Log.i("stard: waiting for \(waiting.count) frame(s) to finish saving")
        let deadline = ContinuousClock.now + timeout
        for frame in waiting {
            while await frame.savingState() != .notSaving {
                if ContinuousClock.now > deadline {
                    Log.e("stard: gave up waiting for frame \(frame.frameIndex) to finish saving")
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    // MARK: - Progress subscribers

    /// Register a stream to receive every progress event from now on.  Hold the token and
    /// hand it to `removeProgressSubscriber` when the stream ends.
    func addProgressSubscriber(_ cont: AsyncStream<Star_V1_ProgressEvent>.Continuation) -> UUID {
        let token = UUID()
        if closed {
            cont.finish()   // a stream that arrives after the close has nothing to wait for
        } else {
            progressSubscribers[token] = cont
        }
        return token
    }

    /// Remove one subscriber, and only that one.
    func removeProgressSubscriber(_ token: UUID) {
        progressSubscribers[token] = nil
    }

    /// Send an event to every subscriber.
    func emit(_ event: Star_V1_ProgressEvent) {
        for cont in progressSubscribers.values { cont.yield(event) }
    }

    /// Tell one subscriber each frame's state as it is now.  StarCore reports a frame's state
    /// as it is built, before any stream exists to hear it, so without this a client that
    /// attaches after the open starts out knowing nothing about frames a resumed run already
    /// finished.  The live events that follow supersede it.
    func seedFrameStates(to cont: AsyncStream<Star_V1_ProgressEvent>.Continuation) async {
        for frame in frames {
            var ev = Star_V1_FrameStateEvent()
            ev.frameIndex = Int32(frame.frameIndex)
            ev.state = Mapping.frameProcessingState(await frame.processingState())
            var prog = Star_V1_ProgressEvent()
            prog.kind = .frameState(ev)
            cont.yield(prog)
        }
    }

    // MARK: - StarCore callback bridges

    private func onFrameStateChange(frame: FrameAirplaneRemover, state: FrameProcessingState) {
        var ev = Star_V1_FrameStateEvent()
        ev.frameIndex = Int32(frame.frameIndex)
        ev.state = Mapping.frameProcessingState(state)
        var prog = Star_V1_ProgressEvent()
        prog.kind = .frameState(ev)
        emit(prog)
    }

    private func onFrameSavingStateChange(frame: FrameAirplaneRemover, old: FrameSavingState, new: FrameSavingState) {
        var ev = Star_V1_FrameSavingEvent()
        ev.frameIndex = Int32(frame.frameIndex)
        ev.oldState = old.int32Value
        ev.newState = new.int32Value
        var prog = Star_V1_ProgressEvent()
        prog.kind = .frameSavingState(ev)
        emit(prog)
    }

    private func onExistingFrameStateChange(frameIndex: Int) {
        var prog = Star_V1_ProgressEvent()
        prog.kind = .frameExisting(Int32(frameIndex))
        emit(prog)
    }

    private func onOutliersLoaded(frameIndex: Int, state: OutlierLoadingState) {
        var ev = Star_V1_OutliersLoaded()
        ev.frameIndex = Int32(frameIndex)
        ev.state = state.int32Value
        var prog = Star_V1_ProgressEvent()
        prog.kind = .outliersLoaded(ev)
        emit(prog)
    }

    private func emitSequenceState(_ state: String, message: String = "") {
        var ev = Star_V1_SequenceStateEvent()
        ev.state = state
        ev.message = message
        var prog = Star_V1_ProgressEvent()
        prog.kind = .sequenceState(ev)
        emit(prog)
    }
}

/// What the `sequence_state` values a processing run reports mean.
enum ProcessingRun {
    /// `done`, `cancelled` and `error` each end a run; nothing follows any of them.
    static func isTerminal(_ state: String) -> Bool {
        state == "done" || state == "cancelled" || state == "error"
    }
}

// Simple wrapper to capture a weak reference to a Session actor inside callbacks.
// (Actors don't support weak references directly; we wrap in a class.)
final class WeakSessionRef: @unchecked Sendable {
    weak var session: Session?
    init(_ session: Session) { self.session = session }
}

// MARK: - Factory

extension Session {
    // Open a sequence directory and build the session.
    static func openSequence(
        sessionID: String,
        scratchSessionDir: String,
        sequenceDir: String,
        protoConfig: Star_V1_Config
    ) async throws -> Session {
        try FileManager.default.createDirectory(atPath: scratchSessionDir, withIntermediateDirectories: true)

        // The sequence's directory name and parent path. StarCore's ImageAccessor locates the
        // original frames at "\(imageSequencePath)/\(imageSequenceDirname)", so these must be exact.
        let (seqName, seqPath) = splitDirPath(sequenceDir)

        let outputPath = protoConfig.outputPath.isEmpty ? "\(scratchSessionDir)/output" : protoConfig.outputPath

        var config = Config(
            outputPath: outputPath,
            cleanMethod: Mapping.cleanMethod(from: protoConfig),
            detectionType: Mapping.detectionType(from: protoConfig.detectionType),
            imageSequenceName: seqName,
            imageSequencePath: seqPath,
            writeOutlierGroupFiles: protoConfig.writeOutlierGroupFiles,
            writeFramePreviewFiles: protoConfig.writeFramePreviewFiles,
            writeFrameProcessedPreviewFiles: protoConfig.writeFramePreviewFiles,
            writeFrameThumbnailFiles: protoConfig.writeFramePreviewFiles
        )
        config.horizonDetectionEnabled = protoConfig.horizonDetectionEnabled
        config.tripodHeadWasMoving = protoConfig.tripodHeadWasMoving
        if protoConfig.numberOfFramesToProcessConcurrently > 0 {
            config.numberOfFramesToProcessConcurrently = Int(protoConfig.numberOfFramesToProcessConcurrently)
        }
        if protoConfig.ignoreLowerPixels != 0 {
            config.ignoreLowerPixels = Int(protoConfig.ignoreLowerPixels)
        }
        Mapping.applyExpertConfig(&config, from: protoConfig)

        let configFilename = "\(scratchSessionDir)/config.json"
        let configManager = await ConfigManager(configFilename: configFilename, config: config)
        await configManager.save()   // the initial file; nothing has updated the manager yet
        await constants.set(detectionType: config.detectionType)

        let imageSequence = try ImageSequence(
            dirname: sequenceDir,
            supportedImageFileTypes: config.supportedImageFileTypes,
            maxImages: 40
        )
        let imageInfo = try await imageSequence.getImageInfo()

        // Propagate the dimensions into the config too. FrameGraphBuilder.build derives
        // rawImageBytes from config.imageWidth/Height/BytesPerPixel, so leaving them at 0
        // makes every op's estimatedMemoryBytes 0 (AsyncOperation then skips reserve()
        // entirely) and drops the keypoint limiter back to
        // numberOfFramesToProcessConcurrently — i.e. no memory gating at all.
        // save: false because there is nothing here worth rewriting config.json for — the
        // dimensions are read back off the sequence on every open.
        var configWithImageInfo = await configManager.config()
        configWithImageInfo.set(imageInfo: imageInfo)
        await configManager.update(configWithImageInfo, save: false)

        let session = Session(
            sessionID: sessionID,
            scratchSessionDir: scratchSessionDir,
            configJsonPath: configFilename,
            configManager: configManager,
            imageSequence: imageSequence,
            imageInfo: imageInfo
        )
        try await session.buildFrameGraph()
        return session
    }

    // Decode a video file to TIFFs and open as a session.
    // onProgress is called on each ffmpeg frame so the handler can stream IoProgress back to the client.
    static func openVideo(
        sessionID: String,
        scratchSessionDir: String,
        videoPath: String,
        protoConfig: Star_V1_Config,
        onProgress: @Sendable @escaping (Int, Int, String) -> Void
    ) async throws -> Session {
        try FileManager.default.createDirectory(atPath: scratchSessionDir, withIntermediateDirectories: true)

        let (sequenceDir, vi) = try await decodeVideo(named: videoPath, progress: onProgress)

        // Originals live in the decoded-frames directory, not next to the source video — derive the
        // sequence name/path from sequenceDir so ImageAccessor resolves the originals correctly.
        let (seqName, seqPath) = splitDirPath(sequenceDir)

        let outputPath = protoConfig.outputPath.isEmpty ? "\(scratchSessionDir)/output" : protoConfig.outputPath

        var config = Config(
            outputPath: outputPath,
            cleanMethod: Mapping.cleanMethod(from: protoConfig),
            detectionType: Mapping.detectionType(from: protoConfig.detectionType),
            imageSequenceName: seqName,
            imageSequencePath: seqPath,
            writeOutlierGroupFiles: protoConfig.writeOutlierGroupFiles,
            writeFramePreviewFiles: protoConfig.writeFramePreviewFiles,
            writeFrameProcessedPreviewFiles: protoConfig.writeFramePreviewFiles,
            writeFrameThumbnailFiles: protoConfig.writeFramePreviewFiles
        )
        config.set(videoInfo: vi)
        config.horizonDetectionEnabled = protoConfig.horizonDetectionEnabled
        config.tripodHeadWasMoving = protoConfig.tripodHeadWasMoving
        if protoConfig.numberOfFramesToProcessConcurrently > 0 {
            config.numberOfFramesToProcessConcurrently = Int(protoConfig.numberOfFramesToProcessConcurrently)
        }
        Mapping.applyExpertConfig(&config, from: protoConfig)

        let configFilename = "\(scratchSessionDir)/config.json"
        let configManager = await ConfigManager(configFilename: configFilename, config: config)
        await configManager.save()   // the initial file; nothing has updated the manager yet
        await constants.set(detectionType: config.detectionType)

        let imageSequence = try ImageSequence(
            dirname: sequenceDir,
            supportedImageFileTypes: config.supportedImageFileTypes,
            maxImages: 40
        )
        let imageInfo = try await imageSequence.getImageInfo()

        // Propagate the dimensions into the config too. FrameGraphBuilder.build derives
        // rawImageBytes from config.imageWidth/Height/BytesPerPixel, so leaving them at 0
        // makes every op's estimatedMemoryBytes 0 (AsyncOperation then skips reserve()
        // entirely) and drops the keypoint limiter back to
        // numberOfFramesToProcessConcurrently — i.e. no memory gating at all.
        // save: false because there is nothing here worth rewriting config.json for — the
        // dimensions are read back off the sequence on every open.
        var configWithImageInfo = await configManager.config()
        configWithImageInfo.set(imageInfo: imageInfo)
        await configManager.update(configWithImageInfo, save: false)

        let session = Session(
            sessionID: sessionID,
            scratchSessionDir: scratchSessionDir,
            configJsonPath: configFilename,
            configManager: configManager,
            imageSequence: imageSequence,
            imageInfo: imageInfo,
            videoInfo: vi
        )
        try await session.buildFrameGraph()
        return session
    }

    // Open from a saved config.json.
    static func openConfig(
        sessionID: String,
        scratchSessionDir: String,
        configPath: String
    ) async throws -> Session {
        try FileManager.default.createDirectory(atPath: scratchSessionDir, withIntermediateDirectories: true)

        let configManager = try await ConfigManager(configFilename: configPath)
        let config = await configManager.config()
        await constants.set(detectionType: config.detectionType)

        let sequenceDir = "\(config.imageSequencePath)/\(config.imageSequenceDirname)"
        let imageSequence = try ImageSequence(
            dirname: sequenceDir,
            supportedImageFileTypes: config.supportedImageFileTypes,
            maxImages: 40
        )
        let imageInfo = try await imageSequence.getImageInfo()

        // Propagate the dimensions into the config too. FrameGraphBuilder.build derives
        // rawImageBytes from config.imageWidth/Height/BytesPerPixel, so leaving them at 0
        // makes every op's estimatedMemoryBytes 0 (AsyncOperation then skips reserve()
        // entirely) and drops the keypoint limiter back to
        // numberOfFramesToProcessConcurrently — i.e. no memory gating at all.
        // save: false because there is nothing here worth rewriting config.json for — the
        // dimensions are read back off the sequence on every open, and this session's
        // config.json is the caller's own file rather than one in the scratch dir.
        var configWithImageInfo = await configManager.config()
        configWithImageInfo.set(imageInfo: imageInfo)
        await configManager.update(configWithImageInfo, save: false)

        let session = Session(
            sessionID: sessionID,
            scratchSessionDir: scratchSessionDir,
            configJsonPath: configPath,   // the caller's own file, not one in the scratch dir
            configManager: configManager,
            imageSequence: imageSequence,
            imageInfo: imageInfo
        )
        try await session.buildFrameGraph()
        return session
    }
}

// Standalone helper (mirrors cli/Processor.swift).
func removePath(fromString string: String) -> String {
    let parts = string.components(separatedBy: "/")
    return parts.last ?? string
}

// Split a directory path into (lastComponent, parentPath), tolerating a trailing slash.
// e.g. "/a/b/seq" -> ("seq", "/a/b"); "/a/b/seq/" -> ("seq", "/a/b").
func splitDirPath(_ dir: String) -> (name: String, path: String) {
    let trimmed = (dir.count > 1 && dir.hasSuffix("/")) ? String(dir.dropLast()) : dir
    let ns = trimmed as NSString
    return (ns.lastPathComponent, ns.deletingLastPathComponent)
}

private extension FrameSavingState {
    var int32Value: Int32 {
        switch self {
        case .notSaving:   return 0
        case .inPurgatory: return 1
        case .savePending: return 2
        case .saving:      return 3
        }
    }
}

private extension OutlierLoadingState {
    var int32Value: Int32 {
        switch self {
        case .unloaded: return 0
        case .loading:  return 1
        case .loaded:   return 2
        }
    }
}
