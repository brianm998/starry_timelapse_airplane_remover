// The Swift Programming Language
// https://docs.swift.org/swift-book

import kht


var lineList: kht.ListOfLines = kht.ListOfLines()
var image: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                      1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                      0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
let height = 10
let width = 10
let cluster_min_size: Int32 = 10
let cluster_min_deviation: Double = 2.0
let delta: Double = 0.5
let kernel_min_height: Double = 0.002
let n_sigmas: Double = 2.0

image.withUnsafeMutableBufferPointer() { imagePtr in
    kht.run_kht(&lineList,
                imagePtr.baseAddress,
                height,
                width,
                cluster_min_size,
                cluster_min_deviation,
                delta,
                kernel_min_height,
                n_sigmas)
    print("lines \(lineList.count)")
}

