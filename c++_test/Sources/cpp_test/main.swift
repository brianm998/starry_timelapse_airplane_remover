// The Swift Programming Language
// https://docs.swift.org/swift-book

import KHTSwift

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

let lines = kernelHoughTransform(image: image2,
                                 width: 12,
                                 height: 12)
print("lines \(lines.count)")

for line in lines {
    print("line \(line)")
}


let lines2 = kernelHoughTransform(image: image2,
                                  width: 12,
                                  height: 12)
print("lines2 \(lines2.count)")

for line in lines2 {
    print("line2 \(line)")
}



