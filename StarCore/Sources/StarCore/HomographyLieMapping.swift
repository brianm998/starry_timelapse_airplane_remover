import Foundation
import kht_bridge

public class HomographyLieMapping {
    static func log(_ h: [Double]) -> [Double] {
        kht_bridge.HomographyLie.logHomography(h.map(NSNumber.init)).map { $0.doubleValue }
    }

    static func exp(_ v: [Double]) -> [Double] {
        kht_bridge.HomographyLie.expHomography(v.map(NSNumber.init)).map { $0.doubleValue }
    }
}
