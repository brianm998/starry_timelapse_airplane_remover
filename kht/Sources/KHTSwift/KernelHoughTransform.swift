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
        var rho = line.rho
        var theta = line.theta

        // invert negative rho, point it in the other direction
        if rho < 0 {
            rho = -rho 
            theta = (line.theta + 180).truncatingRemainder(dividingBy: 360)
        }

        // XXX adjust for central origin
        
        ret.append(Line(rho: rho,
                        theta: theta,
                        count: line.votes))
    }
    return ret
}
