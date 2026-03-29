// BufferHolder.swift — Swift wrapper for pixel buffer management
import kht_bridge

public final class BufferHolder: @unchecked Sendable {
    public let ref: BufferHolderRef

    public init(ref: BufferHolderRef) {
        self.ref = ref
    }

    public init(width: UInt64, height: UInt64, components: Int64, bitsPerComponent: UInt64) {
        self.ref = buffer_holder_create(width, height, components, bitsPerComponent)
    }

    public init(copyingBuffer buffer: UnsafeRawPointer, width: UInt64, height: UInt64,
                components: Int64, bitsPerComponent: UInt64) {
        self.ref = buffer_holder_create_copy(buffer, width, height, components, bitsPerComponent)
    }

    deinit {
        buffer_holder_release(ref)
    }

    public var buffer: UnsafeMutableRawPointer? { buffer_holder_buffer(ref) }
    public var length: UInt64 { buffer_holder_length(ref) }
    public var width: UInt64 { buffer_holder_width(ref) }
    public var height: UInt64 { buffer_holder_height(ref) }
    public var components: UInt64 { buffer_holder_components(ref) }
    public var bitsPerComponent: UInt64 { buffer_holder_bits_per_component(ref) }

    public var asUInt8: UnsafeMutablePointer<UInt8>? { buffer_holder_as_uint8(ref) }
    public var asUInt16: UnsafeMutablePointer<UInt16>? { buffer_holder_as_uint16(ref) }
    public var asUInt32: UnsafeMutablePointer<UInt32>? { buffer_holder_as_uint32(ref) }

    public func toMat() -> MatWrapper {
        MatWrapper(ref: buffer_holder_to_mat(ref))
    }
}
