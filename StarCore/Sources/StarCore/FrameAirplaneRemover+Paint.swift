import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/*
 Logic about painting undesired elements from the image.

 Painting is done with data from a neighboring, aligned frame.

 Pixels to be painted over come from validated outlier groups,
 that logic is elsewhere.
 */
extension FrameAirplaneRemover {

    // actually paint over outlier groups that have been selected as airplane tracks
    internal func paintOverAirplanes(toData data: inout Data,
                                     otherFrame: PixelatedImage) async throws
    {
        Log.i("frame \(frameIndex) painting airplane outlier groups")

        let image = try await imageSequence.getImage(withName: imageSequence.filenames[frameIndex]).image()

        // paint over every outlier in the paint list with pixels from the adjecent frames
        guard let outlierGroups = outlierGroups else {
            Log.e("cannot paint without outlier groups")
            return
        }

        guard outlierGroups.members.count > 0 else {
            Log.v("no outliers, not painting")
            return
        }
        
        // the alpha level to apply to each pixel in the image
        // indexed by y*width+x
        var alphaLevels = [Double](repeating: 0, count: width*height)

        // first go through the outlier groups and determine what alpha
        // level to apply to each pixel in this frame.
        // alpha zero means no painting, keep original pixel
        // alpha one means overwrite original pixel entierly with data from other frame
        
        for (_, group) in outlierGroups.members {
            if let reason = group.shouldPaint {
                if reason.willPaint {
                    Log.d("frame \(frameIndex) painting over group \(group) for reason \(reason)")
                    //let x = index % width;
                    //let y = index / width;

                    //  somehow figure out how to do a border of X pixels

                    let intBorderFuzzAmount = Int(config.outlierGroupPaintBorderPixels)
                    var searchMinX = group.bounds.min.x - intBorderFuzzAmount 
                    var searchMaxX = group.bounds.max.x + intBorderFuzzAmount 
                    var searchMinY = group.bounds.min.y - intBorderFuzzAmount 
                    var searchMaxY = group.bounds.max.y + intBorderFuzzAmount 
                    if searchMinX < 0 { searchMinX = 0 }
                    if searchMinY < 0 { searchMinY = 0 }
                    if searchMaxX >= width { searchMaxX = width - 1 }
                    if searchMaxY >= height { searchMaxY = height - 1 }
                    
                    for x in searchMinX ... searchMaxX {
                        for y in searchMinY ... searchMaxY {

                            var pixelAmount: UInt16 = 0

                            if y >= group.bounds.min.y,
                               y <= group.bounds.max.y,
                               x >= group.bounds.min.x,
                               x <= group.bounds.max.x
                            {
                                let pixelIndex = (y - group.bounds.min.y)*group.bounds.width + (x - group.bounds.min.x)
                                pixelAmount = group.pixels[pixelIndex]
                            }
                            
                            if pixelAmount == 0 {
                                // here check distance to a non-zero pixel and maybe paint
                                var shouldPaint = false
                                var minDistance: Double = config.outlierGroupPaintBorderPixels

                                var fuzzXstart = x - intBorderFuzzAmount
                                var fuzzXend = x + intBorderFuzzAmount
                                if fuzzXstart < group.bounds.min.x {
                                    fuzzXstart = group.bounds.min.x
                                }
                                if fuzzXend > group.bounds.max.x {
                                    fuzzXend = group.bounds.max.x
                                }
                                
                                for fuzzX in fuzzXstart ... fuzzXend {
                                    var fuzzYstart = y - intBorderFuzzAmount
                                    var fuzzYend = y + intBorderFuzzAmount

                                    if fuzzYstart < group.bounds.min.y {
                                        fuzzYstart = group.bounds.min.y
                                    }
                                    if fuzzYend > group.bounds.max.y {
                                        fuzzYend = group.bounds.max.y
                                    }
                                    
                                    for fuzzY in fuzzYstart ... fuzzYend {
                                        let fuzzPixelIndex = (fuzzY - group.bounds.min.y)*group.bounds.width + (fuzzX - group.bounds.min.x)
                                        
                                        if fuzzPixelIndex < 0 ||
                                           fuzzPixelIndex >= group.pixels.count { continue }
                                        
                                        let fuzzAmount = group.pixels[fuzzPixelIndex]

                                        if fuzzAmount == 0 { continue }

                                        let distX = Double(abs(x - fuzzX))
                                        let distY = Double(abs(y - fuzzY))
                                        let hypoDist = sqrt(distX*distX+distY*distY)

                                        if hypoDist < minDistance {
                                            minDistance = hypoDist
                                            shouldPaint = true
                                        }
                                    }
                                }
                                if shouldPaint {
                                    var alpha: Double = 0
                                    if minDistance <= config.outlierGroupPaintBorderInnerWallPixels {
                                        alpha = 1
                                    } else {
                                        // how close are we to the inner wall of full opacity?
                                        let foo = minDistance - config.outlierGroupPaintBorderInnerWallPixels
                                        // the length in pixels of the fade window
                                        let bar = config.outlierGroupPaintBorderPixels - config.outlierGroupPaintBorderInnerWallPixels
                                        alpha = (bar-foo)/bar
                                    }
                                    if alpha > 0 {
                                        alphaLevels[y*width+x] += alpha
                                    }
                                }
                            } else {
                                // paint fully over the marked pixels
                                alphaLevels[y*width+x] += 1
                            }
                        }
                    }
                } else {
                    Log.v("frame \(frameIndex) NOT painting over group \(group) for reason \(reason)")
                }
            }
        }

        // then actually paint each non zero alpha pizel
        for x in 0 ..< width {
            for y in 0 ..< height {
                var alpha = alphaLevels[y*width+x]
                if alpha > 0 {
                    if alpha > 1 { alpha = 1 }

                    paint(x: x, y: y,
                         alpha: alpha,
                         toData: &data,
                         image: image,
                         otherFrame: otherFrame)

                    /*

                     // test paint the expected alpha levels as colors
                     
                                        var paintPixel = Pixel()
                                        paintPixel.blue = 0xFFFF
                                        paintPixel.green = UInt16(Double(0xFFFF)*alpha)
                                        paint(x: x, y: y, why: reason, alpha: alpha,
                                              toData: &data,
                                              image: image,
                                              paintPixel: paintPixel)
                     */

                }
            }
        }
    }

