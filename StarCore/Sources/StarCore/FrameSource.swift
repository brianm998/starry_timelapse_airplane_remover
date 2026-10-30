import Foundation

// Where a sequence's original frames come from, and whether each of them is there yet.
//
// An image sequence has every frame from the start (`DirectoryFrameSource`).  A video's frames are
// extracted in the background (`VideoFrameSource`), so a client has to be able to ask whether a frame
// exists, wait for one, and say which ones it wants first.  See plans/STREAMING_FRAME_INTAKE_PLAN.md.

public enum FrameAvailability: Sendable, Equatable {
    case available
    /// Will be extracted; not yet.
    case pending
    /// Extraction of this frame failed for good.
    case failed(String)
}

public enum FramePriorityReason: Int, Sendable, Comparable {
    /// The in-order sweep.
    case background = 0
    /// An op the graph wants to run next.
    case pipeline
    /// Frames the temporal static horizon samples.
    case pipelineSample
    /// Around the frame the user is looking at.
    case userNearby
    /// The frame on screen right now.
    case userViewing

    public static func < (lhs: FramePriorityReason, rhs: FramePriorityReason) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Requests a long-GOP video acts on (the rest wait for the in-order sweep).
    public var isUserRequest: Bool { self >= .userNearby }
}

/// How cheaply a video gives up an arbitrary frame.
public enum FrameAccessKind: String, Sendable, Codable, Equatable {
    /// Intra-only (ProRes, DNxHD, MJPEG, ...): any frame can be extracted on its own, so any priority moves the extractor.
    case seekable
    /// Frames depend on earlier ones (H.264, H.265, ...): only the frame the user is looking at is worth a jump.
    case longGOP
}

public struct FrameExtractionProgress: Sendable, Equatable {
    public var extracted: Int
    public var total: Int
    /// Smoothed, for the estimate; nil until there is a sample.
    public var framesPerSecond: Double?
    public var isComplete: Bool
    /// nil for a directory.
    public var accessKind: FrameAccessKind?
    /// Non-empty when extraction failed for good.
    public var error: String?

    public init(extracted: Int, total: Int, framesPerSecond: Double? = nil, isComplete: Bool,
                accessKind: FrameAccessKind? = nil, error: String? = nil) {
        self.extracted = extracted
        self.total = total
        self.framesPerSecond = framesPerSecond
        self.isComplete = isComplete
        self.accessKind = accessKind
        self.error = error
    }

    /// Seconds the rest will take at the current rate; nil when there is no rate yet.
    public var estimatedSecondsRemaining: Double? {
        if isComplete { return 0 }
        guard let rate = framesPerSecond, rate > 0 else { return nil }
        return Double(max(0, total - extracted)) / rate
    }
}

public enum FrameSourceEvent: Sendable {
    /// Always the first event of a stream, so a late subscriber is complete.
    case snapshot(available: IndexSet, frameCount: Int, progress: FrameExtractionProgress)
    case framesAvailable(IndexSet)
    case frameFailed(Int, String)
    case progress(FrameExtractionProgress)
    case frameCountSettled(Int)
    case finished
    case failed(String)
}

public struct FrameSourceError: Error, LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Cancels a `whenAvailable` registration.  The callback is then called with `CancellationError`.
public struct FrameWaitToken: Sendable {
    private let action: @Sendable () -> Void
    public init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    public static let none = FrameWaitToken {}
    public func cancel() { action() }
}

/// How many ffmpeg processes may extract at once besides the in-order sweep.  Every limit lives here so that a measurement
/// can change it without a code change (`--extraction-jump-workers`, the proto's `ExtractionSettings`).
public struct FrameExtractionSettings: Sendable, Equatable, Codable {
    /// Extra ffmpeg processes extracting ahead of the sweep on an intra-only video.
    public var maxJumpWorkers: Int
    /// The same for a long-GOP video, where only the user's own frame starts one.
    public var maxLongGOPJumpWorkers: Int

    public static let defaultMaxJumpWorkers = 1
    public static let defaultMaxLongGOPJumpWorkers = 1

    public init(maxJumpWorkers: Int = FrameExtractionSettings.defaultMaxJumpWorkers,
                maxLongGOPJumpWorkers: Int = FrameExtractionSettings.defaultMaxLongGOPJumpWorkers) {
        self.maxJumpWorkers = max(0, maxJumpWorkers)
        self.maxLongGOPJumpWorkers = max(0, maxLongGOPJumpWorkers)
    }

    /// A value of 0 or less means "the default" (how a proto field that was never set reads).
    public init(jumpWorkers: Int, longGOPJumpWorkers: Int) {
        self.init(maxJumpWorkers: jumpWorkers > 0 ? jumpWorkers : Self.defaultMaxJumpWorkers,
                  maxLongGOPJumpWorkers: longGOPJumpWorkers > 0 ? longGOPJumpWorkers : Self.defaultMaxLongGOPJumpWorkers)
    }

