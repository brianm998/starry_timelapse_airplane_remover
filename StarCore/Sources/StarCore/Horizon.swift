import Foundation
import CoreGraphics
import KHTSwift
import logging
import Cocoa
import kht_bridge

// this file has logic for horizon detection and analysis

public struct HorizonMask: Sendable {
    public let image: PixelatedImage
    public let horizonTopY: Int
    public let horizonBottomY: Int

    public var bounds: HorizonBounds {
        HorizonBounds(
          topY: horizonTopY,
          bottomY: horizonBottomY
        )
    }
}

public struct HorizonBounds: Sendable {
    public let topY: Int
    public let bottomY: Int
}


public struct HorizonStats {
    public let lowestBottomY: Int
    public let highestTopY: Int
    public let avgTopY: Double
    public let avgBottomY: Double
    public let medianTopY: Double
    public let medianBottomY: Double
    public let outlierCount: Int
}

/*

 HorizonStats(
  lowestBottomY: 685,
  highestTopY: 1019,
  avgTopY: 932.53,
  avgBottomY: 778.71,
  medianTopY: 922.0,
  medianBottomY: 823.0,
  outlierCount: 25
 )

 */

// calculate HorizonStats from an array of HorizonBounds
public extension Array where Element == HorizonBounds {
    
    func calculateStats() -> HorizonStats? {
        guard !self.isEmpty else { return nil }
        
        let tops = self.map { $0.topY }.sorted()
        let bottoms = self.map { $0.bottomY }.sorted()
        
        let lowestBottomY = bottoms.min()!
        let highestTopY = tops.max()!
        
        let avgTopY = Double(tops.reduce(0, +)) / Double(tops.count)
        let avgBottomY = Double(bottoms.reduce(0, +)) / Double(bottoms.count)
        
        func median(of values: [Int]) -> Double {
            let n = values.count
            if n % 2 == 0 {
                return Double(values[n/2 - 1] + values[n/2]) / 2.0
            } else {
                return Double(values[n/2])
            }
        }
        
        let medianTopY = median(of: tops)
        let medianBottomY = median(of: bottoms)
        
        // Detect outliers using "1.5 * IQR rule"
        func outlierCount(for values: [Int]) -> Int {
            let n = values.count
            guard n >= 4 else { return 0 }
            
            let q1 = Double(values[n / 4])
            let q3 = Double(values[3 * n / 4])
            let iqr = q3 - q1
            let lowerBound = q1 - 1.5 * iqr
            let upperBound = q3 + 1.5 * iqr
            
            return values.filter { Double($0) < lowerBound || Double($0) > upperBound }.count
        }
        
        let outliers = outlierCount(for: tops) + outlierCount(for: bottoms)
        
        return HorizonStats(
            lowestBottomY: lowestBottomY,
            highestTopY: highestTopY,
            avgTopY: avgTopY,
            avgBottomY: avgBottomY,
            medianTopY: medianTopY,
            medianBottomY: medianBottomY,
            outlierCount: outliers
        )
    }
}


extension PixelatedImage {
    // should get rid of all but the ground, designed to run after Otsu classification and
    // connected component filtering.  Returns HorizonMask, including the Y bounds of the horizon
    public var groundOnly: HorizonMask? {
        guard let nsImg = self.nsImage else { return nil }
        let horizonResult = PixelatedImageBridge.groundOnly(from: nsImg)
        if let image = horizonResult.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let pixelatedImage = PixelatedImage(image)
        {
            return HorizonMask(
              image: pixelatedImage,
              horizonTopY: horizonResult.horizonTopY,
              horizonBottomY: horizonResult.horizonBottomY
            )
        } else {
            return nil
        }
    }
}


extension PixelatedImage {
    // horizon detection logic
    // tries to compute a binary ground mask, where the ground is zero (black) 
    public func horizonMask(at frameIndex: Int,
                            bottomPercentage: Double = 50,
                            stripWidth: Int = 400) async -> HorizonMask? {
        /*
         horizon detection alg:
         * split frame image into bottom half, discarding top half
         * split bottom half into 1000 pixel wide segments
         * apply otsu binary classifier to each of them
         * apply connected component filtering (use opencv2?)
         * apply ground only filtering
         * end up with binary set of earth or sky pixels
         * re-combine them all into one
         * assume the top half of the image is sky

         */        

        // determine the new height 
        let halfHeight = Int(Double(self.height)*bottomPercentage/100)

        // crop out the top part
        let bottomCrop = self.bottomCrop(by: halfHeight)

        // split into an array of smaller images
        let matrix = bottomCrop.splitIntoMatrix(maxWidth: stripWidth,
                                                maxHeight: bottomCrop.height,
                                                overlapPercent: 0)

        // updated elements go here
        var newElements: [ImageMatrixElement] = []

        Log.d("frame \(frameIndex) has \(newElements.count) matrix elements for horizon removal")


        return await withTaskGroup(of: Optional<ImageMatrixElement>.self) { taskGroup in
            for (index, element) in matrix.enumerated() {
                taskGroup.addTask {
                    // calculate Otsu classification for this image element
                    let otsu = element.image.binaryOtsuImage

                    // apply connect component filtering and ground only logic
                    if let filtered = otsu.connectedComponentFiltered(keepLargest: 2),
                       let groundOnly = filtered.groundOnly
                    {
                        // deal with groundOnly horizonTopY horizonBottomY
                        return ImageMatrixElement(
                          x: element.x,
                          y: element.y,
                          image: groundOnly.image,
                          horizonTopY: groundOnly.horizonTopY,
                          horizonBottomY: groundOnly.horizonBottomY
                        )
                    } else {
                        return nil
                    }
                }
            }
            for await result in taskGroup {
                if let result { newElements.append(result) }
            }
            
            if newElements.count == matrix.count {
                let (horizonTopY, horizonBottomY) = newElements.combinedHorizonExtents()

                let image = PixelatedImage(from: newElements)
                    .addSky(height: halfHeight)
                
                return HorizonMask(
                  image: image,
                  horizonTopY: horizonTopY ?? 0,
                  horizonBottomY: horizonBottomY ?? image.height
                )
            } else {
                return nil
            }
        }
    }
}

extension PixelatedImage {
    // digs into opencv2 to remove a lot of connected components 
    public func connectedComponentFiltered(keepLargest n: Int = 2) -> PixelatedImage? {
        guard let nsImg = self.nsImage else { return nil }
        let filtered = PixelatedImageBridge.filterConnectedComponents(nsImg, keepLargest: n)
        return PixelatedImage(filtered.cgImage(forProposedRect: nil, context: nil, hints: nil)!)
    }
}
