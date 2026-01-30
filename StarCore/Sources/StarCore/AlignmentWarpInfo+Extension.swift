import Foundation
import kht_bridge

public extension AlignmentWarpInfo {

    func toCodable() -> AlignmentWarpInfoCodable {
        let homographyArray: [Double]?

        if let wrapper = homography,
           let values = wrapper.homographyValues() {
            homographyArray = values.map { $0.doubleValue }
        } else {
            homographyArray = nil
        }

        return AlignmentWarpInfoCodable(
            homography: homographyArray,
            deviation: deviation,
            alignmentState: AlignmentState(objcState: alignmentState) ?? .unknown,
            frameIndex: Int(frameIndex)
        )
    }
}

public extension AlignmentWarpInfo {

    /// Reconstruct from Codable representation
    convenience init(from codable: AlignmentWarpInfoCodable) {
        let homographyWrapper: MatWrapper?

        if let h = codable.homography {
            precondition(h.count == 9, "Homography must have 9 elements")

            homographyWrapper = h.withUnsafeBufferPointer { buffer in
                MatWrapper(homographyValues: buffer.baseAddress!)
            }
        } else {
            homographyWrapper = nil
        }

        self.init(
          homography: homographyWrapper,
          warpedFrame: nil,
          warpedHorizon: nil,
          deviation: codable.deviation,
          alignmentState: codable.alignmentState.objcValue ?? AlignmentStateObjC.unknown,
          frameIndex: UInt(codable.frameIndex)
        )
    }
}
