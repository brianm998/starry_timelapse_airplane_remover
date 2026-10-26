import Foundation

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

public enum ConsoleColor: String, CaseIterable {
    case black   = "\u{001b}[30m"
    case red     = "\u{001b}[31m"
    case green   = "\u{001b}[32m"
    case yellow  = "\u{001b}[33m"
    case blue    = "\u{001b}[34m"
    case magenta = "\u{001b}[35m"
    case cyan    = "\u{001b}[36m"
    case white   = "\u{001b}[37m"
    case reset   = "\u{001b}[0m"
}

// progress is between 0 and 1
public func progressBar(length: Int, progress: Double) -> String {

    var progressBar: String = ConsoleColor.blue.rawValue + "["
    for i in 0 ..< length {
        if Double(i)/Double(length) < progress {
            progressBar += ConsoleColor.green.rawValue + "*";
        } else {
            progressBar += ConsoleColor.yellow.rawValue + "-";
        }
    }
    progressBar += ConsoleColor.blue.rawValue+"]"+ConsoleColor.reset.rawValue;

    return progressBar
}

// progress is between 0 and 1
public func reverseProgressBar(length: Int, progress: Double) -> String {

    var progressBar: String = ConsoleColor.blue.rawValue + "["
    for i in (0 ..< length).reversed() {
        if Double(i)/Double(length) < progress {
            progressBar += ConsoleColor.green.rawValue + "*";
        } else {
            progressBar += ConsoleColor.yellow.rawValue + "-";
        }
    }
    progressBar += ConsoleColor.blue.rawValue+"]"+ConsoleColor.reset.rawValue;

    return progressBar
}

public class UpdatableLogLine {
    let name: String            // a unique name
    var message: String         // the current log message
    var value: Double           // a sortable value
    var value2: Double?         // a second sortable value, used when the first values are equal

    public init(name: String,
                message: String,
                value: Double,
                value2: Double? = nil)
    {
        self.name = name
        self.message = message
        self.value = value
        self.value2 = value2
    }

    var printableLength: Int {
        var printable_message = message
        for type in ConsoleColor.allCases {
            printable_message = printable_message.replacingOccurrences(
              of: type.rawValue, with: "")
        }
        return printable_message.count
    }

    func copyFrom(other: UpdatableLogLine) {
        self.message = other.message
        self.value = other.value
        self.value2 = other.value2
    }
}

