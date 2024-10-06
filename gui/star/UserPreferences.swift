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

    var sortedSequenceList: [String] {
        return recentlyOpenedSequencelist.keys.sorted {
            recentlyOpenedSequencelist[$0]! > recentlyOpenedSequencelist[$1]!
        }
    }
    
    mutating func justOpened(filename: String) {
        self.recentlyOpenedSequencelist[filename] = Date().timeIntervalSince1970
    }
    
    static func initialize() async -> UserPreferences? { // XXX rename this
        var instance: UserPreferences?
        do {
            instance = try await UserPreferences.load()
        } catch {
            Log.e("\(error)")
        }
        return instance
    }

//    private static var instance: UserPreferences?

    private static func load() async throws -> UserPreferences? {
        if FileManager.default.fileExists(atPath: fullPath) {
            let url = NSURL(fileURLWithPath: fullPath, isDirectory: false) as URL
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            let decoder = JSONDecoder()
            decoder.nonConformingFloatDecodingStrategy = .convertFromString(
              positiveInfinity: "inf",
              negativeInfinity: "-inf",
              nan: "nan")
            
            return try decoder.decode(UserPreferences.self, from: data)
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

