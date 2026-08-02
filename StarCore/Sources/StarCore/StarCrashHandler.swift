import Foundation
import StarCoreC
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Installs the fatal-signal handlers, and owns the convention for where the handler leaves
/// its note.
///
/// The handler itself is C — see `crash_handler.c` for why nothing in it can be Swift. This
/// is only the part that runs at install time, where allocation is fine: working out the
/// paths and handing them over.
///
/// Pairs with `RunMarker`. The marker says *what* the run was doing and that it never
/// finished; the note the handler leaves says *how* it ended. Together they turn "the process
/// vanished" into "it crashed with SIGSEGV while merging frame 47 of 312".
public enum StarCrashHandler {

    /// The file the handler creates when it catches a signal.
    ///
    /// Keyed by pid and kept in the same directory as the run markers so `abandonedRuns()`
    /// can pair the two without either side knowing about the other's naming. Nothing about
    /// this path may need computing at signal time — the C side copies it into a static
    /// buffer up front, precisely so the handler can `open()` it without formatting a string.
    public static func noteFileName(pid: Int32) -> String {
        "\(pid).signal"
    }

    static func noteURL(pid: Int32, in directory: URL) -> URL {
        directory.appendingPathComponent(noteFileName(pid: pid))
    }

    /// Arm the handlers.  Idempotent; safe to call from any thread.
    ///
    /// Call this as early as a client can — before loading a sequence, before any C++ runs.
    /// A crash during startup is exactly as worth reporting as one during processing, and
    /// costs nothing extra to cover.
    ///
    /// - Parameters:
    ///   - directory: where to leave the note. Defaults to the run-marker directory, which
    ///     is what pairs a note with a marker.
    ///   - logPath: star's own log file, if there is one yet. The handler appends one line to
    ///     it naming the signal — which is the difference between a log a user sends in that
    ///     stops mid-sentence for no visible reason, and one that says why. Usually not known
    ///     this early; call `setLogPath` once it is.
    public static func install(directory: URL? = nil, logPath: String? = nil) {
        let directory = directory ?? RunMarkerStore.defaultDirectory()

        // The handler cannot create directories — `mkdir` is not on the async-signal-safe
        // list, and more to the point a handler should do as little as possible. So the
        // directory has to exist before the crash, not after it.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let note = noteURL(pid: ProcessInfo.processInfo.processIdentifier,
                           in: directory).path

        _ = star_install_crash_handlers(note, logPath)

        if star_crash_handlers_installed() == 0 {
            Log.w("could not install crash handlers — a fatal signal will go unreported")
        } else {
            Log.i("crash handlers installed, note path \(note)")
        }
    }

    /// Point the handler at star's log file, once the client knows where it is.
    public static func setLogPath(_ path: String?) {
        star_set_crash_log_path(path)
    }

    /// Remove this process's note, if one somehow exists from a previous process that reused
    /// our pid. Called when a run begins, so a stale note cannot be mistaken for ours.
    static func clearNote(pid: Int32, in directory: URL) {
        try? FileManager.default.removeItem(at: noteURL(pid: pid, in: directory))
    }

    /// The signal name a note contains, or nil if there is no note.
    ///
    /// Tolerant of a truncated or empty note: the handler writes it while the process is
    /// already dying, so a note that exists but is unreadable still means "it caught
    /// something", and saying so is better than silently downgrading the report.
    static func caughtSignal(pid: Int32, in directory: URL) -> String? {
        let url = noteURL(pid: pid, in: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "an unidentified fatal signal" : text
    }
}
