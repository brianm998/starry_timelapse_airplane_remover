import Foundation

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

extension UInt64 {
    /// A byte count for a user to read, in whichever unit does not make it meaningless.
    ///
    /// Fixed units do not work here because the same messages carry numbers spanning six
    /// orders of magnitude — a 128GB machine and a 14MB scrap of free space on a small volume.
    /// Formatting everything as GB produced "only 0.0GB is free", which is both useless and
    /// slightly insulting; formatting everything as MB would give a memory report reading
    /// "131072MB".
    ///
    /// Not `ByteCountFormatter`: it is locale-dependent and uses decimal units by default, so
    /// the same run would describe the same volume differently depending on the machine, and
    /// its numbers would not match what `df` says.
    var humanReadableBytes: String {
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        let value = Double(self)

        if value >= gb  { return String(format: "%.1fGB", value / gb) }
        if value >= mb  { return String(format: "%.0fMB", value / mb) }
        if value >= kb  { return String(format: "%.0fKB", value / kb) }
        return "\(self) bytes"
    }
}