    public static let `default` = FrameExtractionSettings()
    /// No jumps at all: one in-order sweep.
    public static let sweepOnly = FrameExtractionSettings(maxJumpWorkers: 0, maxLongGOPJumpWorkers: 0)
}

/// Where a sequence's original frames come from, and whether each is there yet.
public protocol FrameSource: Sendable {
    /// Total frames.  For a video whose header count was an estimate this can change once, when extraction finishes
    /// (`FrameSourceEvent.frameCountSettled`).
    var frameCount: Int { get }
    /// The path frame `index` has, or will have, once extracted.  Never blocks.
    func path(forFrame index: Int) -> String
    /// Non-waiting: is it there now.  Cheap: a lock and an `IndexSet`, no `stat`.
    func isAvailable(_ index: Int) -> Bool
    func availability(_ index: Int) -> FrameAvailability
    /// The frames that are there now.
    var availableFrames: IndexSet { get }
    /// Callback form of waiting, for callers that are not async (the C++ loader, AppKit).  Raises the frame's priority.
    /// The callback is called exactly once: with success when the frame is there, or with the failure.
    @discardableResult
    func whenAvailable(_ index: Int, _ callback: @escaping @Sendable (Result<Void, Error>) -> Void) -> FrameWaitToken
    /// Ask for frames to be extracted soon.  Never blocks.  No-op for a directory source.
    func prioritize(_ indices: [Int], reason: FramePriorityReason)
    /// Snapshot + live updates, for UIs and the daemon's progress stream.
    func events() -> AsyncStream<FrameSourceEvent>
    var progress: FrameExtractionProgress { get }
    /// Seconds until frame `index` is likely to be available; nil if unknown, 0 if available.
    func estimatedSecondsUntilAvailable(_ index: Int) -> Double?
    /// For a source that extracts: where the in-order sweep has got to (the wait panel says "extraction is at frame N").
    var sweepHead: Int? { get }
    /// Whether a jump to this frame is running or planned (the wait panel words itself differently).
    func isBeingJumpedTo(_ index: Int) -> Bool
    /// Stop extracting.  Frames already there stay.
    func stop()
}

extension FrameSource {
    /// Waiting: returns once the frame is on disk (throws on failure or cancellation).  Asking also raises the frame's
    /// priority, where the source can act on that.  Never parks a thread: the wait is a continuation.
    public func waitUntilAvailable(_ index: Int) async throws {
        if isAvailable(index) { return }
        let holder = WaitTokenHolder()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let token = whenAvailable(index) { continuation.resume(with: $0) }
                holder.set(token)
            }
        } onCancel: {
            holder.cancel()
        }
    }

    /// The blocking form, for the C++ loader's native thread.  Only ever call this off the cooperative pool: a pool thread
    /// parked here is one the extractor's own completion may need (see `shellOutOffPool`).
    public func waitUntilAvailableBlocking(_ index: Int) throws {
        if isAvailable(index) { return }
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = LockedBox<Result<Void, Error>?>(nil)
        whenAvailable(index) { result in
            outcome.set(result)
            semaphore.signal()
        }
        semaphore.wait()
        try outcome.get()?.get()
    }

    public func isBeingJumpedTo(_ index: Int) -> Bool { false }
}

/// The token of a wait that may be cancelled before the registration has even returned.
private final class WaitTokenHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var token: FrameWaitToken?
    private var cancelled = false

    func set(_ token: FrameWaitToken) {
        lock.lock()
        if cancelled { lock.unlock(); token.cancel(); return }
        self.token = token
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let held = token
        lock.unlock()
        held?.cancel()
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: T) { lock.lock(); value = newValue; lock.unlock() }
    @discardableResult
    func withValue<R>(_ body: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}

// MARK: naming

public enum FrameNaming {
    /// The digits in a frame's number: at least 4, so a folder that is already on disk still matches, and enough for the count.
    public static func digits(forFrameCount count: Int) -> Int {
        max(4, String(max(count, 1)).count)
    }

    /// Frame index `i` is `image_<i+1, zero padded>.<ext>`: the 1-based numbering ffmpeg's image2 muxer uses.
    public static func baseName(forFrame index: Int, digits: Int) -> String {
        let number = String(index + 1)
        return "image_" + String(repeating: "0", count: max(0, digits - number.count)) + number
    }

    public static func fileName(forFrame index: Int, digits: Int, fileExtension: String) -> String {
        "\(baseName(forFrame: index, digits: digits)).\(fileExtension)"
    }

