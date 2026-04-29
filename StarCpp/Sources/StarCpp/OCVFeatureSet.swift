// OCVFeatureSet.swift — Swift wrapper for OpenCV feature set
import starcpp_bridge

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
    public var descriptorRows: Int { Int(ocv_feature_set_descriptor_rows(ref)) }
    public var descriptorCols: Int { Int(ocv_feature_set_descriptor_cols(ref)) }
    public var descriptorType: Int { Int(ocv_feature_set_descriptor_type(ref)) }

    public func write(toFilename filename: String) -> Bool {
        var errMsg: UnsafePointer<CChar>?
        return ocv_feature_set_write(ref, filename, &errMsg)
    }
}
