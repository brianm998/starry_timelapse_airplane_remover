// HomographyLie.swift — Swift wrapper for Lie group homography operations
import kht_bridge

public enum HomographyLie {
    /// Converts a 3x3 homography (9 doubles, row-major) to 8D log-space vector.
    public static func log(_ homography: [Double]) -> [Double] {
        precondition(homography.count == 9)
        var out = [Double](repeating: 0, count: 8)
        homography.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                homography_lie_log(inBuf.baseAddress!, outBuf.baseAddress!)
            }
        }
        return out
    }

    /// Converts an 8D log-space vector back to 3x3 homography (9 doubles, row-major).
    public static func exp(_ vector: [Double]) -> [Double] {
        precondition(vector.count == 8)
        var out = [Double](repeating: 0, count: 9)
        vector.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                homography_lie_exp(inBuf.baseAddress!, outBuf.baseAddress!)
            }
        }
        return out
    }
}
