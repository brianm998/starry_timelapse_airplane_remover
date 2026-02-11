import Foundation

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// public global is safe because it's an actor
public let constants = Constants(detectionType: .strong)

public actor Constants {        // XXX rename this

    private var detectionType: DetectionType

    private var houghLineFinderArgs: HoughLineFinder.Args = .init()

    // threshold for initial classification into trash or not
    private var trashLevel: Double = -0.5

    // anything smaller than this is dust, adjusted for place on screen
    private var smallTrashMax: Int = 30

    private var frameRate: FrameRate = .fps_24
    private var codec: FFmpegCodec = .prores
    private var encoder: FFmpegEncoder = .prores
    private var pixelFormat: FFmpegPixelFormat = .yuv444p10le
    private var muxer: FFmpegMuxer = .mov
    
    public init(detectionType: DetectionType) {
        self.detectionType = detectionType
    }

    public func set(frameRate: FrameRate) {
        self.frameRate = frameRate
    }

    public func set(codec: FFmpegCodec) {
        self.codec = codec
    }

    public func set(encoder: FFmpegEncoder) {
        self.encoder = encoder
    }

    public func set(pixelFormat: FFmpegPixelFormat) {
        self.pixelFormat = pixelFormat
    }

    public func set(muxer: FFmpegMuxer) {
        self.muxer = muxer
    }

    public func getDetectionType() -> DetectionType { detectionType }
    
    public func set(detectionType: DetectionType) async {
        self.detectionType = detectionType
        contentTypeDidChangeClosure?(detectionType)
        if let contentTypeDidChangeClosure {
            contentTypeDidChangeClosure(detectionType)
        }
    }

    private var contentTypeDidChangeClosure: ((DetectionType) -> Void)? = nil
    
    public func didChange(_ closure: @escaping (DetectionType) -> Void) {
        self.contentTypeDidChangeClosure = closure
    }

    public func getHoughLineFinderArgs() -> HoughLineFinder.Args { houghLineFinderArgs }

    public func set(houghLineFinderArgs newArgs: HoughLineFinder.Args) async {
        self.houghLineFinderArgs = newArgs
    }

    public func getTrashLevel() -> Double { trashLevel }
    public func set(trashLevel: Double) { self.trashLevel = trashLevel }

    public func getSmallTrashMax() -> Int { smallTrashMax }
    public func set(smallTrashMax: Int) { self.smallTrashMax = smallTrashMax }
}

