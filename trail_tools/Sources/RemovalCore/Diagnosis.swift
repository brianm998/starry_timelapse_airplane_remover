import Foundation

/// An outlier group of the frame that touches a failing trail, as `--temp` found it.
public struct GroupTouch: Sendable {
    public var id: UInt16
    public var pixels: Int
    public var decision: String
    public var willRemove: Bool?
    public var trash: Bool
    public init(id: UInt16, pixels: Int, decision: String, willRemove: Bool?, trash: Bool) {
        self.id = id; self.pixels = pixels; self.decision = decision; self.willRemove = willRemove; self.trash = trash
    }
}

public enum Diagnosis {
    /// Why a trail Star was meant to remove is still there, from the groups that touch it (decision data of a kept temp directory).
    public static func classify(_ touches: [GroupTouch], totalGroups: Int) -> String {
        let real = touches.filter { !$0.trash }
        if touches.isEmpty { return "not detected: no outlier group (of \(totalGroups) in the frame, nor any dust) touches the trail" }
        if real.isEmpty {
            return "detected but discarded as dust: \(touches.count) dust group(s) touch it (ids \(touches.map { String($0.id) }.joined(separator: ",")))"
        }
        func list(_ g: [GroupTouch]) -> String { g.map { "#\($0.id) \($0.pixels)px \($0.decision)" }.joined(separator: "; ") }
        let removing = real.filter { $0.willRemove == true }
        if removing.isEmpty {
            return "misclassified: \(real.count) group(s) touch it and all were decided keep: \(list(real))"
        }
        return "painting/merge problem: \(removing.count) of \(real.count) touching group(s) were decided remove but the trail is still in the output: \(list(real))"
    }
}
