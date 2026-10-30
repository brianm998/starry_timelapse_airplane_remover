import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// A frame's first-round horizon, as the one row per column the horizon consensus reads out
/// of its mask — kept beside the mask so the consensus does not have to decode the mask.
///
/// The consensus (`HorizonConsensusBuild`) needs every frame's detection before any frame's
/// line can be written, and what it needs of each is `CombinedHorizonDetector.extractHorizonY`
/// of the `.horizon` mask: one row per column.  The mask is a full-resolution plane — 24 MB
/// of LZW at 6000×4000 — so reading them all is the 2 to 4 minutes at Full, and 10 under
/// Light, in which the CPU sits idle and no merge can start.  The detector that wrote the
/// mask has had that answer in memory the whole time.
///
/// So `ImageAccessor` writes this when it writes the mask, and the consensus reads it, and
/// reads the mask only for a frame with none: one written by a build that did not have this,
/// or one the mask has moved on from.  "Moved on" is decided by the mask file itself: the
/// sidecar records the mask's size and modification time, and is ignored unless they are the
/// mask's now.  A mask edited or redone by anything — the user's brush, a forced stage redo,
/// another run — invalidates it without anything having to remember to say so.
///
/// Columns, not the consensus's grid line, so that the sidecar does not depend on the
/// consensus's parameters: the grid line is cut from the columns by the same
/// `HorizonConsensus.gridLine` either way, and what the consensus computes is the same
/// whether the columns came from the mask or from here.
///
/// A small binary file, `<temp>/horizonLines/<frame>.hln`:
///
///     "HLN1"  width:Int32  height:Int32  maskBytes:Int64  maskModified:Double  rows:Int32 × width
///
/// All little-endian, `-1` for a column with no ground.  Not JSON: that is 30 KB of text per
/// frame to parse for what is a plain array of integers.
enum HorizonLineSidecar {

    private static let magic: [UInt8] = Array("HLN1".utf8)
    private static let headerBytes = 4 + 4 + 4 + 8 + 8

    /// What identifies the mask a sidecar was made from.
    struct Fingerprint: Equatable {
        let bytes: Int64
        let modified: Double
    }

    static func directory(_ config: Config) -> String {
        "\(config.tempOutputPath)/horizonLines"
    }

    static func path(frameIndex: Int, config: Config) -> String {
        "\(directory(config))/\(frameIndex).hln"
    }

    /// The mask file's size and modification time, or nil when there is no such file.
    static func fingerprint(ofMaskAt maskPath: String) -> Fingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: maskPath),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return Fingerprint(bytes: size.int64Value, modified: modified.timeIntervalSince1970)
    }

    /// Write `columns` — `extractHorizonY` of the mask at `maskPath`, which has just been
    /// written — for `frameIndex`.  Best effort: without one the consensus decodes the mask,
    /// as it always did.
    static func write(columns: [Int?], width: Int, height: Int, frameIndex: Int,
                      maskPath: String, config: Config) {
        guard columns.count == width, width > 0,
              let fingerprint = fingerprint(ofMaskAt: maskPath)
        else { return }
        var data = Data(capacity: headerBytes + 4 * width)
        data.append(contentsOf: magic)
        append(Int32(width), to: &data)
        append(Int32(height), to: &data)
        append(fingerprint.bytes, to: &data)
        append(fingerprint.modified.bitPattern, to: &data)
        for column in columns { append(Int32(column ?? -1), to: &data) }
        StarCore.mkdir(directory(config))
        do {
            // atomically: a torn file is one a later read would have to recognise
            try data.write(to: URL(fileURLWithPath: path(frameIndex: frameIndex, config: config)),
                           options: .atomic)
        } catch {
            Log.d("frame \(frameIndex) horizon line sidecar not written: \(error)")
        }
    }

    /// The columns recorded for `frameIndex`'s mask at `maskPath`, or nil when there are none
    /// for that mask as it is now: no sidecar, one for a different mask (size or time), for a
    /// frame of another size, or one that does not parse.
    static func read(frameIndex: Int, width: Int, height: Int,
                     maskPath: String, config: Config) -> [Int?]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath:
                                                    path(frameIndex: frameIndex, config: config)),
                                   options: .mappedIfSafe),
              data.count == headerBytes + 4 * width,
              data.prefix(4).elementsEqual(magic),
              let fingerprint = fingerprint(ofMaskAt: maskPath)
        else { return nil }

        let storedWidth: Int32 = load(Int32.self, from: data, at: 4)
        let storedHeight: Int32 = load(Int32.self, from: data, at: 8)
        let storedBytes: Int64 = load(Int64.self, from: data, at: 12)
        let storedModified = Double(bitPattern: load(UInt64.self, from: data, at: 20))
        guard Int(storedWidth) == width, Int(storedHeight) == height,
              Fingerprint(bytes: storedBytes, modified: storedModified) == fingerprint
        else { return nil }

        return (0..<width).map { x -> Int? in
            let row: Int32 = load(Int32.self, from: data, at: headerBytes + 4 * x)
            return row < 0 ? nil : Int(row)
        }
    }

    static func delete(frameIndex: Int, config: Config) {
        try? FileManager.default.removeItem(atPath: path(frameIndex: frameIndex, config: config))
    }

    // MARK: - little-endian plumbing

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private static func load<T: FixedWidthInteger>(_ type: T.Type, from data: Data,
                                                   at offset: Int) -> T {
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { buffer in
            data.copyBytes(to: buffer, from: (data.startIndex + offset)..<(data.startIndex + offset + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }
}
