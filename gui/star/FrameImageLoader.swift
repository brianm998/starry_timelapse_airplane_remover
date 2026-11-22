import Foundation
import SwiftUI
import AppKit
import ImageIO
import logging
import StarCore

/// Where every frame picture in the gui comes from.  It replaces SwiftUI's built-in async image view, which stays on its
/// placeholder forever when a load fails or is cancelled, and which needed the caller to stat the
/// file on the main thread first.
///
/// * A bounded LRU of decoded pictures keyed by file path (budgeted by bytes, as `ImageCache.kt`
///   on the desktop is); an entry also remembers the file's modification time.
/// * Every stat and decode runs off the main actor.
/// * One `Entry` per path publishes its phase: loading, loaded or failed.
/// * A failure is logged with its path and error and retried once after `retryDelay`.
/// * A request for a path nobody has made yet calls `onMissing` so the caller can queue a `PreviewOp`.
@MainActor @Observable
final class FrameImageLoader {

    static let shared = FrameImageLoader()

    enum Phase {
        case loading
        case loaded(NSImage)
        case failed(String)
    }

    /// One picture's state.  Views hold it and redraw when it changes.
    @MainActor @Observable
    final class Entry {
        let path: String
        fileprivate(set) var phase: Phase = .loading
        /// The last picture this path had, shown while a newer one loads.
        fileprivate(set) var lastImage: NSImage?

        @ObservationIgnored fileprivate var modified: Date?
        @ObservationIgnored fileprivate var bytes = 0
        @ObservationIgnored fileprivate var lastUse: UInt64 = 0
        @ObservationIgnored fileprivate var task: Task<Void, Never>?
        @ObservationIgnored fileprivate var retryTask: Task<Void, Never>?
        @ObservationIgnored fileprivate var retried = false
        @ObservationIgnored fileprivate var needsReload = false
        @ObservationIgnored fileprivate var onMissing: (@MainActor () -> Void)?

        fileprivate init(path: String) { self.path = path }

        var isFailed: Bool {
            if case .failed = phase { return true }
            return false
        }

        /// Waits for the load in flight, if any.
        func settled() async { await task?.value }
    }

    /// The only places the loader touches the disk; they run off the main actor.
    struct FileAccess: Sendable {
        /// The file's modification time, nil when it does not exist.
        var modified: @Sendable (String) -> Date?
        var decode: @Sendable (String) throws -> NSImage

        static let live = FileAccess(
          modified: { path in
              guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
              return (attrs[.modificationDate] as? Date) ?? .distantPast
          },
          decode: { path in try FrameImageLoader.decodeImage(atPath: path) })
    }

    struct DecodeError: Error, CustomStringConvertible {
        let description: String
    }

    let byteBudget: Int
    let retryDelay: TimeInterval
    @ObservationIgnored private let access: FileAccess
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var tick: UInt64 = 0
    @ObservationIgnored private(set) var cachedBytes = 0
    @ObservationIgnored private(set) var decodeCount = 0
    @ObservationIgnored private(set) var requestCounts: [String: Int] = [:]
    /// Called with every failure message, besides the log.
    @ObservationIgnored var onFailure: ((String) -> Void)?

    init(byteBudget: Int = 256 * 1024 * 1024,
         retryDelay: TimeInterval = 1,
         access: FileAccess = .live)
    {
        self.byteBudget = byteBudget
        self.retryDelay = retryDelay
        self.access = access
    }

    var totalRequests: Int { requestCounts.values.reduce(0, +) }
    func requestCount(forPath path: String) -> Int { requestCounts[path] ?? 0 }

    /// What is cached for `path` right now; no disk access and no side effect but recency.
    func peek(_ path: String) -> Entry? {
        guard let e = entries[path] else { return nil }
        tick &+= 1
        e.lastUse = tick
        return e
    }

