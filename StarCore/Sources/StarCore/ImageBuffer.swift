import Foundation
import logging
import kht_bridge

// allows construction of an accessable buffer that can then be converted into
// a PixelatedImage with a cv::Mat holding the buffer
/*

 Usage:

 let buffer = Buffer<UInt16>(width: 200, height: 200, components: 3)
 if let image = buffer.image {
     // image is a PixelatedImage pointing at buffer
     // with a cv::Mat (image.mat) pointing to the same buffer 
 }
 
 */

public struct ImageBuffer<Element: FixedWidthInteger>: @unchecked Sendable {
    private let holder: BufferHolder
    
    /// Number of elements (not bytes)
    let count: Int

    let width: Int
    let height: Int
    let components: Int

    init(pointer: UnsafeBufferPointer<Element>,
         width: Int,
         height: Int,
         components: Int = 1)
    {
        self.width = width
        self.height = height
        Log.d("width \(width) height \(height)")
        self.components = components
        self.count = width * height * components
        self.holder = BufferHolder(
          copiedBuffer: pointer.baseAddress,
          width: UInt(width),
          height: UInt(height),
          components: components,
          bitsPerComponent: UInt(MemoryLayout<Element>.stride)*8
        )
    }
    
    init(width: Int,
         height: Int,
         components: Int = 1)
    {
        self.width = width
        self.height = height
        Log.d("width \(width) height \(height)")
        self.components = components
        self.count = width * height * components
        self.holder = BufferHolder(
          width: UInt(width),
          height: UInt(height),
          components: components,
          bitsPerComponent: UInt(MemoryLayout<Element>.stride)*8
        )
    }
    
    subscript(index: Int) -> Element {
        get {
            precondition(index >= 0 && index < count, "Index out of range")
            return holder.buffer!.assumingMemoryBound(to: Element.self)[index]
        }
        set {
            precondition(index >= 0 && index < count, "Index out of range")
            holder.buffer!.assumingMemoryBound(to: Element.self)[index] = newValue
        }
    }
    
    /// Raw pointer if needed
    var pointer: UnsafeMutablePointer<Element> {
        return holder.buffer!.assumingMemoryBound(to: Element.self)
    }

    var image: PixelatedImage? {
        if let mat = holder.mat() {
            Log.d("FUCKING mat \(mat)")
            if Element.self == UInt8.self,
               let buffer = self as? ImageBuffer<UInt8>
            {
                if let ret = PixelatedImage(mat: mat, eightBitBuffer: buffer) {
                    return ret
                } else {
                    Log.w("couldn't create 8 bit image")
                }
            } else if Element.self == UInt16.self,
                      let buffer = self as? ImageBuffer<UInt16>
            {
                if let ret = PixelatedImage(mat: mat, sixteenBitBuffer: buffer) {
                    return ret
                } else {
                    Log.w("couldn't create 16 bit image")
                }
            } else if Element.self == Int32.self,
                      let buffer = self as? ImageBuffer<Int32>
            {
                if let ret = PixelatedImage(mat: mat, thirtyTwoBitBuffer: buffer) {
                    return ret
                } else {
                    Log.w("couldn't create 32 bit image")
                }
            }
        }
        return nil
    }
}

