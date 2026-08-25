// OCVFeatureSet.swift — Swift wrapper for OpenCV feature set
import StarCpp

public final class OCVFeatureSet: @unchecked Sendable {
    public let ref: OCVFeatureSetRef

    public init(ref: OCVFeatureSetRef) {
        self.ref = ref
    }

    deinit {
        ocv_feature_set_release(ref)
    }

    public static func createEmpty() -> OCVFeatureSet {
        OCVFeatureSet(ref: ocv_feature_set_create_empty())
    }

    public static func load(fromFilename filename: String) -> OCVFeatureSet? {
        var errMsg: UnsafePointer<CChar>?
        guard let r = ocv_feature_set_load(filename, &errMsg) else { return nil }
        return OCVFeatureSet(ref: r)
    }

    public var keypointCount: Int { Int(ocv_feature_set_keypoint_count(ref)) }

    /// Keypoint positions in full-resolution image coordinates.
    public func keypointPositions() -> [(x: Double, y: Double)] {
        let count = keypointCount
        guard count > 0 else { return [] }
        var xy = [Double](repeating: 0, count: count * 2)
        let copied = xy.withUnsafeMutableBufferPointer { buf in
            ocv_feature_set_keypoint_positions(ref, buf.baseAddress!, Int64(buf.count))
        }
        return (0..<Int(copied)).map { (x: xy[$0 * 2], y: xy[$0 * 2 + 1]) }
    }
    public var descriptorRows: Int { Int(ocv_feature_set_descriptor_rows(ref)) }
    public var descriptorCols: Int { Int(ocv_feature_set_descriptor_cols(ref)) }
    public var descriptorType: Int { Int(ocv_feature_set_descriptor_type(ref)) }

    public func write(toFilename filename: String) -> Bool {
        var errMsg: UnsafePointer<CChar>?
        return ocv_feature_set_write(ref, filename, &errMsg)
    }
}