    /// Starts (or joins) the load of `path` and returns its entry.  A picture already loaded is
    /// checked against the file's modification time and decoded again only if that changed.
    @discardableResult
    func request(path: String, onMissing: (@MainActor () -> Void)? = nil) -> Entry {
        requestCounts[path, default: 0] += 1
        let e = entries[path] ?? makeEntry(path)
        tick &+= 1
        e.lastUse = tick
        if let onMissing { e.onMissing = onMissing }
        if e.task == nil {
            e.retryTask?.cancel()
            e.retried = false
            attempt(e, force: false)
        }
        return e
    }

    /// The file at `path` was deleted: drop what is cached for it.
    func forget(path: String) {
        guard let e = entries[path] else { return }
        e.retryTask?.cancel()
        e.task?.cancel()
        entries[path] = nil
    }

    /// A new picture was written at `path`: load it, keeping the old one on screen meanwhile.
    func invalidate(path: String) {
        guard let e = entries[path] else { return }
        e.retryTask?.cancel()
        e.retried = false
        if e.task != nil {
            e.needsReload = true
        } else {
            attempt(e, force: true)
        }
    }

    /// Decodes a picture too big to keep (a full-size original); nothing is cached.
    func loadUncached(path: String) async -> NSImage? {
        let access = self.access
        let result = await Task.detached(priority: .userInitiated) { () -> Outcome in
            guard access.modified(path) != nil else { return .missing }
            do { return .loaded(Decoded(image: try access.decode(path)), .distantPast) }
            catch { return .failed("\(error)") }
        }.value
        switch result {
        case .loaded(let d, _):
            return d.image
        case .missing:
            reportFailure(path, "file not found")
        case .failed(let why):
            reportFailure(path, "unreadable image: \(why)")
        case .unchanged:
            break
        }
        return nil
    }

    // MARK: -

    private struct Decoded: @unchecked Sendable { let image: NSImage }

    private enum Outcome: Sendable {
        case missing
        case unchanged
        case loaded(Decoded, Date)
        case failed(String)
    }

    private func makeEntry(_ path: String) -> Entry {
        let e = Entry(path: path)
        entries[path] = e
        return e
    }

