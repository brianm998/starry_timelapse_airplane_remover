import Foundation
import StarCppBridge

public class HomographyLieMapping {
    static func log(_ h: [Double]) -> [Double] {
        HomographyLie.log(h)
    }

    static func exp(_ v: [Double]) -> [Double] {
        HomographyLie.exp(v)
    }
}
