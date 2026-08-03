import Foundation
import StarCore
import logging
import Semaphore

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

    // whether to show the startup instructions overlay in the horizon painter
    var showHorizonPainterInstructions: Bool? {
        didSet { self.save() }
    }

    // when true, suppress the pre- and post-processing "render video?" prompts
    var skipRenderPromptAfterProcessing: Bool? {
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
        }
        return instance
    }

//    private static var instance: UserPreferences?

    private static func load() throws -> UserPreferences? {
        if FileManager.default.fileExists(atPath: fullPath) {
            let url = NSURL(fileURLWithPath: fullPath, isDirectory: false) as URL
            let data = try Data(contentsOf: url)
            //let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
              positiveInfinity: "inf",
              negativeInfinity: "-inf",
              nan: "nan")
            
            var preferences = try decoder.decode(UserPreferences.self, from: data)

            if preferences.processingType == nil {
                preferences.processingType = .strong
            }
            Log.d("UserPreferences: \(preferences)")
            return preferences
        }
        return nil
    }
    
    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let data = try encoder.encode(self)

            if FileManager.default.fileExists(atPath: UserPreferences.fullPath) {
                try FileManager.default.removeItem(atPath: UserPreferences.fullPath)
            }
            FileManager.default.createFile(atPath: UserPreferences.fullPath, contents: data, attributes: nil)
        } catch {
            Log.e("\(error)")
        }
    }
}

