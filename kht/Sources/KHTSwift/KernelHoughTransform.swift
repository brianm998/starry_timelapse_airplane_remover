import kht

public struct Line {
    let rho: Double
    let theta: Double
    let count: Int32
}

public func kernelHoughTransform(image: inout [UInt16],
                                 width: Int,
                                 height: Int, 
                                 clusterMinSize: Int32 = 10,
                                 clusterMinDeviation: Double = 2.0,
                                 delta: Double = 0.5,
                                 kernelMinHeight: Double = 0.002,
                                 nSigmas: Double = 2.0) -> [Line]
{
    var lineList: kht.ListOfLines = kht.ListOfLines()
    image.withUnsafeMutableBufferPointer() { imagePtr in
        kht.run_kht(&lineList,
                    imagePtr.baseAddress,
                    height,
                    width,
                    clusterMinSize,
                    clusterMinDeviation,
                    delta,
                    kernelMinHeight,
                    nSigmas)
    }
    var ret: [Line] = []
    for line in lineList {

        // XXX fix negative rho

        // XXX adjust for centeral origin
        
        ret.append(Line(rho: line.rho,
                        theta: line.theta,
                        count: line.votes))
    }
    return ret
}
