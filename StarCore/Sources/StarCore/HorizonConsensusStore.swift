import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

extension HorizonConsensus {

    /// Whether `config` describes a run whose horizons the consensus decides: a moving
    /// camera, with horizon detection and earth alignment on, and the setting itself on.
    /// Painted references anchor it rather than switch it off.
    public static func applies(to config: Config) -> Bool {
        config.useHorizonConsensus && config.tripodHeadWasMoving
          && config.horizonDetectionEnabled && config.allowEarthAlignment
    }
}

/// Where a sequence's consensus lines live: one small file per frame in
/// `<temp>/horizonConsensus/`, beside the focal-length calibration that produced them.
///
/// Lines rather than masks, and not a `FrameViewMode`: a line is 1600 numbers where a mask is
/// a full-resolution image, and a new view mode would reach the daemon's protocol, the gui
/// and the desktop client for something only `FrameHorizonProcessor.loadOrCreateFinalHorizonMask`
/// reads.
public enum HorizonConsensusStore {

    /// One frame's consensus line, as written.
    public struct Record: Codable, Sendable, Equatable {
        public let version: Int
        /// Size of the frame the rows describe.
        public let width: Int
        public let height: Int
        /// First ground row at each of `rows.count` columns spread evenly across the frame,
        /// in full-resolution rows; `height` for a column with no ground.
        public let rows: [Int]

        public init(version: Int = HorizonConsensus.algorithmVersion,
                    width: Int, height: Int, rows: [Int]) {
            self.version = version
            self.width = width
            self.height = height
            self.rows = rows
        }

        /// The rows as the grid line `HorizonConsensus.columnRows` expands.
        public var line: [Float] { rows.map { Float($0) } }
    }

    public static func directory(_ config: Config) -> String {
        "\(config.tempOutputPath)/horizonConsensus"
    }

    public static func path(frameIndex: Int, config: Config) -> String {
        "\(directory(config))/\(frameIndex).json"
    }

    public static func calibrationPath(_ config: Config) -> String {
        "\(directory(config))/calibration.json"
    }

    public static func exists(frameIndex: Int, config: Config) -> Bool {
        FileManager.default.fileExists(atPath: path(frameIndex: frameIndex, config: config))
    }

    public static func write(line: [Float], frameIndex: Int,
                             width: Int, height: Int, config: Config) throws {
        let rows = line.map { row -> Int in
            guard row.isFinite else { return height }
            return max(0, min(height, Int(row.rounded())))
        }
        let data = try JSONEncoder().encode(Record(width: width, height: height, rows: rows))
        StarCore.mkdir(directory(config))
        // atomically: a torn file would be a line a later run reads and composites with
        try data.write(to: URL(fileURLWithPath: path(frameIndex: frameIndex, config: config)),
                       options: .atomic)
    }

    /// The frame's consensus line, or nil when there is none — or none this build wrote, or
    /// one for a frame of another size.
    public static func read(frameIndex: Int, width: Int, height: Int, config: Config) -> Record? {
        let path = path(frameIndex: frameIndex, config: config)
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let record = try? JSONDecoder().decode(Record.self, from: data)
        else { return nil }
        guard record.version == HorizonConsensus.algorithmVersion,
              record.width == width, record.height == height, !record.rows.isEmpty
        else {
            Log.w("frame \(frameIndex) horizon consensus line at \(path) is for version " +
                  "\(record.version) at \(record.width)x\(record.height), not " +
                  "\(HorizonConsensus.algorithmVersion) at \(width)x\(height) — ignoring it")
            return nil
        }
        return record
    }

    public static func delete(frameIndex: Int, config: Config) {
        try? FileManager.default.removeItem(atPath: path(frameIndex: frameIndex, config: config))
    }

    public static func writeCalibration(_ calibration: HorizonConsensus.Calibration,
                                        config: Config) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(calibration)
        StarCore.mkdir(directory(config))
        try data.write(to: URL(fileURLWithPath: calibrationPath(config)), options: .atomic)
    }

    public static func deleteCalibration(config: Config) {
        try? FileManager.default.removeItem(atPath: calibrationPath(config))
    }
}
