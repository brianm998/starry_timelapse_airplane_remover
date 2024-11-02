import Foundation
import logging

public actor PixelStatusTracker {

    public let frameIndex: Int
    // row major indexed
    private var pixelStatus: [SortablePixel.Status]
    let imageWidth: Int
    let imageHeight: Int

    public init(frameIndex: Int,
                imageWidth: Int,
                imageHeight: Int)
    {
        self.frameIndex = frameIndex
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.pixelStatus = [SortablePixel.Status](repeating: .unknown,
                                                  count: imageWidth*imageHeight)
    }
    
    public func status(of pixel: SortablePixel) -> SortablePixel.Status {
        pixelStatus[pixel.y*imageWidth+pixel.x]
    }

    public func record(status: SortablePixel.Status, for pixel: SortablePixel) {
//        if frameIndex == 9 {
//            Log.d("frame \(frameIndex) record status \(status) for pixel \(pixel)")
//        }
        pixelStatus[pixel.y*imageWidth+pixel.x] = status
    }
}
