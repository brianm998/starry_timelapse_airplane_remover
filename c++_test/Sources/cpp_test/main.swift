// The Swift Programming Language
// https://docs.swift.org/swift-book

import KHTSwift
import StarCore
import logging


Log.add(handler: ConsoleLogHandler(at: .debug),
        for: .console)

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

//let filename = "/tmp/LRT_00242-severe-noise_cropped_bigger.tif"

//let filename = "/sp/tmp/really_small_test.tiff"
//let filename = "/sp/tmp/10_pixels_square.tiff"
//let filename = "/sp/tmp/20x40_test.tif"

//let filename = "/sp/tmp/foobar3.tif"

//let filename = "/tmp/LRT_00242-severe-noise_cropped_bigger.tif"
//let filename = "/tmp/LRT_00242-severe-noise_cropped.tif"
//let filename = "/tmp/LRT_00242-severe-noise_cropped.tif"


//let filename = "/sp/tmp/LRT_05_20_2023-a9-4-aurora-topaz-star-aligned-subtracted/LRT_00234-severe-noise.tiff"
let filename = "/sp/tmp/LRT_07_15_2023-a7iv-4-aurora-topaz-star-aligned-subtracted/LRT_00242-severe-noise.tiff"


//let filename = "/tmp/LRT_00242-severe-noise_cropped.tif"//no_clouds["241"],
if let image = try await PixelatedImage(fromFile: filename)
{
    Log.d("got [\(image.width), \(image.height)] image from \(filename)")

    let matrix = image.splitIntoMatrix(maxWidth: 1024, maxHeight: 1024)

    for element in matrix {

        Log.d("processing element [\(element.x), \(element.y)]")
        try element.image.writeTIFFEncoding(toFilename: "/tmp/element_base_\(element.x)_\(element.y).tiff")

        
        let lines = element.image.kernelHoughTransform(maxThetaDiff: 10,
                                                       maxRhoDiff: 10,
                                                       minLineCount: 2000,
                                                       minResults: 6)
        
        let numPixels = element.image.width*element.image.height

        var lineImage = [UInt16](repeating: 0, count: numPixels)
        
        Log.d("got \(lines.count) lines")

        let diff: UInt16 = 0x0200
        var amount: UInt16 = 0xFFFF 
        var adjustment: UInt16 = 0xFFFF
        var base: UInt16 = 0x2000
        /*
        if lines.count > 0,
           lines[0].count + Int(base) < 0xFFFF
        {
            adjustment = 0xFFFF/UInt16(lines[0].count) + base
        }
        */
        for i in 0..<lines.count  {
            Log.d("line[i] \(lines[i])")
            
            // where does this line intersect with the edges of image frame?
            let frameEdgeMatches = lines[i].frameBoundries(width: element.image.width,
                                                           height: element.image.height)

            if frameEdgeMatches.count == 0 {
                Log.d("this line is out of frame")
            } else if frameEdgeMatches.count == 1 {
                Log.w("only one edge match")
            } else if frameEdgeMatches.count == 2 {
                // sunny day case
                //Log.d("frameEdgeMatches \(frameEdgeMatches[0]) \(frameEdgeMatches[1])")
                let line = StandardLine(point1: frameEdgeMatches[0],
                                        point2: frameEdgeMatches[1])
                
                let x_diff = abs(frameEdgeMatches[0].x - frameEdgeMatches[1].x)
                let y_diff = abs(frameEdgeMatches[0].y - frameEdgeMatches[1].y)
                
                let iterateOnXAxis = x_diff > y_diff

                if iterateOnXAxis {
                    for x in 0..<element.image.width {
                        let y = Int(line.y(forX: Double(x)))
                        if y > 0,
                           y < element.image.height
                        {
                            var value: UInt16 = 0xFFFF

                            let valueD = Double(0xFFFF - base)/0xFFFF * Double(lines[i].count) + Double(base)
                            if valueD < 0xFFFF {
                                value = UInt16(valueD)
                            } else {
                                Log.e("fuck \(valueD) > 0xFFFF")
                                value = 0xFFFF
                            }
                            
                            let index = y*element.image.width+x
                            if lineImage[index] < value {
                                lineImage[index] = value
                            }
                        }
                    }
                } else {
                    for y in 0..<element.image.height {
                        let x = Int(line.x(forY: Double(y)))
                        if x > 0,
                           x < element.image.width
                        {
                            var value: UInt16 = 0xFFFF
                            if lines[i].count < 0xFFFF {

                                /*
                                 base = 10
                                 count = 0, output = 10
                                 count = 100, output = 100

                                 (100-10)/100 * count /  + 10
                                 
                                 */
                                let valueD = Double(0xFFFF - base)/0xFFFF * Double(lines[i].count) + Double(base)
                                if valueD < 0xFFFF {
                                    value = UInt16(valueD)
                                } else {
                                    Log.e("fuck \(valueD) > 0xFFFF")
                                    value = 0xFFFF
                                }
                            }
                            let index = y*element.image.width+x
                            if lineImage[index] < value {
                                lineImage[index] = value
                            }
                        }
                    }
                }
                if amount > diff {
                    amount -= diff
                }
                
            } else {
                Log.w("frameEdgeMatches \(frameEdgeMatches) WTF")
            }
            
            /*
             determine where the line meets the edges of the frame

             iterate over each pixel and paint it on the line image
             
             */
        }

        let outputImage = PixelatedImage(width: element.image.width,
                                         height: element.image.height,
                                         grayscale16BitImageData: lineImage)

        
        try outputImage.writeTIFFEncoding(toFilename: "/tmp/element_lines_\(element.x)_\(element.y).tiff")
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
Log.d("lines \(lines.count)")

for line in lines {
    Log.d("line \(line)")
}*/

/*
let (theta1, rho1) = polarCoords(point1: DoubleCoord(x: 0, y: -1),
                                 point2: DoubleCoord(x: 8, y: 7))
let (theta1, rho1) = polarCoords(point1: DoubleCoord(x: 0, y: -2),
                                 point2: DoubleCoord(x: -2, y: 0))
Log.d("### theta1 \(theta1) rho1 \(rho1)")
*/

/*
let (theta2, rho2) = polarCoords(point1: DoubleCoord(x: 0, y: 1),
                                 point2: DoubleCoord(x: 8, y: 9))
let (theta2, rho2) = polarCoords(point1: DoubleCoord(x: 0, y: 8),
                                 point2: DoubleCoord(x: 8, y: 0))
let (theta2, rho2) = polarCoords(point1: DoubleCoord(x: 2, y: 8),
                                 point2: DoubleCoord(x: 2, y: 0))
Log.d("### theta1 \(theta1) rho1 \(rho1) theta2 \(theta2) rho2 \(rho2)")

 */
/*
let lines2 = kernelHoughTransform(image: image2,
                                  width: 12,
                                  height: 12)
Log.d("lines2 \(lines2.count)")

for line in lines2 {
    Log.d("line2 \(line)")
}
*/
/*

let horizontalLine = StandardLine(point1: DoubleCoord(x: 3, y: 1),
                                  point2: DoubleCoord(x: 8, y: 1))

Log.d("horizontalLine \(horizontalLine) at y = 1")

let hph = horizontalLine.polarLine

Log.d("hph \(hph)")


let verticalLine = StandardLine(point1: DoubleCoord(x: 1, y: 3),
                                  point2: DoubleCoord(x: 1, y: 8))

Log.d("verticalLine \(verticalLine) at x = 1")

let vph = verticalLine.polarLine

Log.d("vph \(vph)")
*/
/*
let fortyFiveLine = StandardLine(point1: DoubleCoord(x: 0, y: 1),
                                 point2: DoubleCoord(x: 4, y: 1))

Log.d("fortyFiveLine \(fortyFiveLine)")

let polar = fortyFiveLine.polarLine

Log.d("45 polar \(polar)")

Log.d("standard again \(polar.standardLine)")
*/
