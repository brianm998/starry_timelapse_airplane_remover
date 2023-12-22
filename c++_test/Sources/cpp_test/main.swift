// The Swift Programming Language
// https://docs.swift.org/swift-book

import KHTSwift
import StarCore
/*

 Next steps for kernel hough transform:

 add a step after initial outlier group detection that breaks the image up
 into 1024x1024 or smaller chunks, and runs the KHT on it.

 Then, iterate through the pixels close to each line, and see if they match up with
 some number of outlier groups.  If so, group them together.

 ideally we can get the outlier groups from the KHT directly, and then group them
 in the same way

 perhaps try loading full subtraction images here, and running KHT on the full image

 it's possible that the canny edge detector from main.cpp was messing things up
 */

let cloud_base = "/sp/tmp/LRT_05_20_2023-a9-4-aurora-topaz-star-aligned-subtracted"
let lots_of_clouds = [
  "232": "\(cloud_base)/LRT_00234-severe-noise.tiff",
  "574": "\(cloud_base)/LRT_00575-severe-noise.tiff",
  "140": "\(cloud_base)/LRT_00141-severe-noise.tiff",
  "160": "\(cloud_base)/LRT_00161-severe-noise.tiff",
  "184": "\(cloud_base)/LRT_00185-severe-noise.tiff",
  "192": "\(cloud_base)/LRT_00193-severe-noise.tiff",
  "229": "\(cloud_base)/LRT_00230-severe-noise.tiff",
  "236": "\(cloud_base)/LRT_00237-severe-noise.tiff",
  "567": "\(cloud_base)/LRT_00568-severe-noise.tiff",
  "686": "\(cloud_base)/LRT_00687-severe-noise.tiff",
  "783": "\(cloud_base)/LRT_00784-severe-noise.tiff",
  "1155": "\(cloud_base)/LRT_001156-severe-noise.tiff"
]

let no_cloud_base = "/sp/tmp/LRT_07_15_2023-a7iv-4-aurora-topaz-star-aligned-subtracted"
let no_clouds = [
  "800": "\(no_cloud_base)/LRT_00801-severe-noise.tiff",
  "654": "\(no_cloud_base)/LRT_00655-severe-noise.tiff",
  "689": "\(no_cloud_base)/LRT_00690-severe-noise.tiff",
  "882": "\(no_cloud_base)/LRT_00883-severe-noise.tiff",
  "349": "\(no_cloud_base)/LRT_00350-severe-noise.tiff",
  "241": "\(no_cloud_base)/LRT_00242-severe-noise.tiff"
]

let filename = "/tmp/LRT_00242-severe-noise_cropped_bigger.tif"
//let filename = "/tmp/LRT_00242-severe-noise_cropped.tif"//no_clouds["241"],
if    let image = try await PixelatedImage(fromFile: filename)
{
    // XXX segfault because array isn't one big chunk
    print("got [\(image.width), \(image.height)] image from \(filename)")

    switch image.imageData {
    case .eightBit(let imageArray):
        print("8 bit, fuck")
    case .sixteenBit(let imageArray):
        let numPixels = image.width*image.height
        
        let capacity = numPixels + numPixels // works -- XXX WTF is up here??
        //let capacity = numPixels + numPixels/2 // works -- XXX WTF is up here??
        //let capacity = numPixels + numPixels/3 // fails
        //let capacity = numPixels + numPixels/4 // fails
        
        var contiguousArray = ContiguousArray<UInt16>(unsafeUninitializedCapacity: capacity) { unsafePtr, initializedCount in
            for i in 0..<numPixels {
                unsafePtr[i] = imageArray[i]
            }
            initializedCount = numPixels
        }

        let lineImage = [UInt16](repeating: 0, count: numPixels)
        
        contiguousArray.withUnsafeMutableBufferPointer { ptr in
            let lines = kernelHoughTransform(image: ptr.baseAddress,
                                             width: Int32(image.width),
                                             height: Int32(image.height))
            print("got \(lines.count) lines")

            for i in 0..<20  {
                print("line[i] \(lines[i])")

                let (b1, b2) = lines[i].frameBoundries(width: image.width, height: image.height)
                
                /*
                 determine where the line meets the edges of the frame

                 iterate over each pixel and paint it on the line image
                 
                 */
            }
        }
    }
}



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



var image3: [UInt16] = [0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

/*
let lines = kernelHoughTransform(image: image3,
                                 width: 16,
                                 height: 16)
print("lines \(lines.count)")

for line in lines {
    print("line \(line)")
}*/

/*
let (theta1, rho1) = polarCoords(point1: DoubleCoord(x: 0, y: -1),
                                 point2: DoubleCoord(x: 8, y: 7))
let (theta1, rho1) = polarCoords(point1: DoubleCoord(x: 0, y: -2),
                                 point2: DoubleCoord(x: -2, y: 0))
print("### theta1 \(theta1) rho1 \(rho1)")
*/

/*
let (theta2, rho2) = polarCoords(point1: DoubleCoord(x: 0, y: 1),
                                 point2: DoubleCoord(x: 8, y: 9))
let (theta2, rho2) = polarCoords(point1: DoubleCoord(x: 0, y: 8),
                                 point2: DoubleCoord(x: 8, y: 0))
let (theta2, rho2) = polarCoords(point1: DoubleCoord(x: 2, y: 8),
                                 point2: DoubleCoord(x: 2, y: 0))
print("### theta1 \(theta1) rho1 \(rho1) theta2 \(theta2) rho2 \(rho2)")

 */
/*
let lines2 = kernelHoughTransform(image: image2,
                                  width: 12,
                                  height: 12)
print("lines2 \(lines2.count)")

for line in lines2 {
    print("line2 \(line)")
}
*/
/*

let horizontalLine = StandardLine(point1: DoubleCoord(x: 3, y: 1),
                                  point2: DoubleCoord(x: 8, y: 1))

print("horizontalLine \(horizontalLine) at y = 1")

let hph = horizontalLine.polarLine

print("hph \(hph)")


let verticalLine = StandardLine(point1: DoubleCoord(x: 1, y: 3),
                                  point2: DoubleCoord(x: 1, y: 8))

print("verticalLine \(verticalLine) at x = 1")

let vph = verticalLine.polarLine

print("vph \(vph)")
*/
/*
let fortyFiveLine = StandardLine(point1: DoubleCoord(x: 0, y: 1),
                                 point2: DoubleCoord(x: 4, y: 1))

print("fortyFiveLine \(fortyFiveLine)")

let polar = fortyFiveLine.polarLine

print("45 polar \(polar)")

print("standard again \(polar.standardLine)")
*/
