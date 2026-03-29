import Foundation
import KHTSwift

public extension AlignmentWarpInfo {

    func toCodable() -> AlignmentWarpInfoCodable {
        let homographyArray: [Double]?

        if let wrapper = homography,
           let values = wrapper.homographyValues {
            homographyArray = values
        } else {
            homographyArray = nil
        }

        return AlignmentWarpInfoCodable(
            homography: homographyArray,
            deviation: deviation,
            alignmentState: AlignmentState(objcState: alignmentState) ?? .unknown,
            frameIndex: frameIndex
        )
    }

    /// Reconstruct from Codable representation
    static func from(codable: AlignmentWarpInfoCodable) -> AlignmentWarpInfo {
        let homographyWrapper: MatWrapper?

        if let h = codable.homography {
            precondition(h.count == 9, "Homography must have 9 elements")
            homographyWrapper = MatWrapper.fromHomographyValues(h)
        } else {
            homographyWrapper = nil
        }

        return AlignmentWarpInfo(
          homography: homographyWrapper,
          deviation: codable.deviation,
          alignmentState: codable.alignmentState.objcValue ?? .unknown,
          frameIndex: codable.frameIndex
        )
    }
}
