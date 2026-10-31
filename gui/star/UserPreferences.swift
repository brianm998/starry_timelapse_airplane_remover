import Foundation
import StarCore
import logging
import Semaphore

/// The one live copy of the user's preferences.
///
/// `UserPreferences` is a value type that writes the *whole* file whenever any one of its
/// fields changes, so a second copy of it is a second writer: whichever copy saved last put
/// its own version of every other field back on disk, silently undoing what had been changed
/// through the other one.  `ViewModel` and `ImageSequenceViewModel` each used to hold one,
/// synced only at sequence-open — so a render setting changed in the render sheet (which
/// writes through the sequence's copy) was lost as soon as anything wrote through the app's
/// copy, opening another sequence being enough to do it.
///
/// Both now expose `userPreferences` as a view onto this, so there is exactly one writer and
/// no sync to forget.  `@Observable` so that a change still redraws the views that read it,
/// exactly as it did when each view model stored its own.
@MainActor @Observable
final class UserPreferencesStore {
    static let shared = UserPreferencesStore()

    /// Loaded from disk by `ViewModel.init`, which is the first thing to touch it.
    var preferences = UserPreferences()

    private init() {}
}

struct UserPreferences: Codable, Sendable {
    static let filename = ".star.userprefs.json"

    static var fullPath: String { // XXX act like a real app and put this in the right place
        let env = ProcessInfo.processInfo.environment
        if let homedir = env["HOME"] {
            return "\(homedir)/\(filename)"
        } else {
            // with no homedir, put it in tmp?
            return "/tmp/\(filename)"
        }
    }
    
    // other things can be saved here too if needed
    
    var recentlyOpenedSequencelist:
      [String:              // filename
       Double] = [:]  // when it was last opened
    {
        didSet {
            // XXX Add logic here to limit the size of the list to some parameter
            self.save()
        }
    }

    var processingType: DetectionType? {
        didSet {
            self.save()
            if let processingType  {
                Task { await constants.set(detectionType: processingType) }
            }
        }
    }
    
    var sortedSequenceList: [String] {
        return recentlyOpenedSequencelist.keys.sorted {
            recentlyOpenedSequencelist[$0]! > recentlyOpenedSequencelist[$1]!
        }
    }

    // the frame rate of the incoming and outgoing video
    var frameRate: FrameRate? {
        didSet {
            self.save()
            if let frameRate  {
                Task { await constants.set(frameRate: frameRate) }
            }
        }
    }

    // the codec of the incoming and outgoing video
    var codec: FFmpegCodec? {
        didSet {
            self.save()
            if let codec  {
                Task { await constants.set(codec: codec) }
            }
        }
    }

    // the encoder to use when encoding the outgoing video
    var encoder: FFmpegEncoder? {
        didSet {
            self.save()
            if let encoder  {
                Task { await constants.set(encoder: encoder) }
            }
        }
    }

    // the pixelformat of the incoming and outgoing video
    var pixelFormat: FFmpegPixelFormat? {
        didSet {
            self.save()
            if let pixelFormat  {
                Task { await constants.set(pixelFormat: pixelFormat) }
            }
        }
    }

    // the muxer (container) of the incoming and outgoing video
    var muxer: FFmpegMuxer? {
        didSet {
            self.save()
            if let muxer  {
                Task { await constants.set(muxer: muxer) }
            }
        }
    }

    // whether to draw the horizon line on the main frame edit view
    var showHorizonOnMainView: Bool? {
        didSet { self.save() }
    }

    // which kinds of horizon line (HorizonThumbnailOverlay.Kind raw values) the user has
    // switched off; nil or empty draws every kind a frame has.  A list of the hidden ones
    // rather than the shown ones, so a kind added later is drawn until it is switched off.
    // Shared with the Kotlin client, which reads and writes the same file.
    var hiddenHorizonLineKinds: [String]? {
        didSet { self.save() }
    }

    // whether to show the startup instructions overlay in the horizon painter
    var showHorizonPainterInstructions: Bool? {
        didSet { self.save() }
    }

    // when true, suppress the pre- and post-processing "render video?" prompts
    var skipRenderPromptAfterProcessing: Bool? {
        didSet { self.save() }
    }

    // whether starting a processing run puts the processing modal up over the window.
    // nil means yes: this is on unless the user has turned it off.
    var showProcessingWindow: Bool? {
        didSet { self.save() }
    }

    /// Whether the processing modal draws its alignment deviation charts.
    ///
    /// nil means no: the charts are off until the user turns them on.  Stored rather than held in the modal's own state because the modal
    /// is torn down and rebuilt every time it is dismissed and brought back, and a user who
    /// turned the charts on or off wants them to stay that way — they are the tall half of
    /// the panel, and on a short window they are what pushes the steps into a scroll view.
    var showAlignmentInProcessingWindow: Bool? {
        didSet { self.save() }
    }

    /// Whether the processing modal draws its alignment charts, with the default applied:
    /// off when the user has never chosen.
    var showsAlignmentInProcessingWindow: Bool { showAlignmentInProcessingWindow ?? false }

