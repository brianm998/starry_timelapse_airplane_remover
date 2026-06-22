import Foundation
import StarCore
import StarDaemonMessages
import logging
import Semaphore

// Mirrors cli/Processor but lives in the daemon and stays resident.
actor Session {
    let sessionID: String
    let scratchSessionDir: String

    private(set) var configManager: ConfigManager
    private(set) var imageSequence: ImageSequence
    private(set) var frames: [FrameAirplaneRemover] = []
    private(set) var imageInfo: ImageInfo

    // Active progress stream continuation — set when Processing.StreamProgress is open.
    var progressContinuation: AsyncStream<Star_V1_ProgressEvent>.Continuation?

    // Processing task — set when Processing.Start is called.
    private var processingTask: Task<Void, Never>?

    init(
        sessionID: String,
        scratchSessionDir: String,
        configManager: ConfigManager,
        imageSequence: ImageSequence,
        imageInfo: ImageInfo
    ) {
        self.sessionID = sessionID
        self.scratchSessionDir = scratchSessionDir
        self.configManager = configManager
        self.imageSequence = imageSequence
        self.imageInfo = imageInfo
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

    // Start processing (calls frameGraphBuilder.build).
    func startProcessing() async {
        guard processingTask == nil else { return }
        await frameGraphBuilder.set(configManager: configManager)
        let fs = frames
        let weakSelf = WeakSessionRef(self)
        processingTask = Task {
            let sem = AsyncSemaphore(value: 0)
            await frameGraphBuilder.build(frames: fs) { _ in sem.signal() } errorClosure: { _ in }
            await sem.wait()
            await weakSelf.session?.emitSequenceState("done")
            await weakSelf.session?.clearProcessingTask()
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
    }

    private func clearProcessingTask() {
        processingTask = nil
    }

    // Called by Dispatcher when the Processing.StreamProgress stream is opened.
    func setProgressContinuation(_ cont: AsyncStream<Star_V1_ProgressEvent>.Continuation?) {
        progressContinuation = cont
    }

    // MARK: - StarCore callback bridges

    private func onFrameStateChange(frame: FrameAirplaneRemover, state: FrameProcessingState) {
        var ev = Star_V1_FrameStateEvent()
        ev.frameIndex = Int32(frame.frameIndex)
        ev.state = Mapping.frameProcessingState(state)
        var prog = Star_V1_ProgressEvent()
        prog.kind = .frameState(ev)
        progressContinuation?.yield(prog)
    }

    private func onFrameSavingStateChange(frame: FrameAirplaneRemover, old: FrameSavingState, new: FrameSavingState) {
        var ev = Star_V1_FrameSavingEvent()
        ev.frameIndex = Int32(frame.frameIndex)
        ev.oldState = old.int32Value
        ev.newState = new.int32Value
        var prog = Star_V1_ProgressEvent()
        prog.kind = .frameSavingState(ev)
        progressContinuation?.yield(prog)
    }

    private func onExistingFrameStateChange(frameIndex: Int) {
        var prog = Star_V1_ProgressEvent()
        prog.kind = .frameExisting(Int32(frameIndex))
        progressContinuation?.yield(prog)
    }

    private func onOutliersLoaded(frameIndex: Int, state: OutlierLoadingState) {
        var ev = Star_V1_OutliersLoaded()
        ev.frameIndex = Int32(frameIndex)
        ev.state = state.int32Value
        var prog = Star_V1_ProgressEvent()
        prog.kind = .outliersLoaded(ev)
        progressContinuation?.yield(prog)
    }

    private func emitSequenceState(_ state: String) {
        var ev = Star_V1_SequenceStateEvent()
        ev.state = state
        var prog = Star_V1_ProgressEvent()
        prog.kind = .sequenceState(ev)
        progressContinuation?.yield(prog)
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

        var filenamePaths = sequenceDir.components(separatedBy: "/")
        let seqName = filenamePaths.isEmpty ? sequenceDir : (filenamePaths.removeLast().isEmpty && !filenamePaths.isEmpty ? filenamePaths.removeLast() : filenamePaths.last ?? sequenceDir)
        let seqPath = filenamePaths.joined(separator: "/").isEmpty ? "/" : filenamePaths.joined(separator: "/")

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

        let configFilename = "\(scratchSessionDir)/config.json"
        let configManager = await ConfigManager(configFilename: configFilename, config: config)
        await constants.set(detectionType: config.detectionType)

        let imageSequence = try ImageSequence(
            dirname: sequenceDir,
            supportedImageFileTypes: config.supportedImageFileTypes,
            maxImages: 40
        )
        let imageInfo = try await imageSequence.getImageInfo()
        IMAGE_WIDTH = Double(imageInfo.imageWidth)
        IMAGE_HEIGHT = Double(imageInfo.imageHeight)

        let session = Session(
            sessionID: sessionID,
            scratchSessionDir: scratchSessionDir,
            configManager: configManager,
            imageSequence: imageSequence,
            imageInfo: imageInfo
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
        IMAGE_WIDTH = Double(imageInfo.imageWidth)
        IMAGE_HEIGHT = Double(imageInfo.imageHeight)

        let session = Session(
            sessionID: sessionID,
            scratchSessionDir: scratchSessionDir,
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
