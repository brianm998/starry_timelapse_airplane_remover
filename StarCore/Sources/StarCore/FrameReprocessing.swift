import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// What a reprocess of a frame throws away before the frame graph runs again.
//
// This is one function so every client (the macOS gui, the daemon behind the Kotlin client)
// resets a frame the same way for the same `FrameReprocessingType`.

extension FrameAirplaneRemover {

    /// Reset this frame's per-frame work so the frame graph recomputes it: back to
    /// `.unprocessed`, its output images (and, for `.alignment`, its aligned and subtraction
    /// images) deleted, its neighbour counts and its stored outliers cleared.
    /// Never touches the original image or a user-painted horizon.
    public func clearProcessing(deleting type: FrameReprocessingType) async {
        await set(state: .unprocessed)

        imageAccessor.deleteAllImages(frameIndex: frameIndex, reprocessingType: type)

        await setNumberOfAlignedFrames()
        await setNumberOfStaticNeighborFrames()
        do {
            try await removeNumberOfAlignedImagesForThisFrameFile()
        } catch {
            Log.e("frame \(frameIndex) error removing its aligned image count: \(error)")
        }

        // The outlier binaries; a stale one would be loaded by the next run.
        do {
            try await deleteOutliers()
        } catch {
            Log.e("frame \(frameIndex) error removing its outliers: \(error)")
        }
    }

    /// Prepare this frame for a reprocess of `type`.  The per-type work is:
    ///
    /// - `.none`: nothing.  The next run keeps whatever is already done.
    /// - `.allHorizons`: nothing here.  The caller owns the horizon work that type implies.
    /// - `.horizons`: delete the per-frame horizon images only.
    /// - `.alignment`: clear everything that comes after alignment too, and the aligned and
    ///   subtraction images with it.
    /// - `.outliers`: clear the outliers and what is built on them, keeping alignment.
    /// - `.everything`: delete every processed image and the outliers, then clear.
    public func resetForReprocessing(_ type: FrameReprocessingType) async {
        switch type {
        case .none, .allHorizons:
            break
        case .horizons:
            await deleteHorizonImages()
        case .alignment, .outliers:
            await clearProcessing(deleting: type)
        case .everything:
            deleteAllProcessedImages()
            await clearProcessing(deleting: type)
        }
    }
}
