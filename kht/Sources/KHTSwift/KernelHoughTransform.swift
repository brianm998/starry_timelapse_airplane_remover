import kht_bridge

public struct Line: Codable {
    public let theta: Double           // angle in degrees
    public let rho: Double             // distance in pixels
    public let count: Int

    public init(theta: Double,
                rho: Double,
                count: Int)
    {
        self.theta = theta
        self.rho = rho
        self.count = count
    }
}

public func kernelHoughTransform(image: [UInt16],
                                 width: Int32,
                                 height: Int32, 
                                 clusterMinSize: Int32 = 10,
                                 clusterMinDeviation: Double = 2.0,
                                 delta: Double = 0.5,
                                 kernelMinHeight: Double = 0.002,
                                 nSigmas: Double = 2.0) -> [Line]
{
    var ret: [Line] = []

    // for some reason the KHT code munges the input array, so copy it
    var mutableImage = image 
    
    mutableImage.withUnsafeMutableBufferPointer() { imagePtr in
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
                    ret.append(Line(theta: line.theta, rho: line.rho, count: Int(line.count)))
                }
            }
        }
    }
    return ret
}
