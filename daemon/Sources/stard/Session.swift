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

    /// The source of this session's frames when they are still being extracted from a video; nil for an image sequence and for a video that
    /// was fully extracted before the session opened.
    nonisolated let extractionSource: FrameSource?

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

    /// The horizon refinement this sequence is owed after a reference horizon was repainted (StarCore's, the
    /// same record and rules as the macOS app's).
    private var horizonRefinement = HorizonRefinementPlan()

    /// The frames shown as waiting for it (macOS `FrameViewModel.isPendingHorizonRefinement`).  Not the plan's
    /// own sets: a frame in a run that has been claimed stays marked until its merge completes, and one that
    /// was never processed is unmarked as soon as the run is queued.
    private var refinementMarks: Set<Int> = []

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
        let source = imageSequence.source
        self.extractionSource = source.progress.isComplete ? nil : source
    }

    // Build FrameAirplaneRemover graph (does not start processing).  `report` is told how many frames have been loaded (a screen is
    // waiting on them), and a cancelled caller stops it between frames.
    func buildFrameGraph(report: OpenReport? = nil) async throws {
        let config = await configManager.config()
        let filenames = await imageSequence.filenames
        var frameIndexToBaseNameMap: [Int: String] = [:]
        for (i, fn) in filenames.enumerated() {
            frameIndexToBaseNameMap[i] = removePath(fromString: fn)
        }

        let weakSelf = WeakSessionRef(self)
        // Told whenever a preview is written, which is how a client learns that the picture it has is old.
        var imageAccessor = ImageAccessor(
            config: config,
            imageSequence: imageSequence,
            frameIndexToBaseNameMap: frameIndexToBaseNameMap
        ) { _, frameIndex, type, size in
            guard size == .preview else { return }
            Task { await weakSelf.session?.onImageSaved(frameIndex: frameIndex, type: type) }
        }
        // Told whenever a frame's horizon lines change, so the client draws them again.
        imageAccessor.horizonChangedClosure = { frameIndex in
            Task { await weakSelf.session?.horizonRefined(frameIndex: frameIndex) }
        }

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
        built.reserveCapacity(filenames.count)
        var lastReported = Date.distantPast
        report?(OpenEvents.loaded(0, of: filenames.count))
        for (frameIndex, filename) in filenames.enumerated() {
            try Task.checkCancellation()
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
            // At most about twenty a second: a thousand frames is a thousand tiny messages otherwise, and nobody reads them that fast.
            let now = Date()
            if let report, built.count == filenames.count || now.timeIntervalSince(lastReported) >= 0.05 {
                lastReported = now
                report(OpenEvents.loaded(built.count, of: filenames.count))
            }
        }
        try Task.checkCancellation()
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

    /// The background pre-warm of thumbnails and previews (`PreviewPrewarm`), started when the session is open for a client and stopped when it closes.
    private var previewPrewarm: Task<Void, Never>?

    /// Start making the thumbnails and previews this sequence is missing, at the back of the preview queue.  Once per session.
    func startPreviewPrewarm() {
        guard previewPrewarm == nil, !closed, !frames.isEmpty else { return }
        let frames = frames
        previewPrewarm = Task.detached(priority: .utility) { await PreviewPrewarm.run(frames: frames) }
    }

    /// `Sequence.GetKeypointAdvice`: whether full resolution keypoint detection suits this sequence on this machine.  Asked fresh each time, since
    /// it depends on the settings that move it (use of this Mac, concurrency).
    func keypointAdvice() async -> Star_V1_KeypointDivisorAdvice {
        let memory = ProcessInfo.processInfo.physicalMemory
        var out = Star_V1_KeypointDivisorAdvice()
        out.physicalMemoryBytes = memory
        guard let advice = await configManager.config().keypointDivisorAdvice(physicalMemory: memory) else { return out }
        out.available = true
        out.reduceRecommended = advice.reduceRecommended
        out.recommendedDivisor = advice.recommendedDivisor
        out.thresholdPixels = Int64(advice.thresholdPixels)
        out.imagePixels = Int64(advice.imagePixels)
        out.fullResolutionConcurrency = Int32(advice.fullResolutionConcurrency)
        out.frameConcurrency = Int32(advice.frameConcurrency)
        return out
    }

    /// How far a previous run got on this sequence, as the files it left say (`Sequence.GetProgressSurvey`).  A few `stat`s per frame, so
    /// it is cheap to ask on the way into a reopened sequence; takes what is on disk at face value.
    func surveyProgress() async -> SequenceProgress {
        let manager = configManager
        let (config, homographies) = await MainActor.run { (manager.config(), manager.homographyDatabase) }
        return await SequenceProgressSurvey.survey(frames: frames, config: config, homographyDatabase: homographies)
    }

    /// Apply the settings a client sent (`Sequence.UpdateConfig`) and persist them.  Returns the
    /// config as it now stands.
    func updateConfig(from proto: Star_V1_Config) async -> Config {
        let config = Session.applying(proto, to: await configManager.config())
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

    /// `config` with the settings a client sent applied to it: what `updateConfig(from:)` would leave, without leaving it.
    static func applying(_ proto: Star_V1_Config, to config: Config) -> Config {
        var config = config
        config.cleanMethod = Mapping.cleanMethod(from: proto)
        config.detectionType = Mapping.detectionType(from: proto.detectionType)
        config.horizonDetectionEnabled = proto.horizonDetectionEnabled
        config.tripodHeadWasMoving = proto.tripodHeadWasMoving
        if proto.numberOfFramesToProcessConcurrently > 0 {
            config.numberOfFramesToProcessConcurrently = Int(proto.numberOfFramesToProcessConcurrently)
        }
        Mapping.applyExpertConfig(&config, from: proto)
        return config
    }

    // MARK: - Settings changes over finished work

    /// The settings the last run began with, which a settings change is compared against to tell whether it contradicts the frames on disk
    /// (macOS `settingsSnapshot`).  Taken when a run starts, since the run adopts whatever the settings then are; until one has, the first
    /// question asked takes it from the config as it stood then, so a change the user made and put off is still a change the frames lack.
    private(set) var settingsSnapshot: Config?

    /// Whether the survey taken when this session opened found nothing done to the sequence; nil before it has been taken.
    var openedSequenceWasUntouched: Bool?

    /// What applying `proto` would do to the work already on disk, without applying it (`Sequence.PreviewConfigChange`): which cached stages it
    /// would invalidate, and whether there is finished work for that to contradict (StarCore's `SettingsChangeState`).
    func previewConfigChange(_ proto: Star_V1_Config) async -> Star_V1_ConfigChangePreview {
        let current = await configManager.config()
        let snapshot = settingsSnapshot ?? current
        if settingsSnapshot == nil { settingsSnapshot = current }

        let proposed = Session.applying(proto, to: current)
        let stale = ArtifactInputs.current(from: proposed).staleStages(comparedTo: ArtifactInputs.current(from: snapshot))

        // The counts are only worth a look at each frame when they can matter: a live run counts before its first frame is written, and
        // nothing counts when no stage is stale.
        let isProcessing = activeRun != nil
        var complete = 0
        var userModified = 0
        if !stale.isEmpty && !isProcessing {
            for frame in frames {
                switch await frame.processingState() {
                case .complete: complete += 1
                case .userModified: userModified += 1
                default: break
                }
            }
        }
        var out = Star_V1_ConfigChangePreview()
        out.staleStages = ArtifactStage.allCases.filter { stale.contains($0) }.map(\.rawValue)
        out.contradictsFinishedWork = SettingsChangeState.contradictsFinishedWork(
            isProcessingFrames: isProcessing, completeFrameCount: complete, userModifiedFrameCount: userModified,
            openedSequenceWasUntouched: openedSequenceWasUntouched, changedStages: stale)
        return out
    }

    /// For tests: stand in for the survey `didOpen()` takes.
    func setOpened(untouched: Bool?) { openedSequenceWasUntouched = untouched }

    /// Called once the session is open for a client: takes the survey the settings question needs and starts the background previews.
    func didOpen() async {
        openedSequenceWasUntouched = await surveyProgress().isUntouched
        startPreviewPrewarm()
        startExtractionForwarding()
    }

    // MARK: - Frames that are still being extracted

    private var extractionForwarding: Task<Void, Never>?
    private var previewWriter: FramePreviewWriter?

    /// Tell every progress subscriber how the extraction of the video's frames is going (throttled to about four a second, with the
    /// frames that arrived batched into ranges), and write each frame's previews as it lands.  A session whose frames are all there has
    /// nothing to forward.
    private func startExtractionForwarding() {
        guard let source = extractionSource, extractionForwarding == nil, !closed else { return }
        if let first = frames.first {
            let weakSelf = WeakSessionRef(self)
            let writer = FramePreviewWriter(source: source, imageAccessor: first.imageAccessor) { frameIndex in
                await weakSelf.session?.onImageSaved(frameIndex: frameIndex, type: .original)
            }
            writer.start()
            previewWriter = writer
        }
        extractionForwarding = Task.detached(priority: .utility) { [weak self] in
            var pending = IndexSet()
            var lastSent = Date.distantPast
            var finished = false
            for await event in source.events() {
                switch event {
                case .snapshot, .progress: break
                case .framesAvailable(let set): pending.formUnion(set)
                case .frameCountSettled, .frameFailed, .failed, .finished: finished = true
                }
                let now = Date()
                // One update per quarter second, and always the last word.
                guard finished || now.timeIntervalSince(lastSent) >= 0.25 else { continue }
                lastSent = now
                await self?.sendExtraction(source: source, newlyAvailable: pending)
                pending = IndexSet()
            }
            await self?.sendExtraction(source: source, newlyAvailable: pending)
        }
    }

    private func sendExtraction(source: FrameSource, newlyAvailable: IndexSet) {
        if !newlyAvailable.isEmpty {
            var available = Star_V1_FramesAvailable()
            available.ranges = Mapping.frameRanges(newlyAvailable)
            var prog = Star_V1_ProgressEvent()
            prog.kind = .framesAvailable(available)
            emit(prog)
        }
        var prog = Star_V1_ProgressEvent()
        prog.kind = .frameExtraction(Mapping.frameExtraction(of: source, snapshot: false))
        emit(prog)
    }

    /// `Frame.Prioritize`: what the user is looking at, so the extractor fetches it first where the video allows.
    func prioritizeFrames(viewing: Int, nearby: [Int]) {
        guard let source = extractionSource, !closed else { return }
        source.prioritize([viewing], reason: .userViewing)
        if !nearby.isEmpty { source.prioritize(nearby, reason: .userNearby) }
    }

    /// `Frame.GetEta`: how long until a frame that is not extracted yet is, for the wait panel.
    func frameEta(_ index: Int) -> Star_V1_FrameEtaResponse {
        var out = Star_V1_FrameEtaResponse()
        let source = imageSequence.source
        if source.isAvailable(index) { out.available = true; out.fraction = 1; return out }
        if case .failed(let message) = source.availability(index) { out.error = message; return out }
        out.sweepHead = Int32(source.sweepHead ?? 0)
        out.jump = source.isBeingJumpedTo(index)
        if let seconds = source.estimatedSecondsUntilAvailable(index) {
            out.known = true
            out.seconds = seconds
        }
        // How far along: for the in-order extraction, the head's share of the way to this frame; for a jump the estimate itself is the best
        // there is, so the bar follows the time left against the time it was first thought to take.
        let head = Int(out.sweepHead)
        if !out.jump, index > 0 { out.fraction = min(1, Double(head) / Double(index)) }
        return out
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
        // The run adopts whatever the settings now are, so this is the baseline the next settings change is compared against.
        settingsSnapshot = await configManager.config()
        await beginStepReports(generation: generation, types: ProcessingSteps.types(for: await configManager.config()))
        // Before the graph is built, which surveys the disk: a horizon reference the user painted and put off
        // applying is taken on by this run, so starting one is a way through it and not a way around it.  Over
        // this run's own range only, so a reference whose span reaches past it stays pending for the frames
        // it will not touch.
        let lastFrame = frames.count - 1
        let first = max(0, startIndex)
        let last = endIndex.map { min($0, lastFrame) } ?? lastFrame
        await applyPendingHorizonRefinementToRun(range: first <= last ? first...last : nil)
        // A stop that came in while that ran has already ended this run.
        guard activeRun == generation, !closed else { return }
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
    private func runCompleted(generation: Int, errors errorList: [String], whenCurrent: (() -> Void)? = nil) async {
        guard activeRun == generation else {
            Log.i("stard: ignoring the completion of a stopped processing run")
            return
        }
        await endStepReports(generation: generation)
        whenCurrent?()
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
        stepReportTask?.cancel()
        stepReportTask = nil
        stepReports = nil
        // A horizon refinement that is stopped gives back what it claimed, so it can be run again.
        if let affected = horizonRefinement.returnInFlight() {
            refinementMarks.formUnion(affected)
        }
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

    /// `Processing.Restart`: stop the run in progress, wait until it has stopped, and start over the same range with whatever the settings now
    /// are.  The stop is not announced: to a client watching, a restart is not a run that was cancelled.  Without a run it is a start.
    func restartProcessing(startIndex: Int = 0, endIndex: Int? = nil) async {
        guard !closed else { return }
        await stopRun(announce: false)
        await startProcessing(startIndex: startIndex, endIndex: endIndex)
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

    // MARK: - Horizon refinement

    // MARK: - Step progress

    /// What a run's step reports are measured against, and what they say about steps.
    private struct StepReports {
        let generation: Int
        let types: [OperationType]
        let baseline: StepProgressReport.Sample
        let status: String?
    }
    private var stepReports: StepReports?
    private var stepReportTask: Task<Void, Never>?
    private var lastStepReport: Star_V1_StepProgress?

    /// Report each step of the run `generation` about four times a second for as long as it changes (`ProgressEvent.step_progress`), measured
    /// from now.  `status` is for a run that cannot be counted in operations.
    private func beginStepReports(generation: Int, types: [OperationType], status: String? = nil) async {
        stepReportTask?.cancel()
        let baseline = await StepProgressReport.sample()
        stepReports = StepReports(generation: generation, types: types, baseline: baseline, status: status)
        lastStepReport = nil
        stepReportTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let session = self else { return }
                await session.reportSteps(generation: generation)
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func reportSteps(generation: Int) async {
        guard let context = stepReports, context.generation == generation, activeRun == generation, !closed else { return }
        let report = StepProgressReport.make(types: context.types, now: await StepProgressReport.sample(),
                                             baseline: context.baseline, status: context.status ?? waitingForFramesStatus())
        guard report != lastStepReport else { return }
        lastStepReport = report
        var prog = Star_V1_ProgressEvent()
        prog.kind = .stepProgress(report)
        emit(prog)
    }

    /// What a run that is waiting on a video's frames says, so that it is not taken for a hang: nil once they are all out.
    private func waitingForFramesStatus() -> String? {
        guard let source = extractionSource else { return nil }
        let progress = source.progress
        guard !progress.isComplete, progress.error == nil, progress.total > 0 else { return nil }
        return localized("ui.processing_waiting_for_frames", progress.extracted * 100 / progress.total)
    }

    /// The run is over: one last report, so the bars end where the run did, and no more.
    private func endStepReports(generation: Int) async {
        await reportSteps(generation: generation)
        stepReportTask?.cancel()
        stepReportTask = nil
        stepReports = nil
    }

    /// Whether `frameIndex` is waiting for horizon refinement.
    func isRefinementPending(_ frameIndex: Int) -> Bool { refinementMarks.contains(frameIndex) }

    /// Whether any horizon refinement is waiting (`Horizon.GetRefinementStatus`), and how many frames are marked.
    func horizonRefinementStatus() -> (pending: Bool, markedFrames: Int) {
        (horizonRefinement.hasPending(hasOutput: { hasHorizonOutput($0) }), refinementMarks.count)
    }

    /// A frame's `FrameInfo`, with what only the session knows.
    func frameInfo(_ frame: FrameAirplaneRemover, outlierGroups: OutlierGroups?) async -> Star_V1_FrameInfo {
        var info = await Mapping.frameInfo(frame: frame, outlierGroups: outlierGroups)
        info.refinementPending = refinementMarks.contains(frame.frameIndex)
        let config = await configManager.config()
        let index = frame.frameIndex
        info.cleanMethodOverridden = config.pixelReplacementOverrides[index] != nil
        info.alignedNeighborCount = Int32(config.numberAlignedNeighborFrames(for: index))
        info.alignedNeighborOverridden = config.alignedNeighborFrameOverrides[index] != nil
        info.staticNeighborCount = Int32(config.numberStaticNeighborFrames(for: index))
        info.staticNeighborOverridden = config.staticNeighborFrameOverrides[index] != nil
        return info
    }

    // MARK: - Per-frame settings

    /// Make `method` the clean method of `frame` alone (macOS `set(cleanMethod:forFrame:)`): in the frame, and as an override in the
    /// config, which is what a reopened session reads it back from.  The finished image depends on the method, so it is written again.
    func setCleanMethod(_ method: CleanMethod, of frame: FrameAirplaneRemover) async {
        await frame.set(cleanMethod: method)
        var config = await configManager.config()
        config.pixelReplacementOverrides[frame.frameIndex] = method
        await configManager.update(config)
        await configManager.flush()
        await frame.markAsChanged()
        await frameEdited(frame)
    }

    /// Give `frame` its own neighbour count of `kind`, or with a nil `count` take its own away; and do what the change calls for
    /// (macOS `set(alignedNeighborFrames:forFrame:)` and the others).  A new aligned count invalidates the frame's star alignment, and if
    /// it had one the frame is processed again: true when that is under way.  A new static count builds the merged horizon again if
    /// there was one.
    func setNeighborOverride(of frame: FrameAirplaneRemover, kind: NeighborKind, count: Int?) async -> Bool {
        var config = await configManager.config()
        let index = frame.frameIndex
        switch kind {
        case .aligned: config.alignedNeighborFrameOverrides[index] = count
        case .static:  config.staticNeighborFrameOverrides[index] = count
        }
        await configManager.update(config)
        await configManager.flush()

        switch kind {
        case .aligned:
            await frame.setNumberOfAlignedFrames()
            let invalidated = (try? await frame.invalidateStarAlignmentIfExists()) ?? false
            guard invalidated, !closed else { return false }
            await startProcessing(startIndex: index, endIndex: index)
            return activeRun != nil
        case .static:
            await frame.setNumberOfStaticNeighborFrames()
            try? await frame.recomputeMergedHorizonIfExists()
            return false
        }
    }

    enum NeighborKind { case aligned, `static` }

    /// Whether a frame has output the horizon went into, and so has to be rendered again when it moves.
    private func hasHorizonOutput(_ index: Int) -> Bool {
        guard let frame = frame(at: index) else { return false }
        return HorizonRefinementPlan.outputTypes.contains {
            frame.imageAccessor.imageExists(frameIndex: index, ofType: $0, atSize: .original)
        }
    }

    /// Every frame that has a painted reference horizon, in frame order.
    private func referenceHorizonFrameIndices() -> [Int] {
        frames.indices.filter {
            frames[$0].imageAccessor.imageExists(frameIndex: $0, ofType: .userHorizon, atSize: .original)
        }
    }

    /// The reference horizon of `frameIndex` was saved (`Horizon.ReferenceUpdated`).  With `applyToNearby`, the
    /// frames that interpolate from it are marked pending, and the numbers the "now or later?" question quotes
    /// are returned; nil when it is not asked, either because nearby frames were not to be touched or because
    /// there is nothing to redo (in which case the bookkeeping is cleared, which is all a run would do).
    func horizonReferenceUpdated(frameIndex: Int, applyToNearby: Bool) async -> HorizonRefinementPlan.PromptCounts? {
        guard applyToNearby else { return nil }
        let change = horizonRefinement.recordReferenceUpdated(
          frameIndex: frameIndex,
          referenceIndices: referenceHorizonFrameIndices(),
          frameCount: frames.count
        )
        refinementMarks.subtract(change.noLongerPending)
        refinementMarks.formUnion(change.nowPending)

        guard let counts = horizonRefinement.promptCounts(hasOutput: { hasHorizonOutput($0) }) else {
            _ = await runHorizonRefinement()
            return nil
        }
        return counts
    }

    /// "Later": keep the work pending, but take away what the horizon the user has just corrected was already
    /// baked into.
    ///
    /// Saying later used to leave the sequence looking finished.  Every affected frame kept the render made
    /// with the old horizon, so "Render Video" stayed live over frames the user had just told star were wrong.
    /// Deleting that output is what makes the state honest, and it is the same output the run would have
    /// deleted anyway; the only difference is that nothing is rendered to replace it yet.  The stale merged
    /// horizon masks go too, which is what makes "later" survive the daemon being restarted: the plan is only
    /// in memory, but a frame with no merged mask and no output is a frame every run already knows to redo.
    func deferHorizonRefinement() async {
        let references = horizonRefinement.updatedReferences
        var maskFrames: [FrameAirplaneRemover] = []
        var stripped = Set<Int>()
        for i in horizonRefinement.deferralFrameIndices {
            guard let frame = frame(at: i) else { continue }
            maskFrames.append(frame)
            if hasHorizonOutput(i) { stripped.insert(i) }
        }
        guard !maskFrames.isEmpty else { return }
        horizonRefinement.markStripped(stripped)
        let outputFrames = maskFrames.filter { stripped.contains($0.frameIndex) }
        await HorizonRefinementEffects.strip(references: references, maskFrames: maskFrames, outputFrames: outputFrames)
        Log.i("stard: horizon refinement deferred over \(maskFrames.count) frames, \(stripped.count) of which lost their output")
    }

    /// Fold pending horizon refinement into a run that is about to start (see `HorizonRefinementEffects.strip`).
    /// `range` is the frames the run covers, or nil for the whole sequence.
    private func applyPendingHorizonRefinementToRun(range: ClosedRange<Int>?) async {
        guard let taken = horizonRefinement.take(range: range) else { return }
        Log.i("stard: processing run is taking on \(taken.frames.count) of \(taken.pendingCount) frames of pending horizon refinement")
        var maskFrames: [FrameAirplaneRemover] = []
        var outputFrames: [FrameAirplaneRemover] = []
        for i in taken.frames.sorted() {
            guard let frame = frame(at: i) else { continue }
            maskFrames.append(frame)
            if hasHorizonOutput(i) { outputFrames.append(frame) }
            refinementMarks.remove(i)
        }
        await HorizonRefinementEffects.strip(references: taken.referencesToClear, maskFrames: maskFrames, outputFrames: outputFrames)
    }

    /// "Now" / "Re-run Horizon Refinement": claim everything pending and queue it as a run (`Horizon.RunRefinement`).
    /// Returns once it is queued; it ends like any run, with a `sequence_state` event, and a stop gives the work
    /// back.  False if there was nothing to run, or a run was already going.
    @discardableResult
    func runHorizonRefinement() async -> Bool {
        await stopTask?.value
        guard !closed else { return false }
        guard activeRun == nil else {
            Log.w("stard: not starting a horizon refinement while a processing run is going")
            return false
        }
        let claim = horizonRefinement.claimAll()
        let toProcess = claim.affected
        let toInvalidate = claim.references
        let toRestore = claim.stripped

        var refinementFrames: [FrameAirplaneRemover] = []
        var framesToMerge: [FrameAirplaneRemover] = []
        var mergeIndices = Set<Int>()
        for i in toProcess.union(toInvalidate).union(toRestore).sorted() {
            guard let frame = frame(at: i) else { continue }
            // Affected interpolated frames need their merged horizon recomputed.
            if toProcess.contains(i) { refinementFrames.append(frame) }
            // Re-queue any frame that already has final output, and any that "Later" already took the output of.
            if toRestore.contains(i) || hasHorizonOutput(i) {
                framesToMerge.append(frame)
                mergeIndices.insert(i)
            } else {
                // Never processed: nothing to re-render, and the pipeline uses the new horizon when it first
                // reaches this frame.  Clear the mark now.
                refinementMarks.remove(i)
            }
        }
        guard !refinementFrames.isEmpty || !framesToMerge.isEmpty else {
            horizonRefinement.finishClaim()
            return false
        }

        await frameGraphBuilder.set(configManager: configManager)
        runGeneration += 1
        let generation = runGeneration
        activeRun = generation
        // The steps this run takes are known now rather than guessed at: a row for each it is about to put on the queue, and a line that
        // says what it is doing, since there is no frame graph to count (macOS passes exactly these to its modal).
        var refinementSteps: [OperationType] = []
        if !refinementFrames.isEmpty { refinementSteps.append(.mergedHorizon) }
        // The consensus lines of the refined and re-merged frames are anchored on the edited references, so they are built again.
        if HorizonConsensus.applies(to: await configManager.config()) { refinementSteps.append(.horizonConsensus) }
        if !framesToMerge.isEmpty { refinementSteps.append(.merge) }
        let sequenceFrames = frames
        await beginStepReports(generation: generation, types: refinementSteps,
                               status: localized("ui.horizon_refinement_preparing", framesToMerge.count))
        let weakSelf = WeakSessionRef(self)
        let merging = framesToMerge
        let refining = refinementFrames
        let merged = mergeIndices
        let build = Task {
            await HorizonRefinementEffects.prepareRerun(references: toInvalidate, mergeFrames: merging)
            guard !Task.isCancelled else { return }
            Log.i("stard: horizon refinement: \(refining.count) horizons and \(merging.count) merges to queue")
            await frameGraphBuilder.enqueueHorizonRefinement(
              refinementFrames: refining,
              mergeFrames: merging,
              sequenceFrames: sequenceFrames,
              refinementCompletion: { frame in
                  await weakSelf.session?.horizonRefined(frameIndex: frame.frameIndex)
              },
              errorClosure: { errorString in Log.e("stard: op error: \(errorString)") }
            ) { errors in
                Task { await weakSelf.session?.refinementCompleted(generation: generation, errors: errors, mergedFrames: merged) }
            }
        }
        buildTask = build
        await build.value
        return true
    }

    /// One frame's horizon lines changed — a mask of any kind written or deleted, a reference painted or cleared, a refinement
    /// finished: tell the client to draw them again.
    private func horizonRefined(frameIndex: Int) {
        var prog = Star_V1_ProgressEvent()
        prog.kind = .horizonUpdated(Int32(frameIndex))
        emit(prog)
    }

    /// The refinement run finished: its frames are no longer pending, and it keeps what it claimed.
    private func refinementCompleted(generation: Int, errors: [String], mergedFrames: Set<Int>) async {
        await runCompleted(generation: generation, errors: errors) { [self] in
            refinementMarks.subtract(mergedFrames)
            horizonRefinement.finishClaim()
        }
    }

    // MARK: - Closing

    /// End the session (`Session.Close`): stop the run in flight and wait for it to drain, write
    /// out what is still pending, and end every progress stream, so that nothing keeps running
    /// against a session that is about to be dropped (the frame-graph builder is shared, and the
    /// next session repoints it).  Safe to call more than once.
    func close() async {
        closed = true
        previewPrewarm?.cancel()
        previewPrewarm = nil
        // What is extracted stays, and the folder says it is not complete, so a reopen carries on.
        extractionSource?.stop()
        extractionForwarding?.cancel()
        extractionForwarding = nil
        previewWriter?.stop()
        previewWriter = nil
        // Only a session with a run of its own has anything to stop: the frame-graph builder is
        // shared, and stopping it would also stop a run that belongs to another session.
        if activeRun != nil || stopTask != nil {
            await stopRun(announce: false)
        }
        await flushSaves()
        await configManager.flush()
        // This sequence's cached reference statistics must not outlive it (another session may
        // open a sequence whose frames share these indices).
        await ReferenceHorizonStatsRegistry.shared.removeAll()
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

    /// Write `frame`'s finished image from its current decisions right now, instead of when its save
    /// timer fires, and return once it is written (macOS "Render this frame": `FrameSaveQueue.saveNow`
    /// loads the frame's outliers, finishes it and marks it handled).  A save of the frame already under
    /// way is let finish first, since it may have begun before the latest edit.  False if the frame could
    /// not be saved, or the save did not end within `timeout`.
    func renderNow(_ frame: FrameAirplaneRemover, timeout: Duration = .seconds(600)) async -> Bool {
        // A closed session has no save queue worth feeding, and a cancelled caller no longer wants this.
        if closed || Task.isCancelled { return false }
        let deadline = ContinuousClock.now + timeout
        guard await waitForSave(of: frame, until: deadline) else { return false }
        guard await beginSave(frame) else { return false }
        guard await waitForSave(of: frame, until: deadline) else { return false }
        // The final preview is normally announced as it is written, but only when the config has
        // previews written; say so here regardless, since the render is what the client asked for.
        onImageSaved(frameIndex: frame.frameIndex, type: .final)
        return true
    }

    /// Save every frame whose edits are still waiting (in purgatory, or already queued or being
    /// saved) and return once they have all been written.  A frame is never saved twice: one
    /// that is already past purgatory is only waited for.  Gives up after `timeout` rather than
    /// holding a close or a shutdown hostage to a save that never ends.
    func flushSaves(timeout: Duration = .seconds(120)) async {
        var waiting: [FrameAirplaneRemover] = []
        for frame in frames {
            switch await frame.savingState() {
            case .notSaving:
                continue
            case .inPurgatory:
                _ = await beginSave(frame)
            case .savePending, .saving:
                break
            }
            waiting.append(frame)
        }
        guard !waiting.isEmpty else { return }
        Log.i("stard: waiting for \(waiting.count) frame(s) to finish saving")
        let deadline = ContinuousClock.now + timeout
        for frame in waiting {
            guard await waitForSave(of: frame, until: deadline) else {
                Log.e("stard: gave up waiting for frame \(frame.frameIndex) to finish saving")
                return
            }
        }
    }

    /// Start saving `frame` at once, without waiting for it.  False if there is nothing to start: no
    /// queue, a save already under way, or one that could not be started.
    private func beginSave(_ frame: FrameAirplaneRemover) async -> Bool {
        guard let saveQueue else { return false }
        switch await frame.savingState() {
        case .savePending, .saving: return false
        case .notSaving, .inPurgatory: break
        }
        // Claim it before the queue's own timer can: that only saves a frame still in purgatory
        // when it fires.  The save itself is what puts it back to `notSaving`.
        await frame.set(frameSavingState: .savePending)
        do {
            try await saveQueue.saveNow(frame: frame) { }
            return true
        } catch {
            Log.e("stard: could not save frame \(frame.frameIndex): \(error)")
            await frame.set(frameSavingState: .notSaving)
            return false
        }
    }

    /// Wait until `frame` is no longer queued or being saved.  Frames in purgatory are not waited for:
    /// that is ten seconds of nothing.  False if `deadline` came first.
    private func waitForSave(of frame: FrameAirplaneRemover, until deadline: ContinuousClock.Instant) async -> Bool {
        while true {
            switch await frame.savingState() {
            case .notSaving, .inPurgatory: return true
            case .savePending, .saving: break
            }
            if ContinuousClock.now > deadline { return false }
            // `try?` here turned a cancelled caller into a busy loop: sleep throws at once when the
            // task is cancelled, the error was dropped, and the loop spun on `savingState()` with no
            // pause until the deadline. A cancelled wait is over.
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return false }
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
        // A video whose frames are still arriving: which are there, in full, before the deltas that follow.
        if let source = extractionSource {
            var prog = Star_V1_ProgressEvent()
            prog.kind = .frameExtraction(Mapping.frameExtraction(of: source, snapshot: true))
            cont.yield(prog)
        }
        // Where the run in progress has got, which would otherwise not be heard until its next change.
        if let report = lastStepReport {
            var prog = Star_V1_ProgressEvent()
            prog.kind = .stepProgress(report)
            cont.yield(prog)
        }
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
        // Progress into the run marker, so a report of a killed run can say how far it got (what the macOS app records as it goes).
        Task { await RunMarkerStore.shared.note(phase: "\(state)", frameCompleted: state == .complete ? frame.frameIndex : nil) }
        var ev = Star_V1_FrameStateEvent()
        ev.frameIndex = Int32(frame.frameIndex)
        ev.state = Mapping.frameProcessingState(state)
        var prog = Star_V1_ProgressEvent()
        prog.kind = .frameState(ev)
        emit(prog)
    }

    func onFrameSavingStateChange(frame: FrameAirplaneRemover, old: FrameSavingState, new: FrameSavingState) {
        var ev = Star_V1_FrameSavingEvent()
        ev.frameIndex = Int32(frame.frameIndex)
        ev.oldState = old.int32Value
        ev.newState = new.int32Value
        var prog = Star_V1_ProgressEvent()
        prog.kind = .frameSavingState(ev)
        emit(prog)
        // A save that has just finished rewrote the frame's final image.  `ImageAccessor` announces that only for the
        // preview size, and previews are written only when `writeFramePreviewFiles` is on (it is off by default), so
        // without this a client showing the frame never hears that an edit it made was rendered, and keeps the old
        // picture until the user changes frame or asks for "Render Updates".
        if old == .saving, new == .notSaving {
            onImageSaved(frameIndex: frame.frameIndex, type: .final)
        }
    }

    private func onImageSaved(frameIndex: Int, type: FrameViewMode) {
        guard let mode = Mapping.protoFrameViewMode(type) else { return }
        var ev = Star_V1_ImageSaved()
        ev.frameIndex = Int32(frameIndex)
        ev.viewMode = mode
        var prog = Star_V1_ProgressEvent()
        prog.kind = .imageSaved(ev)
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
    /// Where a session opened from a sequence or a video keeps its config.json: in the sequence's own
    /// temp output directory, which is where the macOS app writes it (`ConfigManager` handed the bare
    /// name "config.json").  That is what makes it a path a client can record and open again, from either
    /// client; the per-session scratch dir is a different one every time.
    static func configJsonPath(for config: Config) -> String {
        config.jsonPath(named: "config.json")
    }

    // Open a sequence directory and build the session.
    static func openSequence(
        sessionID: String,
        scratchSessionDir: String,
        sequenceDir: String,
        protoConfig: Star_V1_Config,
        report: @escaping OpenReport = { _ in }
    ) async throws -> Session {
        try FileManager.default.createDirectory(atPath: scratchSessionDir, withIntermediateDirectories: true)

        // The sequence's directory name and parent path. StarCore's ImageAccessor locates the
        // original frames at "\(imageSequencePath)/\(imageSequenceDirname)", so these must be exact.
        let (seqName, seqPath) = splitDirPath(sequenceDir)
        report(OpenEvents.stage(.loadingFrames, name: seqName))

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

        let configFilename = Session.configJsonPath(for: config)
        let configManager = await ConfigManager(configFilename: configFilename, config: config)
        await configManager.save()   // the initial file; nothing has updated the manager yet
        await constants.set(detectionType: config.detectionType)

        // A folder of a video that was not fully extracted carries on from the frames that are there.
        let imageSequence = ImageSequence(
            source: try await FrameSourceFactory.open(directory: sequenceDir, supportedImageFileTypes: config.supportedImageFileTypes),
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
        try await session.buildFrameGraph(report: report)
        return session
    }

    // Decode a video file to frames (in `frameFormat`) and open as a session.
    // onProgress is called on each ffmpeg frame so the handler can stream IoProgress back to the client.
    static func openVideo(
        sessionID: String,
        scratchSessionDir: String,
        videoPath: String,
        protoConfig: Star_V1_Config,
        frameFormat: FrameDecodeFormat = .tiff16,
        extractInBackground: Bool = false,
        extractionSettings: FrameExtractionSettings = .default,
        report: @escaping OpenReport = { _ in }
    ) async throws -> Session {
        try FileManager.default.createDirectory(atPath: scratchSessionDir, withIntermediateDirectories: true)

        let videoName = (videoPath as NSString).lastPathComponent
        report(OpenEvents.stage(.examiningVideo, name: videoName))
        let sequenceDir: String
        let vi: VideoInfo
        let frameSource: FrameSource?
        if extractInBackground {
            // Answer once the first frame is out: the rest arrive while the session is open, and extraction belongs to the session
            // (it outlives this call), which stops it when it closes.  Cancelling the open still stops it and takes the folder back.
            report(OpenEvents.stage(.extractingFrames))
            let (source, info) = try await startVideoExtraction(named: videoPath, format: frameFormat, settings: extractionSettings)
            sequenceDir = source.outputFolder
            vi = info
            frameSource = source
        } else {
            let extracting = OnceFlag()
            let (dir, info) = try await decodeVideo(named: videoPath, format: frameFormat) { current, total, outputDir in
                if extracting.setOnce() { report(OpenEvents.stage(.extractingFrames)) }
                var io = Star_V1_IoProgress()
                io.current   = Int32(current)
                io.total     = Int32(total)
                io.outputDir = outputDir
                var progress = Star_V1_OpenProgress()
                progress.kind = .progress(io)
                report(progress)
            }
            sequenceDir = dir
            vi = info
            frameSource = nil
        }
        report(OpenEvents.stage(.loadingFrames))

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

        let configFilename = Session.configJsonPath(for: config)
        let configManager = await ConfigManager(configFilename: configFilename, config: config)
        await configManager.save()   // the initial file; nothing has updated the manager yet
        await constants.set(detectionType: config.detectionType)

        let source: FrameSource
        if let frameSource {
            source = frameSource
        } else {
            source = try await FrameSourceFactory.open(directory: sequenceDir, supportedImageFileTypes: config.supportedImageFileTypes)
        }
        let imageSequence = ImageSequence(source: source, maxImages: 40)
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
        try await session.buildFrameGraph(report: report)
        return session
    }

    // Open from a saved config.json.
    static func openConfig(
        sessionID: String,
        scratchSessionDir: String,
        configPath: String,
        report: @escaping OpenReport = { _ in }
    ) async throws -> Session {
        try FileManager.default.createDirectory(atPath: scratchSessionDir, withIntermediateDirectories: true)

        let configManager = try await ConfigManager(configFilename: configPath)
        let config = await configManager.config()
        report(OpenEvents.stage(.loadingFrames, name: config.imageSequenceDirname))
        await constants.set(detectionType: config.detectionType)

        let sequenceDir = "\(config.imageSequencePath)/\(config.imageSequenceDirname)"
        // A folder of a video that was not fully extracted carries on from the frames that are there.
        let imageSequence = ImageSequence(
            source: try await FrameSourceFactory.open(directory: sequenceDir, supportedImageFileTypes: config.supportedImageFileTypes),
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
        try await session.buildFrameGraph(report: report)
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

/// Told what opening a source is doing, as it does it.  Called from whatever thread the work is on.
typealias OpenReport = @Sendable (Star_V1_OpenProgress) -> Void

/// The events an open reports, built in one place.
enum OpenEvents {
    static func stage(_ stage: Star_V1_OpenStage, name: String = "") -> Star_V1_OpenProgress {
        var event = Star_V1_OpenStageEvent()
        event.stage = stage
        event.name = name
        var progress = Star_V1_OpenProgress()
        progress.kind = .stage(event)
        return progress
    }

    static func loaded(_ loaded: Int, of total: Int) -> Star_V1_OpenProgress {
        var event = Star_V1_FramesLoaded()
        event.loaded = Int32(loaded)
        event.total = Int32(total)
        var progress = Star_V1_OpenProgress()
        progress.kind = .loaded(event)
        return progress
    }
}

/// True the first time it is asked, from any thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    func setOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if set { return false }
        set = true
        return true
    }
}
