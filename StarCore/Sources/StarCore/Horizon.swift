import Foundation
import CoreGraphics
import KHTSwift
import logging
import Cocoa
import kht_bridge

// this file has logic for horizon detection and analysis

public struct HorizonMask: Sendable {
    public let image: PixelatedImage
    public let horizonTopY: Int // this is the bottom 
    public let horizonBottomY: Int // this is the top :( swap these names

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
    public let lowestBottomY: Int // this is the top of the horizon
    public let highestTopY: Int // this is the bottom of the horizon
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
    public func groundOnly() throws -> PixelatedImage {
        let matWrapper = self.mat
        if let ret = PixelatedImage(
             mat: PixelatedImageBridge.groundOnly(from: matWrapper)
           )
        {
            return ret
        }
        throw "cannot get ground only from image without mat wrapper"
    }
}


extension PixelatedImage {
    // horizon detection logic
    // tries to compute a binary ground mask, where the ground is zero (black) 
    public func horizonMask(
      at frameIndex: Int,
      bottomPercentage: Double = 50,
      stripWidth: Int = 400
    ) async throws -> HorizonMask? {
        
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
        let bottomHeight = Int(Double(self.height)*bottomPercentage/100)

        // round up
        let topHeight = Int(Double(Double(self.height)*(100-bottomPercentage)/100)
                              .rounded(.down))

        // crop out the top part
        guard let bottomCrop = self.bottomCrop(by: bottomHeight) else {
            Log.w("Unable to bottom crop")
            return nil
        }

        // split into an array of smaller images
        let matrix = bottomCrop.splitIntoMatrix(
          maxWidth: stripWidth,
          maxHeight: bottomCrop.height,
          overlapPercent: 0
        )

        // updated elements go here
        var newElements: [ImageMatrixElement] = []

        Log.d("frame \(frameIndex) has \(newElements.count) matrix elements for horizon removal")


        return try await withThrowingTaskGroup(of: Optional<ImageMatrixElement>.self) { taskGroup in
            for (index, element) in matrix.enumerated() {
                taskGroup.addTask {
                    // calculate Otsu classification for this image element
                    if let otsu = element.image.binaryOtsuImage {
                        // apply connect component filtering and ground only logic
                        let filtered = try otsu.connectedComponentFiltered(keepLargest: 2)
                        
                        let groundOnly = try filtered.groundOnly()
                        
                        let bounds = try groundOnly.horizonBounds()

                        return ImageMatrixElement(
                          x: element.x,
                          y: element.y,
                          image: groundOnly,
                          horizonTopY: bounds.topY,
                          horizonBottomY: bounds.bottomY
                        )
                    } else {
                        Log.w("unable to create otsu horizon image")
                        return nil
                    }
                }
            }
            for try await result in taskGroup {
                if let result { newElements.append(result) }
            }
            
            if newElements.count == matrix.count {
                let (horizonTopY, horizonBottomY) = newElements.combinedHorizonExtents()

                if let no_sky_image = PixelatedImage(from: newElements),
                   let image = no_sky_image.addSky(height: topHeight)
                {
                    Log.d("image \(image.description)")
                    Log.d("no_sky_image \(no_sky_image.description)")
                    var _horizonTopY: Int = image.height
                    if let horizonTopY { _horizonTopY = horizonTopY + topHeight }

                    var _horizonBottomY: Int = 0
                    if let horizonBottomY { _horizonBottomY = horizonBottomY + topHeight }
                    
                    return HorizonMask(
                      image: image,
                      horizonTopY: _horizonTopY,
                      horizonBottomY: _horizonBottomY
                    )
                } else {
                    Log.w("unable to add sky to image")
                }
            } else {
                return nil
            }
            return nil
        }
    }
}

extension PixelatedImage {
    // digs into opencv2 to remove a lot of connected components 
    public func connectedComponentFiltered(keepLargest n: Int = 2) throws -> PixelatedImage {

        // first convert self to MatWrapper
        let baseMat = self.mat 
        let filtered = PixelatedImageBridge.filterConnectedComponents(baseMat, keepLargest: n) 
        // then convert back in to PixelatedImage
        if let ret = PixelatedImage(mat: filtered) { return ret }

        throw "unable to connected component filter without a mat wrapper"
    }
}

extension PixelatedImage {
    /// Returns a new image with `height` rows of white pixels
    /// added to the top of the current image.
    func addSky(height: Int) -> PixelatedImage? {
        guard height > 0 else { return self }

        return PixelatedImage(mat: self.mat.addWhiteRows(onTop: Int32(height)))
    }
}

extension Array where Element == ImageMatrixElement {
    /// Returns the combined horizon extents across all elements in the array
    func combinedHorizonExtents() -> (horizonTopY: Int?, horizonBottomY: Int?) {
        // Collect only non-nil values
        let allHighestBlackY = self.compactMap { $0.horizonTopY }
        let allLowestWhiteY  = self.compactMap { $0.horizonBottomY }
        Log.d("XXX allHighestBlackY \(allHighestBlackY)")
        Log.d("XXX allLowestWhiteY \(allLowestWhiteY)")
        
        // Highest horizon = largest horizonTopY
        let globalHighestBlackY = allHighestBlackY.min()
        
        // Lowest horizon = smallest horizonBottomY
        let globalLowestWhiteY = allLowestWhiteY.max()

        //Log.d("XXX (\(globalHighestBlackY), \(globalLowestWhiteY))")
        
        return (globalHighestBlackY, globalLowestWhiteY)
    }
}


