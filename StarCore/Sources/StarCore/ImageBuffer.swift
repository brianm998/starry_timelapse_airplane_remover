import Foundation
import logging
import StarCpp

// allows construction of an accessable buffer that can then be converted into
// a PixelatedImage with a cv::Mat holding the buffer
/*

 Usage:

 let buffer = ImageBuffer<UInt16>(width: 200, height: 200, components: 3)
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

    public init(
      pointer: UnsafeBufferPointer<Element>,
      width: Int,
      height: Int,
      components: Int = 1
    ) {
        self.width = width
        self.height = height
        //Log.d("width \(width) height \(height)")
        self.components = components
        self.count = width * height * components
        self.holder = BufferHolder(
          copyingBuffer: UnsafeRawPointer(pointer.baseAddress!),
          width: UInt64(width),
          height: UInt64(height),
          components: Int64(components),
          bitsPerComponent: UInt64(MemoryLayout<Element>.stride)*8
        )
    }
    
    public init(
      width: Int,
      height: Int,
      components: Int = 1
    ) {
        self.width = width
        self.height = height
        //Log.d("width \(width) height \(height)")
        self.components = components
        self.count = width * height * components
        self.holder = BufferHolder(
          width: UInt64(width),
          height: UInt64(height),
          components: Int64(components),
          bitsPerComponent: UInt64(MemoryLayout<Element>.stride)*8
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
    public var pointer: UnsafeMutablePointer<Element> {
        return holder.buffer!.assumingMemoryBound(to: Element.self)
    }

    public var image: PixelatedImage? {
        let mat = holder.toMat()
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
        } else {
            Log.w("cannot create image from unsupported element type \(Element.self)")
        }
        return nil
    }
}

