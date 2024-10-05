import Foundation

public actor PixelStatusTracker {
    // indexed by id
    private var pixelStatus: [String: SortablePixel.Status] = [:]

    public func status(of pixel: SortablePixel) -> SortablePixel.Status {
        if let status = pixelStatus[pixel.id] {
            return status
        }
        return .unknown
    }

    public func record(status: SortablePixel.Status, for pixel: SortablePixel) {
        pixelStatus[pixel.id] = status
    }
}
