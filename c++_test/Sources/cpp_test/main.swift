// The Swift Programming Language
// https://docs.swift.org/swift-book

import kht

var image: [UInt16] = [0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
                       1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                       0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 1, 0, 0, 0, 0, 0, 0, 0,
                       0, 0, 1, 0, 0, 0, 0, 0, 0, 0]


var image2: [UInt16] = [0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1,
                        0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 1,
                        0, 0, 1, 0, 0, 0, 0, 0, 0, 1, 1, 0,
                        0, 0, 1, 0, 0, 0, 0, 0, 1, 1, 0, 0,
                        0, 0, 1, 0, 0, 0, 0, 1, 1, 0, 0, 0,
                        0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 0, 0,
                        0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0,
                        0, 0, 1, 0, 1, 1, 0, 0, 0, 0, 0, 0]


let lines = kernelHoughTransform(image: &image2,
                                 width: 12,
                                 height: 12)

print("lines \(lines.count)")

for line in lines {
    print("line \(line)")
}


func kernelHoughTransform(image: inout [UInt16],
                          width: Int,
                          height: Int, 
                          clusterMinSize: Int32 = 10,
                          clusterMinDeviation: Double = 2.0,
                          delta: Double = 0.5,
                          kernelMinHeight: Double = 0.002,
                          nSigmas: Double = 2.0) -> kht.ListOfLines
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

    // XXX fix negative rho

    // XXX adjust 
    
    return lineList
}