    /// The ffmpeg output pattern for `digits`.
    public static func pattern(digits: Int, fileExtension: String) -> String {
        "image_%0\(digits)d.\(fileExtension)"
    }
}

// MARK: the bookkeeping both sources share

/// Which frames exist, who is waiting for which, and who is listening.  All of it behind one lock; nothing is ever called out
/// to while the lock is held.
final class FrameAvailabilityBook: @unchecked Sendable {

    typealias Callback = @Sendable (Result<Void, Error>) -> Void

    private struct Waiter {
        let index: Int
        let callback: Callback
    }

    private let lock = NSLock()
    private var available = IndexSet()
    private var failures: [Int: String] = [:]
    private var count: Int
    private var sourceError: String?
    private var finished = false
    private var waiters: [UInt64: Waiter] = [:]
    private var nextWaiterID: UInt64 = 0
    private var subscribers: [UInt64: AsyncStream<FrameSourceEvent>.Continuation] = [:]
    private var nextSubscriberID: UInt64 = 0

    init(frameCount: Int, available: IndexSet = IndexSet()) {
        self.count = frameCount
        self.available = available
    }

    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var availableSet: IndexSet { lock.lock(); defer { lock.unlock() }; return available }
    var availableCount: Int { lock.lock(); defer { lock.unlock() }; return available.count }
    var error: String? { lock.lock(); defer { lock.unlock() }; return sourceError }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func isAvailable(_ index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return available.contains(index)
    }

    func availability(_ index: Int) -> FrameAvailability {
        lock.lock(); defer { lock.unlock() }
        if available.contains(index) { return .available }
        if let failure = failures[index] ?? sourceError { return .failed(failure) }
        return .pending
    }

    /// Registers a waiter, or answers at once if the frame is there (or can never be).
    func addWaiter(_ index: Int, _ callback: @escaping Callback) -> FrameWaitToken {
        lock.lock()
        if available.contains(index) {
            lock.unlock()
            callback(.success(()))
            return .none
        }
        if let failure = failures[index] ?? sourceError {
            lock.unlock()
            callback(.failure(FrameSourceError(failure)))
            return .none
        }
        if index < 0 || index >= count {
            lock.unlock()
            callback(.failure(FrameSourceError("frame \(index) is outside the video's \(count) frames")))
            return .none
        }
        let id = nextWaiterID
        nextWaiterID += 1
        waiters[id] = Waiter(index: index, callback: callback)
        lock.unlock()
        return FrameWaitToken { [weak self] in self?.cancelWaiter(id) }
    }

    private func cancelWaiter(_ id: UInt64) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?.callback(.failure(CancellationError()))
    }

    var waitingFrames: [Int] {
        lock.lock(); defer { lock.unlock() }
        return waiters.values.map(\.index)
    }

    /// Marks frames available, resumes their waiters, and tells the listeners.
    func markAvailable(_ indices: IndexSet, progress: @autoclosure () -> FrameExtractionProgress) {
        guard !indices.isEmpty else { return }
        lock.lock()
        let fresh = indices.subtracting(available)
        guard !fresh.isEmpty else { lock.unlock(); return }
        available.formUnion(fresh)
        var ready: [Waiter] = []
        for (id, waiter) in waiters where fresh.contains(waiter.index) {
            ready.append(waiter)
            waiters.removeValue(forKey: id)
        }
        let listeners = Array(subscribers.values)
        lock.unlock()
        for waiter in ready { waiter.callback(.success(())) }
        let snapshot = progress()
        for listener in listeners {
            listener.yield(.framesAvailable(fresh))
            listener.yield(.progress(snapshot))
        }
    }

    func fail(frame index: Int, message: String) {
        lock.lock()
        failures[index] = message
        let ready = waiters.filter { $0.value.index == index }
        for id in ready.keys { waiters.removeValue(forKey: id) }
        let listeners = Array(subscribers.values)
        lock.unlock()
        for (_, waiter) in ready { waiter.callback(.failure(FrameSourceError(message))) }
        for listener in listeners { listener.yield(.frameFailed(index, message)) }
    }

    /// The whole source failed: every waiter fails with the error, and so does every later one.
    func failEverything(_ message: String) {
        lock.lock()
        if sourceError != nil { lock.unlock(); return }
        sourceError = message
        let all = Array(waiters.values)
        waiters = [:]
        let listeners = Array(subscribers.values)
        lock.unlock()
        for waiter in all { waiter.callback(.failure(FrameSourceError(message))) }
        for listener in listeners {
            listener.yield(.failed(message))
            listener.finish()
        }
        lock.lock(); subscribers = [:]; lock.unlock()
    }

    /// The frame count became known exactly.  Frames beyond it can never arrive, so their waiters fail.
    func settleCount(_ newCount: Int) {
        lock.lock()
        guard newCount != count else { lock.unlock(); return }
        count = newCount
        available = available.filteredIndexSet { $0 < newCount }
        var doomed: [Waiter] = []
        for (id, waiter) in waiters where waiter.index >= newCount {
            doomed.append(waiter)
            waiters.removeValue(forKey: id)
        }
        let listeners = Array(subscribers.values)
        lock.unlock()
        for waiter in doomed {
            waiter.callback(.failure(FrameSourceError("the video has only \(newCount) frames")))
        }
        for listener in listeners { listener.yield(.frameCountSettled(newCount)) }
    }

    /// The source was stopped: whoever is waiting is told so, and the stream ends.
    func cancelAll() {
        lock.lock()
        let all = Array(waiters.values)
        waiters = [:]
        let listeners = Array(subscribers.values)
        subscribers = [:]
        lock.unlock()
        for waiter in all { waiter.callback(.failure(CancellationError())) }
        for listener in listeners { listener.finish() }
    }

    func finish() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let listeners = Array(subscribers.values)
        subscribers = [:]
        lock.unlock()
        for listener in listeners {
            listener.yield(.finished)
            listener.finish()
        }
    }

    /// A stream that begins with a snapshot.
    func events(progress: @escaping @Sendable () -> FrameExtractionProgress) -> AsyncStream<FrameSourceEvent> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            // Asked before the lock is taken: the progress is built from this book, and the lock is not reentrant.
            let state = progress()
            lock.lock()
            let snapshot = FrameSourceEvent.snapshot(available: available, frameCount: count, progress: state)
            continuation.yield(snapshot)
            if let sourceError {
                lock.unlock()
                continuation.yield(.failed(sourceError))
                continuation.finish()
                return
            }
            if finished {
                lock.unlock()
                continuation.yield(.finished)
                continuation.finish()
                return
            }
            let id = nextSubscriberID
            nextSubscriberID += 1
            subscribers[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    func publish(_ event: FrameSourceEvent) {
        lock.lock()
        let listeners = Array(subscribers.values)
        lock.unlock()
        for listener in listeners { listener.yield(event) }
    }
}

