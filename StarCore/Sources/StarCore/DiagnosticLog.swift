import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// The log that is always running, so a crash always leaves evidence.
///
/// The gui and the daemon each had a way to produce no record at all of what they had been
/// doing. The gui's file logging defaults to off and its console handler is `#if DEBUG`, so a
/// release build that died left nothing but the OS crash report — no sequence name, no frame
/// number, none of star's own reasoning. The daemon registered only `StderrLogHandler`, and
/// the desktop client's default stderr sink is `System.err.println`, which in a packaged app
/// goes nowhere a user can reach.
///
/// That is the gap the original bug report fell into: "a crash with no error message". The
/// cli at least had `--file-log-level` for a user who thought to pass it. The other two had
/// nothing to offer, and asking a user to reproduce a crash with logging turned on is asking
/// them to hit it twice.
///
/// This is deliberately separate from the user-facing file log:
///
///   - it goes to the system log directory rather than the user's Documents folder, because
///     it is machine state, not something anybody asked for;
///   - it runs at `.info`, which is enough to reconstruct what a run was doing without the
///     volume of `.debug`;
///   - it prunes itself, which the opt-in log never had to (an always-on log writes a file
///     per launch, and filling a user's disk would be a poor way to end a piece of work that
///     added a disk-space warning).
///
/// The user-toggleable file log is unaffected and still works alongside this, at its own
/// level, in its own place.
public enum DiagnosticLog {

    /// How many launches' worth to keep.
    ///
    /// Enough that a user who hits an intermittent problem has the failing run *and* a few
    /// good ones to compare it against, which is most of what makes a log useful. At `.info`
    /// on a long sequence these run to a few megabytes each.
    public static let keepCount = 10

    /// `~/Library/Logs/star` on Darwin, `<application support>/star/logs` elsewhere.
    ///
    /// `~/Library/Logs` is where a macOS user (and Console.app) already looks, and where a
    /// support request can be pointed without explaining anything.
    public static func directory() -> URL {
        #if canImport(Darwin)
        if let library = FileManager.default.urls(for: .libraryDirectory,
                                                  in: .userDomainMask).first {
            return library.appendingPathComponent("Logs", isDirectory: true)
                          .appendingPathComponent("star", isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
        let base = support ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("star", isDirectory: true)
                   .appendingPathComponent("logs", isDirectory: true)
    }

    /// Start the always-on log and prune older ones.
    ///
    /// - Parameter level: how much to record. `.info` by default — enough to follow a run.
    /// - Returns: the path being written to, so the caller can hand it to
    ///   `StarCrashHandler.setLogPath` and name it in a crash report. Nil if it could not be
    ///   opened, which is never fatal: not being able to write a log is not a reason to
    ///   refuse to process images.
    @discardableResult
    public static func enable(level: Log.Level = .info) -> String? {
        let directory = directory()

        // Prune before opening, so a directory already at the limit does not briefly hold
        // one more than it should, and so a failure to prune cannot delete the log we are
        // about to write.
        FileLogHandler.pruneLogs(in: directory, prefix: Log.name, keeping: keepCount - 1)

        do {
            let handler = try FileLogHandler(at: level, in: directory)
            Log.add(handler: handler, for: .diagnostic)
            Log.i("diagnostic log started at \(handler.full_log_path)")
            return handler.full_log_path
        } catch {
            // Through the other handlers, which is all that is left.
            Log.w("could not start the diagnostic log in \(directory.path): \(error)")
            return nil
        }
    }
}
