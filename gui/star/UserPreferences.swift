import Foundation
import StarCore
import logging

class UserPreferences: Codable {
    static let filename = ".star.userprefs.json"

    static var fullPath: String {
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
    
    func justOpened(filename: String) {
        self.recentlyOpenedSequencelist[filename] = Date().timeIntervalSince1970
    }
    
    static var shared: UserPreferences { // XXX rename this
        get {
            // first look for a memory cached one
            if let instance = instance { return instance }

            // next look for one on file in users home dir
            let dispatchGroup = DispatchGroup()
            dispatchGroup.enter()
            Task {
                do {
                    instance = try await UserPreferences.load()
                } catch {
                    Log.e("\(error)")
                }
                dispatchGroup.leave()
            }
            dispatchGroup.wait()
            if let instance = instance { return instance } 

            // lastly make a new one
            let ret = UserPreferences()
            instance = ret
            return ret
        }
    }

    private static var instance: UserPreferences?

    private static func load() async throws -> UserPreferences? {
        if file_manager.fileExists(atPath: fullPath) {
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

            if file_manager.fileExists(atPath: UserPreferences.fullPath) {
                try file_manager.removeItem(atPath: UserPreferences.fullPath)
            }
            file_manager.createFile(atPath: UserPreferences.fullPath, contents: data, attributes: nil)
        } catch {
            Log.e("\(error)")
        }
    }
}

fileprivate let file_manager = FileManager.default
