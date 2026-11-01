import Foundation
import AppKit
import StarCore
import logging

/// Under the App Sandbox the app may touch only what the user has granted through an open panel or a drop, and that grant lasts for
/// the session.  A grant outlives the launch only as a security-scoped bookmark.  This file holds the decisions and the storage for
/// that; none of it does anything in a build that is not sandboxed (Developer ID, a local build), which behaves as it always has.

/// Which folder, if any, the user has to be asked for before a source can be opened with its output where they chose.
enum OutputLocation {
    /// The folder star needs the user to grant before it can write its output, or nil when there is nothing to ask.
    ///
    /// A folder the user chose (`outputDir`) was granted by the panel that chose it.  "Beside the source" is the *parent* of what the
    /// open panel granted (the folder of the sequence, or the video file), and a sibling cannot be made in a folder that was not
    /// granted: the answer is that parent, unless it can already be written.  A video import writes its extracted frames there too,
    /// so it is the same decision.
    static func folderNeedingGrant(source: String, outputDir: String?, isWritable: (String) -> Bool) -> String? {
        guard outputDir == nil else { return nil }
        let parent = (source as NSString).deletingLastPathComponent
        return isWritable(parent) ? nil : parent
    }
}

/// App-scoped, security-scoped bookmarks to the folders the user has granted, kept in the user preferences (`folderBookmarks`) so a
/// recent sequence, or a resume from its config.json, can be opened after a relaunch without asking again.
///
/// Bookmarks are keyed by the folder's path.  What a granted folder covers is everything inside it, so a path is looked up by the
/// bookmark of the nearest folder above it (`resolve(covering:)`): the grant of a sequence's parent covers the sequence, its output
/// and its config.json.
@MainActor
final class BookmarkStore {
    enum Resolution: Equatable {
        /// The bookmark resolved to the folder it was made for.
        case resolved(URL)
        /// It resolved, but to somewhere else or out of date (the folder was moved or renamed).  The stored bookmark has been remade
        /// from the new place when that could be done; what it was made for is no longer where the caller thinks.
        case stale(URL)
        /// There is no bookmark, or it no longer leads anywhere (the folder is gone).  Nothing is thrown: the caller asks the user.
        case missing
    }

    /// The system calls, injected so that a test can run without a sandbox.
    struct System {
        var isSandboxed: Bool
        var makeBookmark: (URL) throws -> Data
        var resolveBookmark: (Data) throws -> (url: URL, isStale: Bool)
        var startAccess: (URL) -> Bool
        var stopAccess: (URL) -> Void

        nonisolated(unsafe) static let live = System(
            isSandboxed: BookmarkStore.processIsSandboxed,
            makeBookmark: { try $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) },
            resolveBookmark: { data in
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                return (url, stale)
            },
            startAccess: { $0.startAccessingSecurityScopedResource() },
            stopAccess: { $0.stopAccessingSecurityScopedResource() })
    }

    /// A sandboxed process has a container id in its environment; nothing else is as cheap and as reliable to ask.
    nonisolated static var processIsSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private let system: System
    private let load: () -> [String: Data]
    private let store: ([String: Data]) -> Void
    /// Folders whose access this store has started and not yet stopped.
    private var active: [String: URL] = [:]

    init(system: System = .live,
         load: @escaping () -> [String: Data],
         store: @escaping ([String: Data]) -> Void) {
        self.system = system
        self.load = load
        self.store = store
    }

    /// The one backed by the user preferences.
    static func live() -> BookmarkStore {
        BookmarkStore(load: { UserPreferencesStore.shared.preferences.folderBookmarks ?? [:] },
                      store: { UserPreferencesStore.shared.preferences.folderBookmarks = $0.isEmpty ? nil : $0 })
    }

    static func key(for url: URL) -> String { url.standardizedFileURL.path }

    /// Remember the folder (or file) the user just granted.  Only a sandboxed process makes bookmarks: elsewhere there is nothing
    /// they would add, and the preferences file is shared with the Kotlin client.
    func save(url: URL) {
        guard system.isSandboxed else { return }
        do {
            var bookmarks = load()
            bookmarks[Self.key(for: url)] = try system.makeBookmark(url)
            store(bookmarks)
        } catch {
            Log.w("could not bookmark \(url.path): \(error)")
        }
    }

    /// The bookmark made for exactly `path`.
    func resolve(path: String) -> Resolution {
        guard let data = load()[path] else { return .missing }
        return resolve(data: data, key: path)
    }

    /// The bookmark of the nearest folder that is `path` or above it.
    func resolve(covering path: String) -> Resolution {
        guard let key = Self.key(covering: path, in: Array(load().keys)) else { return .missing }
        return resolve(path: key)
    }

    /// `path` with symlinks (`/tmp`, `/var`) followed, so that two spellings of one folder compare equal.
    nonisolated private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// Of `keys`, the longest that is `path` or a folder above it.
    nonisolated static func key(covering path: String, in keys: [String]) -> String? {
        keys.filter { $0 == path || $0 == "/" || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
            .max { $0.count < $1.count }
    }

    private func resolve(data: Data, key: String) -> Resolution {
        let resolved: (url: URL, isStale: Bool)
        do { resolved = try system.resolveBookmark(data) } catch { return .missing }
        let moved = Self.canonical(resolved.url.path) != Self.canonical(key)
        guard resolved.isStale || moved else { return .resolved(resolved.url) }
        // Out of date, or moved: remake it from where it is now, which takes the access it came with.
        let wasActive = system.startAccess(resolved.url)
        defer { if wasActive { system.stopAccess(resolved.url) } }
        var bookmarks = load()
        bookmarks.removeValue(forKey: key)
        if let fresh = try? system.makeBookmark(resolved.url) { bookmarks[Self.key(for: resolved.url)] = fresh }
        store(bookmarks)
        return .stale(resolved.url)
    }

    /// Resolve the bookmark covering `path` and begin the access it grants, until `stopAll`.
    @discardableResult
    func startAccess(covering path: String) -> Resolution {
        let resolution = resolve(covering: path)
        guard case let .resolved(url) = resolution else { return resolution }
        let key = Self.key(for: url)
        if active[key] == nil, system.startAccess(url) { active[key] = url }
        return resolution
    }

    /// End every access `startAccess` began: when the sequence it was for is closed.
    func stopAll() {
        for url in active.values { system.stopAccess(url) }
        active = [:]
    }

    var activeFolders: [String] { active.keys.sorted() }

    /// Whether the bookmark in `data` still leads to a folder, for the Recents list to decide whether to keep an entry.
    nonisolated static func stillResolves(_ data: Data) -> Bool {
        (try? System.live.resolveBookmark(data)) != nil
    }
}

