import Foundation
import logging

/// Leftovers of writes that never finished.
///
/// Every image and feature file star writes goes to a temp name of the form
/// `<name>.tmp.<pid>-<n>[.<ext>]` and is renamed into place, so a crash or a power cut leaves the
/// temp file behind and the real file untouched. Nothing ever removed the temp files; on a long
/// sequence with several crashes they are frame-sized and accumulate in the temp and output
/// directories. This removes the ones whose writer is gone.
public enum StaleTempFiles {

    /// The process id in a temp file's name, nil if `name` is not one of ours.
    public static func writerPID(inFileName name: String) -> Int32? {
        // `.tmp.<pid>-<n>` followed by an optional extension, at the end of the name
        guard let range = name.range(of: #"\.tmp\.(\d+)-\d+(\.[A-Za-z0-9]+)?$"#, options: .regularExpression)
        else { return nil }
        let match = name[range]                      // ".tmp.1234-5.tif"
        let afterTmp = match.dropFirst(5)            // "1234-5.tif"
        let digits = afterTmp.prefix { $0.isNumber }
        return Int32(digits)
    }

    /// Whether a process with this id exists (running, even if it is not ours to signal).
    public static func processIsAlive(_ pid: Int32) -> Bool {
        #if os(Windows)
        return true   // cannot tell cheaply; err on the side of keeping the file
        #else
        if pid <= 0 { return true }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM     // exists, but belongs to someone else
        #endif
    }

    /// Removes stale temp files under `directories`; returns how many. A file is stale when it
    /// matches the pattern and its writer is not a live process (our own pid counts as live: a
    /// write of ours may be in flight). `isAlive` is injectable for tests.
    @discardableResult
    public static func clean(in directories: [String],
                             isAlive: (Int32) -> Bool = { StaleTempFiles.processIsAlive($0) }) -> Int
    {
        var removed = 0
        let fm = FileManager.default
        for directory in directories where !directory.isEmpty {
            guard let enumerator = fm.enumerator(atPath: directory) else { continue }
            for case let relative as String in enumerator {
                let name = (relative as NSString).lastPathComponent
                guard let pid = writerPID(inFileName: name) else { continue }
                if pid == ProcessInfo.processInfo.processIdentifier || isAlive(pid) { continue }
                let path = (directory as NSString).appendingPathComponent(relative)
                do {
                    try fm.removeItem(atPath: path)
                    removed += 1
                } catch {
                    Log.w("could not remove stale temp file \(path): \(error)")
                }
            }
        }
        if removed > 0 { Log.i("removed \(removed) stale temp file(s) left by an earlier run") }
        return removed
    }
}
