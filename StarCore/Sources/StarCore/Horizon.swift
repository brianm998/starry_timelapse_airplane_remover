import Foundation
import StarCpp
import logging

// this file has logic for horizon detection and analysis

public struct HorizonMask: Sendable {
    public let image: PixelatedImage
    public let horizonTopY: Int // this is the bottom 
    public let horizonBottomY: Int // this is the top :( swap these names

    public init?(_ image: PixelatedImage) {
        // Always normalise to CV_8UC1 — all downstream OpenCV operations require it
        let mask = image.asHorizonMask ?? image
        self.image = mask
        guard let bounds = mask.horizonBounds() else { return nil }
        self.horizonTopY = bounds.topY
        self.horizonBottomY = bounds.bottomY
    }

    public init(
      image: PixelatedImage,
      horizonTopY: Int, // this is the bottom
      horizonBottomY: Int // this is the top :( swap these names
    ) {
        // Always normalise to CV_8UC1 — all downstream OpenCV operations require it
        self.image = image.asHorizonMask ?? image
        self.horizonTopY = horizonTopY
        self.horizonBottomY = horizonBottomY
    }

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
        guard let resultMat = PixelatedImageBridge.groundOnly(from: matWrapper) else {
            throw "groundOnly returned nil"
        }
        if let ret = PixelatedImage(mat: resultMat) {
            return ret
        }
        throw "cannot get ground only from image without mat wrapper"
    }

    public func skyOnly() throws -> PixelatedImage {
        let matWrapper = self.mat
        guard let resultMat = PixelatedImageBridge.skyOnly(from: matWrapper) else {
            throw "skyOnly returned nil"
        }
        if let ret = PixelatedImage(mat: resultMat) {
            return ret
        }
        throw "cannot get sky only from image without mat wrapper"
    }

    public func growDarkRegions(by radius: Int32) throws -> PixelatedImage {
        let matWrapper = self.mat
        guard let resultMat = PixelatedImageBridge.growDarkRegions(matWrapper, by: radius) else {
            throw "growDarkRegions returned nil"
        }
        if let ret = PixelatedImage(mat: resultMat) {
            return ret
        }
        throw "cannot grow dark regions"
    }

    public func shrinkDarkRegions(by radius: Int32) throws -> PixelatedImage {
        let matWrapper = self.mat
        guard let resultMat = PixelatedImageBridge.shrinkDarkRegions(matWrapper, by: radius) else {
            throw "shrinkDarkRegions returned nil"
        }
        if let ret = PixelatedImage(mat: resultMat) {
            return ret
        }
        throw "cannot shrink dark regions"
    }
}


extension PixelatedImage {
    // horizon detection logic
    // tries to compute a binary ground mask, where the ground is zero (black) 
    public func horizonMask(
      at frameIndex: Int,
      bottomPercentage: Double = 50,
      useCannyEdgeDetection: Bool = true,
      cannyMinThreshold: Double = 80,
      cannyMaxThreshold: Double = 250,
      useL2Gradient: Bool = true
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

         * run canny edge detection
         * combine that with otsu results
         * run ground only
         * add small padding
         * run sky only
         * remove small padding
         */        

        // determine the size of the sky to remove
        let topHeight = Int(Double(self.height)*bottomPercentage/100)

        Log.d("horizonMask: image=\(self.width)×\(self.height) crop=\(String(format:"%.1f",bottomPercentage))% topHeight=\(topHeight) cropHeight=\(self.height-topHeight)")

        // crop out the top part
        guard let bottomCrop = self.bottomCrop(by: topHeight) else {
            Log.w("Unable to bottom crop")
            return nil
        }
        
        // split into an array of smaller images
//        let matrix = bottomCrop.splitIntoMatrix(


        // updated elements go here
        Log.d("horizonMask: from \(bottomCrop.width)×\(bottomCrop.height) cropped region")

        var groundOnly: PixelatedImage? = nil

        // calculate Otsu classification for this image element
        if let otsu = bottomCrop.binaryOtsuImage {
            // apply connect component filtering and ground only logic
            let filtered = try otsu.connectedComponentFiltered(keepLargest: 2)
            
            groundOnly = try filtered.groundOnly()

        } else {
            Log.w("unable to create otsu horizon image")
            return nil
        }

            
        if let groundOnly,
           let image = groundOnly.addSky(height: topHeight)
        {
            var combined = image

            if useCannyEdgeDetection, false {
                // find edges 
                let edges = try image.cannyEdgeDetect( 
                  minThreshold: cannyMinThreshold,
                  maxThreshold: cannyMaxThreshold,
                  useL2Gradient: useL2Gradient
                )
                  .bitwiseNot()
                  .growDarkRegions(by: 1)

                // combine otsu and canny edge detection into one image

                combined = try image
                  .bitwiseAnd(with: edges)
            }
            
            // expand the dark areas by one pixel
            //let grown = try groundOnly.growDarkRegions(by: 1)

            // get rid of any bright compoments that don't touch the top
            let filtered = try combined.skyOnly()

            // shrink back down
            let shrunk = try filtered.shrinkDarkRegions(by: 1)

            // get rid of any dark components that don't touch the ground
            let groundOnly = try shrunk.groundOnly()
            
            let _horizonTopY = shrunk.height

            let _horizonBottomY = 0
            
            let horizonYValues = HorizonScoring.extractHorizonYPerColumn(from: groundOnly)
            let definedYs = horizonYValues.compactMap { $0 }
            if definedYs.isEmpty {
                Log.i("horizonMask: result has no defined horizon columns (all sky or all ground)")
            } else {
                let minY = definedYs.min()!
                let maxY = definedYs.max()!
                let avgY = Double(definedYs.reduce(0,+)) / Double(definedYs.count)
                Log.d("horizonMask: result horizonY min=\(minY) max=\(maxY) avg=\(String(format:"%.1f",avgY)) defined=\(definedYs.count)/\(horizonYValues.count) cols")
            }
            
            return HorizonMask(
              image: groundOnly,
              horizonTopY: _horizonTopY, // XXX these are not right anymore :(
              horizonBottomY: _horizonBottomY
            )
        } else {
            Log.w("unable to add sky to image")
        }
        return nil
    }
}