// MARK: a folder of files

/// Image sequence: every frame is there already, so nothing waits and nothing is ever extracted.  Lists the directory once, at
/// init, exactly as `ImageSequence` always has.
public final class DirectoryFrameSource: FrameSource, @unchecked Sendable {
    public let filenames: [String]

    public init(dirname: String, supportedImageFileTypes: [String]) throws {
        if !FileManager.default.fileExists(atPath: dirname) {
            throw "\(dirname) does not exist"
        }
        // runs on the main thread and blocks when the SAN is starting
        let contents = try FileManager.default.contentsOfDirectory(atPath: dirname)
        var imageFiles: [String] = []
        for file in contents {
            for type in supportedImageFileTypes where file.hasSuffix(type) {
                imageFiles.append("\(dirname)/\(file)")
            }
        }
        imageFiles.sort { removePathAndSuffix(fromString: $0) < removePathAndSuffix(fromString: $1) }
        self.filenames = imageFiles
    }

    /// A source over names already chosen (tests, and a finished video's folder).
    public init(filenames: [String]) {
        self.filenames = filenames
    }

    public var frameCount: Int { filenames.count }
    public func path(forFrame index: Int) -> String { filenames[index] }
    public func isAvailable(_ index: Int) -> Bool { index >= 0 && index < filenames.count }
    public func availability(_ index: Int) -> FrameAvailability { isAvailable(index) ? .available : .failed("no frame \(index)") }
    public var availableFrames: IndexSet { filenames.isEmpty ? IndexSet() : IndexSet(integersIn: 0..<filenames.count) }

    @discardableResult
    public func whenAvailable(_ index: Int, _ callback: @escaping @Sendable (Result<Void, Error>) -> Void) -> FrameWaitToken {
        if isAvailable(index) {
            callback(.success(()))
        } else {
            callback(.failure(FrameSourceError("frame \(index) is outside the sequence's \(filenames.count) frames")))
        }
        return .none
    }

    public func prioritize(_ indices: [Int], reason: FramePriorityReason) {}

    public func events() -> AsyncStream<FrameSourceEvent> {
        let snapshot = FrameSourceEvent.snapshot(available: availableFrames, frameCount: frameCount, progress: progress)
        return AsyncStream { continuation in
            continuation.yield(snapshot)
            continuation.yield(.finished)
            continuation.finish()
        }
    }

    public var progress: FrameExtractionProgress {
        FrameExtractionProgress(extracted: filenames.count, total: filenames.count, isComplete: true)
    }

    public func estimatedSecondsUntilAvailable(_ index: Int) -> Double? { isAvailable(index) ? 0 : nil }
    public var sweepHead: Int? { nil }
    public func stop() {}
}
