import Foundation
import Cocoa

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

enum TerminalColor: String {
    case black = "\u{001b}[30m"
    case red = "\u{001b}[31m"
    case green = "\u{001b}[32m"
    case yellow = "\u{001b}[33m"
    case blue = "\u{001b}[34m"
    case magenta = "\u{001b}[35m"
    case cyan = "\u{001b}[36m"
    case white = "\u{001b}[37m"
    case reset = "\u{001b}[0m"
}

// progress is between 0 and 1
func progress_bar(length: Int, progress: Double) -> String {

    var progress_bar: String = TerminalColor.blue.rawValue + "["
    for i in 0 ..< length {
        if Double(i)/Double(length) < progress {
            progress_bar += TerminalColor.green.rawValue + "*";
        } else {
            progress_bar += TerminalColor.yellow.rawValue + "-";
        }
    }
    progress_bar += TerminalColor.blue.rawValue+"]"+TerminalColor.reset.rawValue;

    return progress_bar
}

// progress is between 0 and 1
func reverse_progress_bar(length: Int, progress: Double) -> String {

    var progress_bar: String = TerminalColor.blue.rawValue + "["
    for i in (0 ..< length).reversed() {
        if Double(i)/Double(length) < progress {
            progress_bar += TerminalColor.green.rawValue + "*";
        } else {
            progress_bar += TerminalColor.yellow.rawValue + "-";
        }
    }
    progress_bar += TerminalColor.blue.rawValue+"]"+TerminalColor.reset.rawValue;

    return progress_bar
}

class UpdateableLogLine {
    let name: String            // a unique name
    var message: String         // the current log message
    var value: Double           // a sortable value
    var value2: Double?         // a second sortable value, used when the first values are equal

    init(name: String,
         message: String,
         value: Double,
         value2: Double? = nil)
    {
        self.name = name
        self.message = message
        self.value = value
        self.value2 = value2
    }

    func copyFrom(other: UpdateableLogLine) {
        self.message = other.message
        self.value = other.value
        self.value2 = other.value2
    }
}

@available(macOS 10.15, *) 
actor UpdateableLog {

    var list: [UpdateableLogLine] = []

    func sort() {
        self.clear()
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
            print(line.message/*, terminator:""*/)
            //print("\n", terminator:"")a
            print("\u{001b}[\(index)B", terminator:"") // move cursor down index lines
            index -= 1
        }
    }

    func clear() {
        let screen_char_width = 120 // XXX fix this, get it from the console somehow

        var index = self.list.count
        for line in self.list {
            print("\u{001b}[\(index)A", terminator:"") // move cursor up index lines
            for i in 0 ..< screen_char_width {
                print(" ", terminator:"")
            }
            print("\n", terminator:"")
            print("\u{001b}[\(index)B", terminator:"") // move cursor down index lines
            index -= 1
        }
        
    }

    func log(name: String,
             message: String,
             value: Double,
             value2: Double? = nil)
    {
        var found = false
        let new_logline = UpdateableLogLine(name: name,
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
