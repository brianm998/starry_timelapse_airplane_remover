import Foundation
import KHTSwift

// these values are used for creating an initial config when processing a new sequence
public struct Defaults {

    /*
     The outlier max and min thresholds below are percentages of how much a
     pixel is brighter than the same pixel in adjecent frames.

     If a pixel is outlierMinThreshold percentage brighter, then it is an outlier.
     If a pixel is brighter than outlierMaxThreshold, then it is painted over fully.
     If a pixel is between these two values, then an alpha between 0-1 is applied.

     A lower outlierMaxThreshold results in detecting more outlier groups.
     A higher outlierMaxThreshold results in detecting fewer outlier groups.
     */
//    public static let outlierMaxThreshold: Double = 11.86 // misses some streaks
//    public static let outlierMaxThreshold: Double = 11.00 // still misses some

    //public static let outlierMaxThreshold: Double = 12.2


    
    //public static let outlierMaxThreshold: Double = 11.50 // gets most, misses a few small parts
    // adjusted for removed /4 division
    public static let outlierMaxThreshold: Double = 2.5

    // groups smaller than this are completely ignored
    // this is scaled by image size:
    //   12 megapixels will get this value
    //   larger ones more, smaller less 
    public static let minGroupSize: Int = 50
}

public enum Edge {
    case vertical
    case horizontal
}