    private func attempt(_ e: Entry, force: Bool) {
        let path = e.path
        let access = self.access
        let known = force ? nil : (e.lastImage != nil && !e.isFailed ? e.modified : nil)
        e.needsReload = false
        e.task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
                guard let modified = access.modified(path) else { return .missing }
                if let known, known == modified { return .unchanged }
                do { return .loaded(Decoded(image: try access.decode(path)), modified) }
                catch { return .failed("\(error)") }
            }.value
            self?.finish(e, outcome)
        }
    }

    private func finish(_ e: Entry, _ outcome: Outcome) {
        e.task = nil
        switch outcome {
        case .unchanged:
            e.retried = false
        case .loaded(let d, let modified):
            decodeCount += 1
            cachedBytes -= e.bytes
            e.bytes = Self.byteCount(d.image)
            cachedBytes += e.bytes
            e.modified = modified
            e.lastImage = d.image
            e.phase = .loaded(d.image)
            e.retried = false
            evictIfNeeded(keeping: e)
        case .missing:
            fail(e, "file not found", missing: true)
        case .failed(let why):
            fail(e, "unreadable image: \(why)", missing: false)
        }
        if e.needsReload {
            attempt(e, force: true)
        }
    }

    private func fail(_ e: Entry, _ reason: String, missing: Bool) {
        reportFailure(e.path, reason)
        e.phase = .failed(reason)
        if missing { e.onMissing?() }
        guard !e.retried else { return }
        e.retried = true
        e.retryTask = Task { [weak self, weak e] in
            try? await Task.sleep(nanoseconds: UInt64((self?.retryDelay ?? 1) * 1_000_000_000))
            guard !Task.isCancelled, let self, let e, e.task == nil else { return }
            self.attempt(e, force: false)
        }
    }

    private func reportFailure(_ path: String, _ reason: String) {
        let message = "frame picture \(path): \(reason)"
        Log.w(message)
        onFailure?(message)
    }

    private func evictIfNeeded(keeping keep: Entry) {
        while cachedBytes > byteBudget {
            let victim = entries.values
              .filter { $0 !== keep && $0.bytes > 0 }
              .min { $0.lastUse < $1.lastUse }
            guard let victim else { break }
            entries[victim.path] = nil
            cachedBytes -= victim.bytes
            victim.bytes = 0
        }
    }

    private static func byteCount(_ image: NSImage) -> Int {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return Int(image.size.width * image.size.height) * 4
    }

    /// Decodes right away (not lazily at first draw, which would be on the main thread).
    nonisolated static func decodeImage(atPath path: String) throws -> NSImage {
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
        else { throw DecodeError(description: "not a readable image") }
        let rep = NSBitmapImageRep(cgImage: cg)
        let image = NSImage(size: NSSize(width: cg.width, height: cg.height))
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - the view

/// A frame picture from the loader.  No file I/O happens here: the path comes from the caller
/// (`ImageAccessor.nameForImage` is just string work) and the loader stats and decodes it elsewhere.
struct LoaderPicture: View {
    enum Failure {
        /// Filmstrip cell: "n/a" in large type.
        case thumbnail
        /// Frame view: "image not found for frame" with the picture type's name.
        case preview(String)
        /// A small picture inside a dialog.
        case small
    }

    let path: String?
    var fallbackPath: String? = nil
    var failure: Failure = .small
    var resizable = true
    /// Changes when something rewrote a picture; asks the loader to look again.
    var reloadToken: UUID? = nil
    var onMissing: (@MainActor () -> Void)? = nil
    var loader: FrameImageLoader = .shared

    @State private var entry: FrameImageLoader.Entry?

    private struct TaskKey: Hashable {
        let path: String?
        let token: UUID?
    }

    var body: some View {
        let shown = (entry?.path == path || entry?.path == fallbackPath) ? entry : nil
        let cached = shown ?? path.flatMap { loader.peek($0) }
        content(cached)
          .task(id: TaskKey(path: path, token: reloadToken)) {
              guard let path else { entry = nil; return }
              let first = loader.request(path: path, onMissing: onMissing)
              entry = first
              if let fallbackPath {
                  await first.settled()
                  if first.isFailed {
                      entry = loader.request(path: fallbackPath)
                  }
              }
          }
    }

    @ViewBuilder
    private func content(_ entry: FrameImageLoader.Entry?) -> some View {
        switch entry?.phase {
        case .loaded(let image):
            picture(image)
        case .failed:
            failedPanel
        case .loading:
            if let last = entry?.lastImage {
                picture(last)
            } else {
                Color(white: 0.15)
            }
        case nil:
            Color(white: 0.15)
        }
    }

    @ViewBuilder
    private func picture(_ image: NSImage) -> some View {
        if resizable {
            Image(nsImage: image).resizable()
        } else {
            Image(nsImage: image)
        }
    }

    @ViewBuilder
    private var failedPanel: some View {
        switch failure {
        case .thumbnail:
            ZStack {
                Color(white: 0.15)
                Text(localized("ui.n_a"))
                  .font(.largeTitle)
                  .foregroundColor(Color(white: 0.45))
            }
        case .preview(let name):
            ZStack {
                Color(white: 0.15)
                Text(localized("ui.image_not_found_for_frame", name))
                  .font(.system(size: 28, weight: .medium))
                  .multilineTextAlignment(.center)
                  .padding()
                  .foregroundColor(Color(white: 0.45))
            }
        case .small:
            ZStack {
                Color(white: 0.15)
                Text(localized("ui.n_a"))
                  .font(.caption)
                  .foregroundColor(Color(white: 0.45))
            }
        }
    }
}