    // paint over a selected outlier pixel with data from pixels from adjecent frames
    internal func paint(x: Int, y: Int,
                      alpha: Double,
                      toData data: inout Data,
                      image: PixelatedImage,
                      otherFrame: PixelatedImage)
    {
        var paintPixel = otherFrame.readPixel(atX: x, andY: y)

        if otherFrame.pixelOffset == 4, // has alpha channel
           paintPixel.alpha != 0xFFFF   // alpha is not fully opaque
        {
            // ignore transparent pixels
            // don't paint over with them
            return
        }

        if alpha < 1 {
            let op = image.readPixel(atX: x, andY: y)
            paintPixel = Pixel(merging: paintPixel, with: op, atAlpha: alpha)
        }

        // this is the numeric value we need to write out to paint over the airplane
        var paintValue = paintPixel.value

        // the is the place in the image data to write to
        let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)

        // actually paint over that airplane like thing in the image data
        data.replaceSubrange(offset ..< offset+self.bytesPerPixel,
                             with: &paintValue, count: self.bytesPerPixel)
    }


    // paint over a selected outlier pixel with data from pixels from adjecent frames
    internal func paint(x: Int, y: Int,
                      alpha: Double,
                      toData data: inout Data,
                      image: PixelatedImage,
                      paintPixel: Pixel)
    {
        var paintPixel = paintPixel
        if alpha < 1 {
            let op = image.readPixel(atX: x, andY: y)
            paintPixel = Pixel(merging: paintPixel, with: op, atAlpha: alpha)
        }

        // this is the numeric value we need to write out to paint over the airplane
        var paintValue = paintPixel.value
        
        // the is the place in the image data to write to
        let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
        
        // actually paint over that airplane like thing in the image data
        data.replaceSubrange(offset ..< offset+self.bytesPerPixel,
                             with: &paintValue, count: self.bytesPerPixel)
        
    }
}