public actor UpdatableLog {

    var screen_width: UInt16 = 120

    var list: [UpdatableLogLine] = []

    /// Where drawn text goes. Standard output; replaceable so a test can see what was drawn.
    let output: @Sendable (String) -> Void

    /// How often the display is redrawn at most. A redraw rewrites every row on a terminal, and
    /// callers update many rows in a burst (every state change of every frame), so drawing on every
    /// update made the terminal the bottleneck of the run it was reporting on.
    public static let defaultRedrawInterval: TimeInterval = 0.25

    /// The most event rows (log messages, as opposed to named progress rows) kept on screen. Each
    /// distinct message used to be a row for good, so a run with many errors redrew a longer and
    /// longer list every time.
    public static let defaultMaxEventRows = 20

    private let redrawInterval: TimeInterval
    private let maxEventRows: Int
    private var eventRowNames: [String] = []
    private var lastDraw: Date?
    private var dirty = false
    private var trailingDrawScheduled = false
    private var batchDepth = 0

    /// How many times the display has been drawn, for tests.
    public private(set) var drawCount = 0

    func setScreenWidth(_ width: UInt16) {
        screen_width = width
    }

    public init(redrawInterval: TimeInterval = UpdatableLog.defaultRedrawInterval,
                maxEventRows: Int = UpdatableLog.defaultMaxEventRows,
                output: @escaping @Sendable (String) -> Void = { print($0, terminator: "") })
    {
        self.redrawInterval = redrawInterval
        self.maxEventRows = maxEventRows
        self.output = output
        #if !os(Windows)
        // POSIX: query the real terminal width via TIOCGWINSZ.
        // On Windows the equivalent is GetConsoleScreenBufferInfo from the
        // WinSDK module; until that's wired up we just stay on the 120-col
        // default initialised above.
        var w = winsize()
        let ioctl_ret = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w)
        if ioctl_ret == 0 {
            screen_width = w.ws_col
        }
        #endif
    }

    func sort() {
        let sorted_logs = self.list.sorted() { a, b in
            if a.value == b.value,
               let a_value2 = a.value2,
               let b_value2 = b.value2
            {
                return a_value2 < b_value2
            } else {
                return a.value < b.value
            }
        }
        self.list = sorted_logs
    }

    /// The whole display as one string: every row in turn, each reached by moving the cursor up
    /// from the bottom and padded to the screen width. Built first and written once, so a redraw is
    /// one write rather than five per row.
    func render() -> String {
        var frame = ""
        var index = self.list.count
        for line in self.list {
            frame += "\u{001b}[\(index)A"                    // move cursor up index lines
            let num_extra_spaces = Int(screen_width) - line.printableLength - 1
            frame += line.message
            if num_extra_spaces > 0 { frame += String(repeating: " ", count: num_extra_spaces) }
            frame += "\n"
            frame += "\u{001b}[\(index)B"                    // move cursor down index lines
            index -= 1
        }
        return frame
    }

    func redraw() {
        output(render())
        drawCount += 1
        lastDraw = Date()
        dirty = false
    }

    /// Draws now if it has been long enough since the last draw, else makes sure one happens when
    /// it has (so the final state is always shown, not just the last one that was due).
    private func requestRedraw() {
        dirty = true
        guard batchDepth == 0 else { return }
        let since = lastDraw.map { Date().timeIntervalSince($0) } ?? .infinity
        if since >= redrawInterval {
            redraw()
        } else if !trailingDrawScheduled {
            trailingDrawScheduled = true
            let wait = redrawInterval - since
            Task {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                await self.trailingDraw()
            }
        }
    }

    private func trailingDraw() {
        trailingDrawScheduled = false
        if dirty && batchDepth == 0 { redraw() }
    }

    /// Updates made between `beginBatch()` and `endBatch()` are drawn together, once, when the batch
    /// ends: a caller refreshing twenty rows is one draw, not twenty.
    public func beginBatch() { batchDepth += 1 }

    public func endBatch() {
        batchDepth = max(0, batchDepth - 1)
        if batchDepth == 0 && dirty {
            sort()
            // an explicit end of batch is the caller saying "now", so it is not throttled; the
            // caller (the progress monitor) is itself paced
            let since = lastDraw.map { Date().timeIntervalSince($0) } ?? .infinity
            if since >= redrawInterval { redraw() } else { requestRedraw() }
        }
    }

    /// Draw whatever is pending right now, ignoring the throttle. For the end of a run.
    public func flush() {
        sort()
        if dirty || lastDraw == nil { redraw() }
    }

    private func upsert(name: String, message: String, value: Double, value2: Double?) {
        let new_logline = UpdatableLogLine(name: name, message: message, value: value, value2: value2)
        if let existing = list.first(where: { $0.name == name }) {
            existing.copyFrom(other: new_logline)
        } else {
            // add to end of list by printing a blank line here
            list.append(new_logline)
            output("\n")
        }
    }

    public func log(name: String,
                    message: String,
                    value: Double,
                    value2: Double? = nil)
    {
        upsert(name: name, message: message, value: value, value2: value2)
        if batchDepth == 0 { sort() }
        requestRedraw()
    }

    /// A one-off message row, as opposed to a progress row that is updated in place. Only the most
    /// recent `maxEventRows` of these are kept.
    public func logEvent(name: String,
                         message: String,
                         value: Double,
                         value2: Double? = nil)
    {
        let isNew = !eventRowNames.contains(name)
        upsert(name: name, message: message, value: value, value2: value2)
        if isNew {
            eventRowNames.append(name)
            while eventRowNames.count > maxEventRows {
                let oldest = eventRowNames.removeFirst()
                list.removeAll { $0.name == oldest }
            }
        }
        if batchDepth == 0 { sort() }
        requestRedraw()
    }

    /// Rows currently held, for tests.
    public var rowCount: Int { list.count }
}
