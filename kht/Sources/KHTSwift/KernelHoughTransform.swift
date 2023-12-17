import kht_bridge

public struct Line {
    let theta: Double
    let rho: Double
    let count: Int32
}

public func kernelHoughTransform(image: inout [UInt16],
                                 width: Int32,
                                 height: Int32, 
                                 clusterMinSize: Int32 = 10,
                                 clusterMinDeviation: Double = 2.0,
                                 delta: Double = 0.5,
                                 kernelMinHeight: Double = 0.002,
                                 nSigmas: Double = 2.0) -> [Line]
{
    var ret: [Line] = []
    image.withUnsafeMutableBufferPointer() { imagePtr in
        if let lines = KHTBridge.translate(imagePtr.baseAddress,
                                           width: width,
                                           height: width,
                                           clusterMinSize: clusterMinSize,
                                           clusterMinDeviation: clusterMinDeviation,
	                                   delta: delta,
                                           kernelMinHeight: kernelMinHeight,
                                           nSigmas: nSigmas)
        {
            for line in lines {
                if let line = line as? KHTBridgeLine {
                    ret.append(Line(theta: line.theta, rho: line.rho, count: line.count))
                }
            }
        }
    }
    return ret
}