    /// How many reference horizons the user wants for a moving sequence, relative to what
    /// star suggests for that sequence's length.
    ///
    /// A multiplier rather than a count, because the count that suits a sequence depends on
    /// how long it is: 12 references over 1450 frames says "about one every 120 frames", and
    /// storing 12 would ask for the same 12 on a 200 frame sequence.  Stored as
    /// `chosen / suggestedMovingHorizonCount(total)`, so 1.5 means "half again as many as
    /// star suggests, whatever the length" and re-opening a sequence of the same length
    /// offers exactly the count the user picked last time.
    ///
    /// nil until the user first moves the stepper: star's own suggestion, unmodified.
    ///
    /// Shared with the Kotlin client, which reads and writes the same key in the same
    /// `~/.star.userprefs.json`.
    var movingHorizonCountMultiplier: Double? {
        didSet { self.save() }
    }

    /// The three GPU processing toggles — align & merge, SIFT, AKAZE — as the user last set them
    /// on this machine, or nil until they first touch one.
    ///
    /// Whether a machine's GPU is worth using is a fact about the machine, not about the
    /// sequence being processed, so a toggle turned off here has to stay off for every video and
    /// image sequence opened afterwards, not just the one whose settings sheet it was changed in
    /// (each sequence's own `config.json` still records the value it ran with).  nil means "never
    /// chosen": the sequence's own config — on wherever a GPU is available — is used as it is.
    ///
    /// Shared with the Kotlin client, which reads and writes the same keys in the same
    /// `~/.star.userprefs.json`.
    var useGPUForMerge: Bool? {
        didSet { self.save() }
    }

    var useGPUForSIFT: Bool? {
        didSet { self.save() }
    }

    var useGPUForAKAZE: Bool? {
        didSet { self.save() }
    }

    /// The language the user picked from the Language menu, or nil to follow the system.
    ///
    /// A BCP-47 tag rather than an index, so the file survives languages being added or
    /// reordered. Shared with the Kotlin client, which reads and writes the same key in the
    /// same `~/.star.userprefs.json` — pick Japanese in one and the other opens in Japanese.
    var language: String? {
        didSet {
            self.save()
            StarLocalization.shared.languageOverride = language
        }
    }

    mutating func justOpened(filename: String) {
        self.recentlyOpenedSequencelist[filename] = Date().timeIntervalSince1970
    }

    /// Take `filename` off the Open Recent list (the desktop client's ✕ on a recent; parity plan D12).
    mutating func removeFromRecent(filename: String) {
        recentlyOpenedSequencelist.removeValue(forKey: filename)
    }

    /// What the Open Recent picker shows once `removed` has gone from `list` (newest first): the entry that took its place, else the one
    /// before it, else nothing.
    static func recentSelection(afterRemoving removed: String, from list: [String]) -> String {
        guard let index = list.firstIndex(of: removed) else { return list.first ?? "" }
        let rest = list.filter { $0 != removed }
        return rest.isEmpty ? "" : rest[min(index, rest.count - 1)]
    }

    mutating func pruneNonExistentFromRecentList() {
        let missing = recentlyOpenedSequencelist.keys.filter {
            !FileManager.default.fileExists(atPath: $0)
        }
        for filename in missing {
            recentlyOpenedSequencelist.removeValue(forKey: filename)
        }
    }

    static func initialize() -> UserPreferences? { // XXX rename this
        var instance: UserPreferences?
        do {
            instance = try UserPreferences.load()
            instance?.pruneNonExistentFromRecentList()

            if let processingType = instance?.processingType {
                Task { await constants.set(detectionType: processingType) }
            }

            // Before any window is built, so the first frame the user sees is already in
            // their language rather than flashing English and then re-rendering.
            StarLocalization.shared.languageOverride = instance?.language
        } catch {
            Log.e("\(error)")
            // The file is there but could not be read (a hand edit, a newer format written by the
            // other client). Saving the defaults over it later would destroy whatever it holds,
            // so nothing is saved this session; a copy is kept beside it for the user.
            Self.markUnreadable(path: fullPath)
        }
        return instance
    }

    /// Set when the preferences file exists but did not decode: `save()` then leaves it alone.
    nonisolated(unsafe) static var loadFailed = false

    /// Stop writing to the file at `path` for the rest of this run, and keep a copy of it beside it, once, for the user.
    static func markUnreadable(path: String) {
        loadFailed = true
        let copy = path + ".undecodable"
        if FileManager.default.fileExists(atPath: path), !FileManager.default.fileExists(atPath: copy) {
            try? FileManager.default.copyItem(atPath: path, toPath: copy)
        }
    }

    /// What this process last read from, or wrote to, the file, as a JSON object: the baseline `save()` compares the
    /// preferences against, so that it writes only what this process changed (see `merged`).
    nonisolated(unsafe) static var lastSaved: [String: Any]?

    /// What a `UserPreferences` with nothing set encodes to: only the recent list, empty.  Written out rather than made by
    /// constructing one, which only the store is to do (`UserPreferencesStoreTests`); a test pins it to the real thing.
    nonisolated(unsafe) static let defaultObject: [String: Any] = ["recentlyOpenedSequencelist": [String: Any]()]

