// MatWrapper.swift — Swift wrapper matching the old ObjC MatWrapper API
import Foundation
import StarCpp

public final class MatWrapper: @unchecked Sendable {
    public let ref: MatWrapperRef

    // Take ownership of an existing C handle (does NOT retain/clone)
    public init(ref: MatWrapperRef) {
        self.ref = ref
    }

    deinit {
        mat_wrapper_release(ref)
    }

    // MARK: - Factory methods

    public static func load(fromFilename filename: String) -> MatWrapper? {
        guard let r = mat_wrapper_load(filename) else { return nil }
        return MatWrapper(ref: r)
    }

    public init(width: Int, height: Int, cvType: Int32, bytesPerRow: Int, data: UnsafeMutableRawPointer, takeOwnership: Bool) {
        self.ref = mat_wrapper_create(Int64(width), Int64(height), cvType,
                                       bytesPerRow, data, takeOwnership)
    }

    // MARK: - Properties

    public var rows: Int { Int(mat_wrapper_rows(ref)) }
    public var cols: Int { Int(mat_wrapper_cols(ref)) }
    public var channels: Int { Int(mat_wrapper_channels(ref)) }
    public var type: Int32 { Int32(mat_wrapper_type(ref)) }
    public var step: Int { Int(mat_wrapper_step(ref)) }
    public var dataLength: Int { Int(mat_wrapper_data_length(ref)) }
    public var lengthInBytes: Int { Int(mat_wrapper_length_in_bytes(ref)) }
    public var isEmpty: Bool { mat_wrapper_is_empty(ref) }
    public var dataPtr: UnsafeRawPointer? { mat_wrapper_data_ptr(ref) }
    public var bitsPerPixel: Int { Int(mat_wrapper_bits_per_pixel(ref)) }
    public var bitsPerComponent: Int { Int(mat_wrapper_bits_per_component(ref)) }
    public var ownsData: Bool { mat_wrapper_owns_data(ref) }

    // MARK: - Memory tracking

    public static var totalBytes: UInt64 { mat_wrapper_total_bytes() }
    public static var totalInstances: UInt64 { mat_wrapper_total_instances() }

    // MARK: - Operations

    public func clone() -> MatWrapper {
        MatWrapper(ref: mat_wrapper_clone(ref))
    }

    /// Write to `filename`. Returns whether the file is now on disk.
    ///
    /// `@discardableResult` because plenty of callers write debug and preview images where a
    /// failure genuinely does not matter — but the ones writing the user's output frames must
    /// check it, or a full disk produces a run that reports success with frames missing.
    @discardableResult
    public func write(to filename: String) -> Bool {
        mat_wrapper_write_to(ref, filename)
    }

    @discardableResult
    public func saveJpeg(quality: UInt32, filename: String) -> Bool {
        mat_wrapper_save_jpeg(ref, quality, filename)
    }

    public func bottomCrop(_ n: Int32) -> MatWrapper? {
        guard let r = mat_wrapper_bottom_crop(ref, n) else { return nil }
        return MatWrapper(ref: r)
    }

    public func upScale(to width: UInt, height: UInt) -> MatWrapper? {
        guard let r = mat_wrapper_up_scale(ref, UInt64(width), UInt64(height)) else { return nil }
        return MatWrapper(ref: r)
    }

    public func downScale(to width: UInt, height: UInt) -> MatWrapper? {
        guard let r = mat_wrapper_down_scale(ref, UInt64(width), UInt64(height)) else { return nil }
        return MatWrapper(ref: r)
    }

    public func ensureEightBit() -> MatWrapper {
        MatWrapper(ref: mat_wrapper_ensure_eight_bit(ref))
    }

    /// Convert to single-channel 8-bit grayscale (CV_8UC1).
    /// This is required for images used as horizon masks.
    public func ensureGray8U() -> MatWrapper {
        MatWrapper(ref: mat_wrapper_ensure_gray_8u(ref))
    }

    public func addWhiteRows(onTop rows: Int32) -> MatWrapper {
        MatWrapper(ref: mat_wrapper_add_white_rows_on_top(ref, rows))
    }

    public var is16Bits: Bool { mat_wrapper_is_16_bits(ref) }
    public var is8Bits: Bool { mat_wrapper_is_8_bits(ref) }

    public func ensure16Bits() -> MatWrapper {
        MatWrapper(ref: mat_wrapper_ensure_16_bits(ref))
    }

    public func ensure8Bits() -> MatWrapper {
        MatWrapper(ref: mat_wrapper_ensure_8_bits(ref))
    }

    public func atDouble(row: Int32, col: Int32) -> Double {
        mat_wrapper_at_double(ref, row, col)
    }

    // MARK: - Homography

    public var homographyValues: [Double]? {
        var out = [Double](repeating: 0, count: 9)
        if mat_wrapper_get_homography_values(ref, &out) {
            return out
        }
        return nil
    }

    public static func fromHomographyValues(_ values: [Double]) -> MatWrapper {
        precondition(values.count == 9)
        return MatWrapper(ref: mat_wrapper_from_homography_values(values))
    }

    /// Convenience init matching old ObjC `initWithHomographyValues:` pattern
    public convenience init(homographyValues: [Double]) {
        precondition(homographyValues.count == 9)
        self.init(ref: mat_wrapper_from_homography_values(homographyValues))
    }

    // MARK: - Split/Combine

    public func split(tileWidth: Int32, tileHeight: Int32, overlapPercent: Double) -> [MatTileElement] {
        var elemsPtr: UnsafeMutablePointer<CImageMatrixElement>?
        let count = mat_wrapper_split(ref, tileWidth, tileHeight, overlapPercent, &elemsPtr)
        guard count > 0, let elems = elemsPtr else { return [] }

        var result: [MatTileElement] = []
        for i in 0..<Int(count) {
            let e = elems[i]
            result.append(MatTileElement(x: Int(e.x), y: Int(e.y),
                                          width: Int(e.width), height: Int(e.height),
                                          image: MatWrapper(ref: e.image)))
        }
        // Free the C array but NOT the images (we took ownership above)
        free(elems)
        return result
    }

    public static func combine(from elements: [MatTileElement]) -> MatWrapper? {
        let cElems = elements.map { e in
            CImageMatrixElement(x: Int32(e.x), y: Int32(e.y),
                                width: Int32(e.width), height: Int32(e.height),
                                image: e.image.ref)
        }
        guard let r = cElems.withUnsafeBufferPointer({ buf in
            mat_wrapper_combine(buf.baseAddress, Int32(buf.count))
        }) else { return nil }
        return MatWrapper(ref: r)
    }

    // MARK: - CV type helper

    public static func cvType(forBitsPerComponent bits: Int32, componentsPerPixel components: Int32) -> Int32 {
        Int32(mat_wrapper_cv_type_for(bits, components))
    }
}

// Swift-level tile element returned by MatWrapper.split / used by MatWrapper.combine
public struct MatTileElement: Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let image: MatWrapper

    public init(x: Int, y: Int, width: Int, height: Int, image: MatWrapper) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.image = image
    }
}