/// What the views call.  Everything here returns at once without asking when the process is not sandboxed.
@MainActor
enum FolderAccess {
    static let bookmarks = BookmarkStore.live()

    static var isSandboxed: Bool { BookmarkStore.processIsSandboxed }

    /// Remember a folder or file the user has just handed to star (an open panel, a drop), for the next launch.
    static func remember(_ url: URL) { bookmarks.save(url: url) }

    /// The access held for the sequence that is open ends with it.
    static func releaseAll() { bookmarks.stopAll() }

    enum Grant: Equatable {
        /// Nothing more to ask, or the folder asked for has been granted.
        case granted
        /// The user chose a different folder to put the output in, which is granted too.
        case choseOutputDir(String)
        case cancelled
    }

    /// Before a sequence or a video is opened: make sure the place its output will go can be written, asking the user for the parent
    /// folder (an open panel on it) when it cannot.  Picking another folder in the panel makes that the output location.
    static func grantOutputLocation(source: String, outputDir: String?) -> Grant {
        guard isSandboxed else { return .granted }
        guard let folder = OutputLocation.folderNeedingGrant(
                source: source, outputDir: outputDir,
                isWritable: { FileManager.default.isWritableFile(atPath: $0) })
        else { return .granted }

        // An earlier launch may have been granted it.
        if case .resolved = bookmarks.startAccess(covering: folder),
           FileManager.default.isWritableFile(atPath: folder) { return .granted }

        let name = (source as NSString).lastPathComponent
        guard let url = askForFolder(at: folder, message: localized("ui.location_grant_message", folder, name)) else {
            return .cancelled
        }
        bookmarks.save(url: url)
        return covers(url.path, folder) ? .granted : .choseOutputDir(url.path)
    }

    /// Whether star can use `path` now: read it, or write it when `writable`.
    private static func accessible(_ path: String, writable: Bool) -> Bool {
        writable ? FileManager.default.isWritableFile(atPath: path) : FileManager.default.isReadableFile(atPath: path)
    }

    /// Make `path` reachable from a sandboxed process: through what is granted already, a bookmark from an earlier launch, or an open
    /// panel.  False when the user would not grant it, or granted something that does not cover it.  Always true when not sandboxed.
    static func ensureAccess(to path: String, writable: Bool) -> Bool {
        guard isSandboxed else { return true }
        if accessible(path, writable: writable) { return true }
        if case .resolved = bookmarks.startAccess(covering: path) { return true }
        // No bookmark, or it leads somewhere else now: the folder was never granted, or has been moved or deleted.
        guard let url = askForFolder(at: path, message: localized("ui.folder_access_prompt", path)) else { return false }
        bookmarks.save(url: url)
        return covers(url.path, path)
    }

    /// The access a re-opened sequence needs: its config.json, the folder of its images and the folder it writes to.  Throws a
    /// localized error naming what could not be reached, rather than starting a run that fails halfway.
    static func ensureAccess(forConfigFile configPath: String) throws {
        guard isSandboxed else { return }
        guard ensureAccess(to: configPath, writable: false) else { throw FolderAccessError.denied(configPath) }
        let config = try ConfigManager(configFilename: configPath).config()
        let sequence = (config.imageSequencePath as NSString).appendingPathComponent(config.imageSequenceDirname)
        guard ensureAccess(to: sequence, writable: false) else { throw FolderAccessError.denied(sequence) }
        guard ensureAccess(to: config.tempOutputPath, writable: true) else { throw FolderAccessError.denied(config.tempOutputPath) }
    }

    /// Whether the folder `granted` is `path` or has it inside.
    static func covers(_ granted: String, _ path: String) -> Bool {
        BookmarkStore.key(covering: path, in: [granted]) != nil
    }

    private static func askForFolder(at path: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = localized("ui.folder_access_grant")
        panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum FolderAccessError: LocalizedError {
    case denied(String)

    var errorDescription: String? {
        switch self {
        case .denied(let path): return localized("ui.folder_access_denied", path)
        }
    }
}
