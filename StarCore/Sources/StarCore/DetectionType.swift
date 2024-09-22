import Foundation
/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// how hard to we try to detect airplanes and such?
// the harder we try, the longer it takes, but the more results we get.
public enum DetectionType: String, Codable, CaseIterable, Sendable {
    case mild       // 2-4x faster than excessive, finds fewer dimmer airplanes
    case strong     // get more airplanes than normal and not take forever
    case excessive  // takes much longer, finds a LOT more bad signals
}
