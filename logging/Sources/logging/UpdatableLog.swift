import Foundation
import Cocoa

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

    func setScreenWidth(_ width: UInt16) {
        screen_width = width
    }
    
    public init() {
        var w = winsize()
        let ioctl_ret = ioctl(STDOUT_FILENO, TIOCGWINSZ, &w)
        if ioctl_ret == 0 {
            screen_width = w.ws_col
        }
        /*
         XXX attempt to get sigwinch signals to alert us to changes in the console size
         
        Task(priority: .userInitiated) {
            await MainActor.run { subscribe() }
        }

         */
    }

    @MainActor
    func subscribe() {
        var w = winsize()
        let sigwinchSrc = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
        sigwinchSrc.setEventHandler {
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
                Task {
                    await self.setScreenWidth(w.ws_col)
                }
                /*
                if let updatable = updatable {
                    Task(priority: .userInitiated) {
                        await updatable.redraw()
                    }
                }*/
//                print("rows:", w.ws_row, "cols", w.ws_col)
            }
        }
//        sigwinchSrc.resume()

//        dispatchMain()
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
        self.redraw()
    }

    func redraw() {
        var index = self.list.count
        for line in self.list {
            print("\u{001b}[\(index)A", terminator:"") // move cursor up index lines 
            let num_extra_spaces = Int(screen_width)-line.printableLength-1

            //Log.i("num_extra_spaces \(num_extra_spaces)")
            
            var extra_spaces: String = ""
            
            if num_extra_spaces > 0 { for _ in 0 ..< num_extra_spaces { extra_spaces += " " } }

            print(line.message + extra_spaces, terminator:"")
            print("\n", terminator:"")
            print("\u{001b}[\(index)B", terminator:"") // move cursor down index lines
            index -= 1
        }
    }

    public func log(name: String,
                    message: String,
                    value: Double,
                    value2: Double? = nil)
    {
        var found = false
        let new_logline = UpdatableLogLine(name: name,
                                           message: message,
                                           value: value,
                                           value2: value2);
        // first look at is it in the list
        for line in self.list {
            if line.name == name {
                found = true
                line.copyFrom(other: new_logline);
            }
        }

        if !found {
            // add to end of list by printing a blank line here
            self.list.append(new_logline)
            print("")
        }

        // lastly sort and redisplay
        self.sort()
    }
}
