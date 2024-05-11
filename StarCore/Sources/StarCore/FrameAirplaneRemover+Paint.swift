import Foundation
import CoreGraphics
import logging
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
    internal func paintOverAirplanes(toData data: inout [UInt16],
                                     otherFrame: PixelatedImage) async throws
    {
        Log.i("frame \(frameIndex) painting airplane outlier groups")

        // paint over every outlier in the paint list with pixels from the adjecent frames
        guard let outlierGroups = outlierGroups else {
            Log.e("cannot paint without outlier groups")
            return
        }

        guard outlierGroups.members.count > 0 else {
            Log.v("no outliers, not painting")
            return
        }

        guard let image = await imageAccessor.load(type: .original, atSize: .original)
        else { throw "couldn't load image" }
        
        // the alpha level to apply to each pixel in the image
        // indexed by y*width+x
        // this is esentially a layer mask for the frame, 
        // with the adjusted neighbor frame underneath
        var alphaLevels = [Double](repeating: 0, count: width*height)

        // first go through the outlier groups and determine what alpha
        // level to apply to each pixel in this frame.
        // alpha zero means no painting, keep original pixel
        // alpha one means overwrite original pixel entierly with data from other frame

        // the alpha mask that we will convolve across all paintable pixels
        let paintMask = self.paintMask
        let paintMaskIntRadius = Int(paintMask.radius)
        
        for (_, group) in outlierGroups.members {
            if let reason = group.shouldPaint {
                if reason.willPaint {
                    Log.d("frame \(frameIndex) painting over group \(group) for reason \(reason)")
                    for x in 0..<group.bounds.width {
                        for y in 0..<group.bounds.height {
                            if group.pixels[y*group.bounds.width + x] > 0 {
                                // center of paint mask in frame coords
                                let maskCenterX = x + group.bounds.min.x
                                let maskCenterY = y + group.bounds.min.y

                                // start in frame coords
                                let maskStartX = maskCenterX - paintMaskIntRadius
                                let maskStartY = maskCenterY - paintMaskIntRadius

                                for maskX in 0..<paintMask.size {
                                    for maskY in 0..<paintMask.size {
                                        let frameX = maskX + maskStartX
                                        let frameY = maskY + maskStartY

                                        if frameX >= 0,
                                           frameX < width,
                                           frameY >= 0,
                                           frameY < height
                                        {
                                            let frameIndex = frameY*width+frameX
                                            let maskIndex = maskY*paintMask.size+maskX
                                        
                                            let frameAlpha = alphaLevels[frameIndex]
                                            let maskAlpha = paintMask.pixels[maskIndex]
                                            if maskAlpha > frameAlpha {
                                                alphaLevels[frameIndex] = maskAlpha
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    //Log.v("frame \(frameIndex) NOT painting over group \(group) for reason \(reason)")
                }
            }
        }

        if config.writeOutlierGroupFiles { // XXX this config value is very much overloaded
            var paintMaskImageData = [UInt8](repeating: 0, count: width*height)

            for x in 0 ..< width {
                for y in 0 ..< height {
                    let index = y*width+x
                    let alpha = alphaLevels[index]
                    if alpha > 0 {
                        var value = Int(alpha*Double(0xFF))
                        if value > 0xFF { value = 0xFF }
                        paintMaskImageData[index] = UInt8(value)
                    }
                }
            }

            let paintMaskImage = PixelatedImage(width: width, height: height,
                                                grayscale8BitImageData: paintMaskImageData)
            let (_,_) = await (try imageAccessor.save(paintMaskImage, as: .paintMask,
                                                      atSize: .original, overwrite: true),
                               try imageAccessor.save(paintMaskImage, as: .paintMask,
                                                      atSize: .preview, overwrite: true))
        }
        
        self.state = .painting2
        
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
                        toData data: inout [UInt16],
                        image: PixelatedImage,
                        otherFrame: PixelatedImage)
    {
        var paintPixel = otherFrame.readPixel(atX: x, andY: y)

        if otherFrame.componentsPerPixel == 4, // has alpha channel
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

        // the is the place in the image data to write to
        let offset = (Int(y) * bytesPerRow/2) + (Int(x) * bytesPerPixel/2)

        // actually paint over that airplane like thing in the image data
        if self.bytesPerPixel == 2 {
            data.replaceSubrange(offset ..< offset+self.bytesPerPixel/2,
                              with: [paintPixel.red])
        } else if self.bytesPerPixel == 6 {
            data.replaceSubrange(offset ..< offset+self.bytesPerPixel/2,
                              with: [paintPixel.red, paintPixel.green, paintPixel.blue])
        } else if self.bytesPerPixel == 8 {
            data.replaceSubrange(offset ..< offset+self.bytesPerPixel/2,
                               with: [paintPixel.red,
                                      paintPixel.green,
                                      paintPixel.blue,
                                      paintPixel.alpha])
        }
    }


    // paint over a selected outlier pixel with data from pixels from adjecent frames
    internal func paint(x: Int, y: Int,
                        alpha: Double,
                        toData data: inout [UInt16],
                        image: PixelatedImage,
                        paintPixel: Pixel)
    {
        var paintPixel = paintPixel
        if alpha < 1 {
            let op = image.readPixel(atX: x, andY: y)
            paintPixel = Pixel(merging: paintPixel, with: op, atAlpha: alpha)
        }

        // the is the place in the image data to write to
        let offset = (Int(y) * bytesPerRow/2) + (Int(x) * bytesPerPixel/2)

        // actually paint over that airplane like thing in the image data
        if self.bytesPerPixel == 2 {
            data.replaceSubrange(offset ..< offset+self.bytesPerPixel/2,
                                 with: [paintPixel.red])
        } else if self.bytesPerPixel == 6 {
            data.replaceSubrange(offset ..< offset+self.bytesPerPixel/2,
                                 with: [paintPixel.red, paintPixel.green, paintPixel.blue])
        } else if self.bytesPerPixel == 8 {
            data.replaceSubrange(offset ..< offset+self.bytesPerPixel/2,
                                 with: [paintPixel.red,
                                       paintPixel.green,
                                       paintPixel.blue,
                                       paintPixel.alpha])
        }
    }
}