extension PixelatedImage {
    /// Dynamic programming horizon detection.
    /// Finds the horizon as an optimal left-to-right path through the image
    /// that follows strong horizontal edges (Sobel vertical gradient + Canny edges).
    ///
    /// Unlike the Otsu-based `horizonMask()`, this approach does NOT classify
    /// pixels by brightness. Instead, it directly traces the strongest horizontal
    /// boundary in the image, making it robust to bright ground (snow, reflections)
    /// that would confuse Otsu thresholding.
    ///
    /// The search band is defined by `searchTopFraction` and `searchBottomFraction`
    /// (both as fractions of image height, 0.0–1.0).  These are independent of
    /// the Otsu crop amount so the DP can find the real horizon even when the
    /// Otsu crop parameter is set below the true horizon.
    ///
    /// Returns a `HorizonMask` with a binary image: white = sky, black = ground.
    public func dpHorizonMask(
      at frameIndex: Int,
      searchTopFraction: Double = 0.10,
      searchBottomFraction: Double = 0.90,
      cannyMinThreshold: Double = 50,
      cannyMaxThreshold: Double = 120,
      useL2Gradient: Bool = true,
      smoothnessLambda: Double = 2.0,
      sobelWeight: Double = 0.6,
      cannyWeight: Double = 0.4
    ) async throws -> HorizonMask? {
        let top    = max(0.0, min(1.0, searchTopFraction))
        let bottom = max(top, min(1.0, searchBottomFraction))

        Log.d("frame \(frameIndex) dpHorizonMask: " +
              "searchTop=\(String(format: "%.2f", top)), " +
              "searchBottom=\(String(format: "%.2f", bottom)), " +
              "lambda=\(smoothnessLambda), sobelW=\(sobelWeight), cannyW=\(cannyWeight)")

        let dpMask = try self.dpHorizonDetect(
          cannyMinThreshold: cannyMinThreshold,
          cannyMaxThreshold: cannyMaxThreshold,
          useL2Gradient: useL2Gradient,
          smoothnessLambda: smoothnessLambda,
          sobelWeight: sobelWeight,
          cannyWeight: cannyWeight,
          searchTopFraction: top,
          searchBottomFraction: bottom
        )

        return HorizonMask(dpMask)
    }
}

extension PixelatedImage {
    // digs into opencv2 to remove a lot of connected components
    public func connectedComponentFiltered(keepLargest n: Int = 2) throws -> PixelatedImage {

        // first convert self to MatWrapper
        let baseMat = self.mat
        guard let filtered = PixelatedImageBridge.filterConnectedComponents(baseMat, keepLargest: n) else {
            throw "filterConnectedComponents returned nil"
        }
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

    /// Build a binary CV_8UC1 horizon mask from per-column Y values.
    ///
    /// White (255) = sky, black (0) = ground.
    /// For column x, all rows >= columnY[x] are ground; rows above are sky.
    /// Columns with nil retain all-sky (255 throughout).
    static func fromHorizonColumnY(
      width: Int,
      height: Int,
      columnY: [Int?]
    ) -> PixelatedImage? {
        guard width > 0, height > 0, columnY.count == width else { return nil }
        var bytes = [UInt8](repeating: 255, count: width * height)
        for x in 0..<width {
            guard let y = columnY[x] else { continue }
            let clampedY = max(0, min(height, y))
            for row in clampedY..<height {
                bytes[row * width + x] = 0
            }
        }
        return bytes.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return nil }
            let mat = MatWrapper(
              width: width, height: height,
              cvType: 0, // CV_8UC1
              bytesPerRow: width,
              data: base,
              takeOwnership: false
            )
            return PixelatedImage(mat: mat.clone())
        }
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