    private static let saveLock = NSLock()

//    private static var instance: UserPreferences?

    private static func load() throws -> UserPreferences? {
        if FileManager.default.fileExists(atPath: fullPath) {
            let url = NSURL(fileURLWithPath: fullPath, isDirectory: false) as URL
            let data = try Data(contentsOf: url)
            // Nothing in a blank file to protect, and nothing to decode: it reads as no file at all.
            if data.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 }) { return nil }
            //let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
              positiveInfinity: "inf",
              negativeInfinity: "-inf",
              nan: "nan")
            
            var preferences = try decoder.decode(UserPreferences.self, from: data)
            lastSaved = jsonObject(of: preferences)

            if preferences.processingType == nil {
                preferences.processingType = .strong
            }
            Log.d("UserPreferences: \(preferences)")
            return preferences
        }
        return nil
    }

    /// The JSON object `value` encodes to: the keys this process knows, with a nil left out.
    static func jsonObject(of value: UserPreferences) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func jsonEqual(_ a: Any, _ b: Any) -> Bool {
        (a as AnyObject).isEqual(b)
    }

    /// `onDisk` with this process's changes applied.  Every key whose value in `current` differs from its value in
    /// `previous` is set to the new one, or removed when `current` no longer has it; objects are compared member by
    /// member, so two processes that each added a different recent file both keep theirs.  Everything else is left as
    /// the file has it: the keys only the Kotlin client knows, and what it changed since `previous` was taken.
    /// (`save()` used to write the whole struct, which dropped the first and undid the second.)
    static func merged(onDisk: [String: Any], previous: [String: Any], current: [String: Any]) -> [String: Any] {
        var result = onDisk
        for key in Set(previous.keys).union(current.keys) {
            let was = previous[key]
            switch (was, current[key]) {
            case (nil, nil):
                continue
            case let (was?, now?) where jsonEqual(was, now):
                continue
            case (_, nil):
                result.removeValue(forKey: key)
            case let (was, now?):
                if let nowObject = now as? [String: Any],
                   was == nil || was is [String: Any],
                   onDisk[key] == nil || onDisk[key] is [String: Any] {
                    result[key] = merged(onDisk: onDisk[key] as? [String: Any] ?? [:],
                                         previous: was as? [String: Any] ?? [:],
                                         current: nowObject)
                } else {
                    result[key] = now
                }
            }
        }
        return result
    }

    enum SaveOutcome: Equatable {
        case written
        /// The file is there but is not a JSON object, so it was left as it is.
        case unreadable
    }

    /// Apply the difference between `previous` and `current` to the file at `path`, atomically, as it is *now*.
    static func writeMerged(current: [String: Any], previous: [String: Any], to path: String) throws -> SaveOutcome {
        var onDisk: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: path) {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if !data.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x0d || $0 == 0x09 }) {
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return .unreadable
                }
                onDisk = object
            }
        }
        let out = try JSONSerialization.data(
            withJSONObject: merged(onDisk: onDisk, previous: previous, current: current),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Atomically: removing the file and then creating it left a window with no file at all
        // (and an empty one if the process died in it), and the Kotlin client reads the same
        // file.
        try out.write(to: URL(fileURLWithPath: path), options: .atomic)
        return .written
    }

    private func save() {
        guard !Self.loadFailed else {
            Log.w("not saving preferences: the existing file could not be read and would be overwritten")
            return
        }
        Self.saveLock.lock()
        defer { Self.saveLock.unlock() }
        guard let current = Self.jsonObject(of: self) else {
            Log.e("could not encode the preferences")
            return
        }
        // No file was read at startup: what this process started from is the defaults.
        let previous = Self.lastSaved ?? Self.defaultObject
        do {
            switch try Self.writeMerged(current: current, previous: previous, to: UserPreferences.fullPath) {
            case .written:
                Self.lastSaved = current
            case .unreadable:
                // Edited into something unreadable while this ran: it is the user's to fix.
                Log.w("not saving preferences: the file changed into something that cannot be read")
                Self.markUnreadable(path: UserPreferences.fullPath)
            }
        } catch {
            Log.e("\(error)")
        }
    }
}

extension UserPreferences {
    /// The horizon line kinds to draw, when the horizon lines are shown at all.
    var visibleHorizonLineKinds: Set<HorizonThumbnailOverlay.Kind> {
        let hidden = Set(hiddenHorizonLineKinds ?? [])
        return Set(HorizonThumbnailOverlay.Kind.allCases.filter { !hidden.contains($0.rawValue) })
    }

    /// Switch one kind of horizon line on or off.
    mutating func setHorizonLineKind(_ kind: HorizonThumbnailOverlay.Kind, visible: Bool) {
        var hidden = Set(hiddenHorizonLineKinds ?? [])
        if visible { hidden.remove(kind.rawValue) } else { hidden.insert(kind.rawValue) }
        hiddenHorizonLineKinds = hidden.sorted()
    }
}
