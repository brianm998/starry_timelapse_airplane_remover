import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Records output frames star failed to write, so a run that could not produce what it was
/// asked for cannot report success.
///
/// The write path used to be incapable of reporting failure at all: `mat_wrapper_write_to`
/// returned void, caught its own exception, logged it in C++, and returned. Swift never heard
/// about it. On a full disk — the obvious way for this to happen on a 42MP sequence — star
/// would work through every frame, write nothing, and exit 0 with an empty output directory.
///
/// Now the whole chain returns a result, and a failure on the *output* path lands here. Two
/// consumers, deliberately separate:
///
///   - `StarWarnings`, immediately, so the user sees it while the run is still going rather
///     than discovering an empty directory afterwards;
///   - the run's error list, at the end, so the cli exits non-zero and keeps the temp
///     directory for a resume.
///
/// Only output frames. Previews, masks and debug images use the same write call, and a
/// failure there is worth a log line but is not worth failing a run over.
public actor OutputWriteFailures {

    public static let shared = OutputWriteFailures()

    public struct Failure: Sendable, Equatable {
        public let path: String
        public let frameIndex: Int?

        public var description: String {
            if let frameIndex {
                return "frame \(frameIndex): could not write output to \(path)"
            }
            return "could not write output to \(path)"
        }
    }

    private var failures: [Failure] = []

    /// Whether a warning has already been posted for this run.
    ///
    /// One warning, not one per frame: a full disk fails every remaining frame, and a
    /// hundred identical alerts is not a hundred times more informative. `StarWarnings`
    /// would rate-limit them anyway, but only for 30 seconds at a time, and a long run
    /// would keep re-raising it.
    private var warned = false

    public func record(path: String, frameIndex: Int? = nil) async {
        failures.append(Failure(path: path, frameIndex: frameIndex))
        Log.e("failed to write output image to \(path)")

        guard !warned else { return }
        warned = true

        await StarWarnings.shared.post(StarWarning(
          kind: .outputWriteFailed,
          severity: .critical,
          message: localized("warning.output_write_failed.message", path),
          suggestion: localized("warning.output_write_failed.suggestion")
        ))
    }

    public func all() -> [Failure] { failures }

    public func descriptions() -> [String] { failures.map(\.description) }

    public func isEmpty() -> Bool { failures.isEmpty }

    /// Forget everything. For the gui and the daemon, which process more than one sequence
    /// in a process and must not carry the last one's failures into the next.
    public func reset() {
        failures = []
        warned = false
    }
}
