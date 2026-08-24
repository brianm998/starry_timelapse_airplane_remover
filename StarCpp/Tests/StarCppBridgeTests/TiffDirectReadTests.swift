import XCTest
@testable import StarCppBridge

/// Coverage for the direct-read path in `mat_wrapper_load`.
///
/// Loading an uncompressed 16-bit TIFF through `cv::imread` costs about three times what
/// reading its strips into the Mat costs, and the merge does nothing but load originals —
/// 9 or 17 of them per frame — so `load(fromFilename:)` reads that one shape itself.
///
/// The risk this buys is entirely in the probe. `cv::imread` does not simply hand back the
/// bytes: depending on the tags it inverts MINISWHITE, expands a palette, converts YCbCr,
/// scales samples narrower than the destination, honours a rotated orientation, undoes a
/// predictor, and for 8-bit images goes through libtiff's RGBA reader and derives grayscale
/// with a weighted luma conversion. A direct read agrees with it for exactly one
/// combination of tags, and silently disagrees for the rest — so what needs pinning is not
/// that the fast path works, but that it declines everything else.
///
/// These tests build TIFF files byte by byte rather than going through a writer, because a
/// writer will not produce the files that have to be refused. Every field the probe looks
/// at gets a case that makes it say no.
final class TiffDirectReadTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TiffDirectReadTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - a TIFF built by hand

    /// Every tag the probe inspects, so a test can set exactly one of them wrong.
    /// `nil` means "leave the tag out", which is not the same as setting it to its default:
    /// the probe has to treat an absent Predictor as 1 and an absent RowsPerStrip as the
    /// whole image, and those are different code paths from seeing the tag.
    private struct Spec {
        var width = 17
        var height = 11
        var samplesPerPixel = 3
        var bitsPerSample = 16
        var compression = 1
        var photometric: Int? = nil        // nil: 1 for gray, 2 for RGB
        var planarConfig: Int? = 1
        var predictor: Int? = nil
        var fillOrder: Int? = nil
        var orientation: Int? = nil
        var sampleFormat: Int? = 1
        var rowsPerStrip: Int? = nil       // nil: one strip holding every row
        var tiled = false
        var extraSamples = false
        var bigEndian = false
        var bigTiffMagic = false
        /// Lay the strips out back to front in the file, so a reader that walks forward
        /// from the first offset instead of using the table gets the rows in the wrong
        /// order.
        var stripsReversedInFile = false
        /// Understate the last strip's byte count, which makes the file a lie.
        var truncateLastStripCount = false
    }

    private struct Field {
        let tag: Int
        let type: Int          // 3 = SHORT, 4 = LONG
        let values: [Int]
    }

    /// The pixel bytes a spec needs, deterministic per spec so a failure reproduces.
    private func pixelBytes(_ spec: Spec, seed: UInt64) -> [UInt8] {
        let count = spec.width * spec.height * spec.samplesPerPixel * (spec.bitsPerSample / 8)
        var state = seed | 1
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes.append(UInt8((state >> 33) & 0xff))
        }
        // plant exact 0x0000 and 0xffff samples, the two values a wrong conversion is
        // most likely to preserve by accident
        if spec.bitsPerSample == 16 {
            var i = 0
            while i + 1 < count {
                if i % 18 == 0 { bytes[i] = 0; bytes[i + 1] = 0 }
                if i % 26 == 0 { bytes[i] = 0xff; bytes[i + 1] = 0xff }
                i += 2
            }
        }
        return bytes
    }

    private func write(_ spec: Spec, named name: String, seed: UInt64 = 0x5eed) throws -> String {
        let little = !spec.bigEndian
        func put16(_ out: inout [UInt8], _ v: Int) {
            let v = UInt16(truncatingIfNeeded: v)
            if little { out.append(UInt8(v & 0xff)); out.append(UInt8(v >> 8)) }
            else { out.append(UInt8(v >> 8)); out.append(UInt8(v & 0xff)) }
        }
        func put32(_ out: inout [UInt8], _ v: Int) {
            let v = UInt32(truncatingIfNeeded: v)
            if little { for i in 0..<4 { out.append(UInt8((v >> (8 * i)) & 0xff)) } }
            else { for i in (0..<4).reversed() { out.append(UInt8((v >> (8 * i)) & 0xff)) } }
        }

        let spp = spec.samplesPerPixel
        let photometric = spec.photometric ?? (spp == 1 ? 1 : 2)
        let rows = spec.height
        let rowsPerStrip = spec.rowsPerStrip ?? rows
        let rowBytes = spec.width * spp * (spec.bitsPerSample / 8)
        let stripCount = (rows + rowsPerStrip - 1) / rowsPerStrip

        var fields: [Field] = [
            Field(tag: 256, type: 4, values: [spec.width]),
            Field(tag: 257, type: 4, values: [rows]),
            Field(tag: 258, type: 3, values: Array(repeating: spec.bitsPerSample, count: spp)),
            Field(tag: 259, type: 3, values: [spec.compression]),
            Field(tag: 262, type: 3, values: [photometric]),
            Field(tag: 277, type: 3, values: [spp]),
        ]
        if let v = spec.fillOrder    { fields.append(Field(tag: 266, type: 3, values: [v])) }
        if let v = spec.orientation  { fields.append(Field(tag: 274, type: 3, values: [v])) }
        if spec.rowsPerStrip != nil  { fields.append(Field(tag: 278, type: 4, values: [rowsPerStrip])) }
        if let v = spec.planarConfig { fields.append(Field(tag: 284, type: 3, values: [v])) }
        if let v = spec.predictor    { fields.append(Field(tag: 317, type: 3, values: [v])) }
        if spec.tiled {
            fields.append(Field(tag: 322, type: 4, values: [spec.width]))
            fields.append(Field(tag: 323, type: 4, values: [rowsPerStrip]))
        }
        if spec.extraSamples { fields.append(Field(tag: 338, type: 3, values: [0])) }
        if let v = spec.sampleFormat {
            fields.append(Field(tag: 339, type: 3, values: Array(repeating: v, count: spp)))
        }
        // placeholders, patched once the pixel offsets are known
        fields.append(Field(tag: 273, type: 4, values: Array(repeating: 0, count: stripCount)))
        fields.append(Field(tag: 279, type: 4, values: Array(repeating: 0, count: stripCount)))
        fields.sort { $0.tag < $1.tag }

        // header | IFD | out-of-line field values | pixels
        let ifdStart = 8
        let ifdBytes = 2 + fields.count * 12 + 4
        var tail: [UInt8] = []
        let tailStart = ifdStart + ifdBytes
        var inlineValue = [Int: Int]()      // tag -> value written in the entry
        var tailPosition = [Int: Int]()     // tag -> offset into tail
        for f in fields {
            let byteWidth = f.type == 3 ? 2 : 4
            if f.values.count * byteWidth <= 4 {
                var packed = 0
                for (i, v) in f.values.enumerated() {
                    packed |= (v & (byteWidth == 2 ? 0xffff : 0xffffffff)) << (8 * byteWidth * i)
                }
                inlineValue[f.tag] = packed
            } else {
                tailPosition[f.tag] = tail.count
                inlineValue[f.tag] = tailStart + tail.count
                for v in f.values {
                    if byteWidth == 2 { put16(&tail, v) } else { put32(&tail, v) }
                }
            }
        }
        if tail.count % 2 == 1 { tail.append(0) }
        let pixelStart = tailStart + tail.count

        var stripOffsets = [Int](repeating: 0, count: stripCount)
        var stripCounts = [Int](repeating: 0, count: stripCount)
        for s in 0..<stripCount {
            stripCounts[s] = rowBytes * min(rowsPerStrip, rows - s * rowsPerStrip)
        }
        var at = pixelStart
        for s in spec.stripsReversedInFile ? Array((0..<stripCount).reversed())
                                          : Array(0..<stripCount) {
            stripOffsets[s] = at
            at += stripCounts[s]
        }
        if spec.truncateLastStripCount, stripCount > 0 { stripCounts[stripCount - 1] -= 1 }

        func patch(_ tag: Int, _ values: [Int], into out: inout [UInt8], entryValueAt: Int) {
            if let pos = tailPosition[tag] {
                var bytes: [UInt8] = []
                for v in values { put32(&bytes, v) }
                for (i, b) in bytes.enumerated() { tail[pos + i] = b }
            } else {
                var bytes: [UInt8] = []
                put32(&bytes, values[0])
                for (i, b) in bytes.enumerated() { out[entryValueAt + i] = b }
            }
        }

        var out: [UInt8] = []
        out.append(spec.bigEndian ? UInt8(ascii: "M") : UInt8(ascii: "I"))
        out.append(spec.bigEndian ? UInt8(ascii: "M") : UInt8(ascii: "I"))
        put16(&out, spec.bigTiffMagic ? 43 : 42)
        put32(&out, ifdStart)
        put16(&out, fields.count)
        var valuePositions = [Int: Int]()
        for f in fields {
            put16(&out, f.tag)
            put16(&out, f.type)
            put32(&out, f.values.count)
            valuePositions[f.tag] = out.count
            let v = inlineValue[f.tag] ?? 0
            // a single SHORT sits in the first two bytes of the four-byte value field
            if f.type == 3 && f.values.count == 1 { put16(&out, v); put16(&out, 0) }
            else { put32(&out, v) }
        }
        put32(&out, 0)                                  // no second IFD
        patch(273, stripOffsets, into: &out, entryValueAt: valuePositions[273]!)
        patch(279, stripCounts, into: &out, entryValueAt: valuePositions[279]!)
        out.append(contentsOf: tail)

        // append each strip's rows in the order the strips sit in the file, which is not
        // the order of the strips themselves when stripsReversedInFile is set
        let pixels = pixelBytes(spec, seed: seed)
        for s in (0..<stripCount).sorted(by: { stripOffsets[$0] < stripOffsets[$1] }) {
            let begin = s * rowsPerStrip * rowBytes
            let length = rowBytes * min(rowsPerStrip, rows - s * rowsPerStrip)
            out.append(contentsOf: pixels[begin..<(begin + length)])
        }

        let path = scratch.appendingPathComponent("\(name).tiff").path
        try Data(out).write(to: URL(fileURLWithPath: path))
        return path
    }

    /// The samples a spec's file should decode to, in OpenCV's channel order: TIFF stores
    /// RGB and both `cv::imread` and the direct read hand back BGR.
    private func expectedSamples(_ spec: Spec, seed: UInt64 = 0x5eed) -> [UInt16] {
        let bytes = pixelBytes(spec, seed: seed)
        var samples: [UInt16] = []
        samples.reserveCapacity(bytes.count / 2)
        var i = 0
        while i + 1 < bytes.count {
            samples.append(UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
            i += 2
        }
        guard spec.samplesPerPixel == 3 else { return samples }
        for p in stride(from: 0, to: samples.count, by: 3) {
            samples.swapAt(p, p + 2)
        }
        return samples
    }

    private func samples(of mat: MatWrapper) throws -> [UInt16] {
        let base = try XCTUnwrap(mat.dataPtr)
        let perRow = mat.cols * mat.channels
        var out: [UInt16] = []
        out.reserveCapacity(perRow * mat.rows)
        for y in 0..<mat.rows {
            let row = base.advanced(by: y * mat.step).assumingMemoryBound(to: UInt16.self)
            for i in 0..<perRow { out.append(row[i]) }
        }
        return out
    }

    // MARK: - the shape that is taken

    /// Every accepted geometry has to come back with the file's own samples, in BGR order,
    /// and has to actually be taking the fast path — a probe that quietly said no would
    /// leave this test passing on `cv::imread` and prove nothing.
    func testEveryAcceptedShapeDecodesToTheFilesOwnSamples() throws {
        var checked = 0
        for spp in [1, 3] {
            for width in [1, 7, 8, 17, 40] {
                for height in [1, 3, 11] {
                    for rowsPerStrip in [nil, 1, 2, 5] as [Int?] {
                        for reversed in [false, true] {
                            // laying strips out backwards only means something with more
                            // than one strip
                            if reversed && (rowsPerStrip == nil || height == 1) { continue }
                            var spec = Spec()
                            spec.samplesPerPixel = spp
                            spec.width = width
                            spec.height = height
                            spec.rowsPerStrip = rowsPerStrip
                            spec.stripsReversedInFile = reversed
                            let name = "ok-\(spp)-\(width)x\(height)-rps\(rowsPerStrip ?? 0)-r\(reversed)"
                            let path = try write(spec, named: name)
                            let label = "\(spp)ch \(width)x\(height) " +
                                        "rowsPerStrip=\(rowsPerStrip ?? height) reversed=\(reversed)"

                            XCTAssertTrue(MatWrapper.tiffIsFastReadable(path),
                                          "the probe declined \(label), so this test would " +
                                          "be checking cv::imread instead")

                            let mat = try XCTUnwrap(MatWrapper.load(fromFilename: path),
                                                    "could not load \(label)")
                            XCTAssertEqual(mat.cols, width, "\(label)")
                            XCTAssertEqual(mat.rows, height, "\(label)")
                            XCTAssertEqual(mat.channels, spp, "\(label)")
                            XCTAssertEqual(try samples(of: mat), expectedSamples(spec),
                                           "samples came back wrong for \(label)")
                            checked += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 100, "the sweep stopped covering anything")
    }

    /// An absent tag has to be read as its default rather than as a reason to refuse:
    /// leaving out RowsPerStrip means one strip, and leaving out Predictor, FillOrder,
    /// Orientation, PlanarConfiguration and SampleFormat means the ordinary values.
    func testTheDefaultsForAbsentTagsAreStillAccepted() throws {
        var spec = Spec()
        spec.rowsPerStrip = nil
        spec.planarConfig = nil
        spec.predictor = nil
        spec.fillOrder = nil
        spec.orientation = nil
        spec.sampleFormat = nil
        let path = try write(spec, named: "bare-tags")
        XCTAssertTrue(MatWrapper.tiffIsFastReadable(path),
                      "a file that omits every optional tag was refused")
        let mat = try XCTUnwrap(MatWrapper.load(fromFilename: path))
        XCTAssertEqual(try samples(of: mat), expectedSamples(spec))
    }

    // MARK: - the shapes that are not

    /// One case per field the probe inspects. Each of these decodes to something other
    /// than the file's raw bytes — a different conversion, a different layout, or a
    /// different sample type — so accepting any of them would corrupt the image rather
    /// than fail loudly. `cv::imread` still handles them; only the shortcut declines.
    func testEveryDisqualifyingTagIsRefused() throws {
        var cases: [(String, Spec)] = []
        func add(_ name: String, _ change: (inout Spec) -> Void) {
            var spec = Spec()
            change(&spec)
            cases.append((name, spec))
        }
        // 8-bit reaches cv::imread through libtiff's RGBA reader, which derives gray with
        // a weighted luma conversion rather than a copy
        add("8-bit samples")            { $0.bitsPerSample = 8 }
        add("32-bit samples")           { $0.bitsPerSample = 32 }
        add("LZW compression")          { $0.compression = 5 }
        add("deflate compression")      { $0.compression = 8 }
        add("packbits compression")     { $0.compression = 32773 }
        add("horizontal predictor")     { $0.predictor = 2 }
        add("planar configuration")     { $0.planarConfig = 2 }
        add("reversed fill order")      { $0.fillOrder = 2 }
        add("bottom-left orientation")  { $0.orientation = 4 }
        add("rotated orientation")      { $0.orientation = 8 }
        add("signed samples")           { $0.sampleFormat = 2 }
        add("float samples")            { $0.sampleFormat = 3 }
        add("one sample too many")      { $0.samplesPerPixel = 4 }
        add("two samples per pixel")    { $0.samplesPerPixel = 2 }
        add("MINISWHITE gray")          { $0.samplesPerPixel = 1; $0.photometric = 0 }
        add("palette")                  { $0.samplesPerPixel = 1; $0.photometric = 3 }
        add("YCbCr")                    { $0.photometric = 6 }
        add("CMYK")                     { $0.photometric = 5 }
        add("three samples called gray") { $0.photometric = 1 }
        add("one sample called RGB")    { $0.samplesPerPixel = 1; $0.photometric = 2 }
        add("extra samples")            { $0.extraSamples = true }
        add("tiled")                    { $0.tiled = true; $0.rowsPerStrip = 4 }
        add("big-endian")               { $0.bigEndian = true }
        add("BigTIFF magic")            { $0.bigTiffMagic = true }
        add("a strip that claims too few bytes") {
            $0.rowsPerStrip = 3; $0.truncateLastStripCount = true
        }

        for (name, spec) in cases {
            let path = try write(spec, named: "no-" + name.replacingOccurrences(of: " ", with: "-"))
            XCTAssertFalse(MatWrapper.tiffIsFastReadable(path),
                           "the direct read accepted \(name), which it cannot decode correctly")
        }
    }

    /// The file star's own writer produces. `mat_wrapper_write_to` is `cv::imwrite`, which
    /// defaults to LZW with a horizontal predictor, so nothing star writes can take this
    /// path — worth pinning, because if that writer ever changed, the shortcut would start
    /// applying to files it was never measured against.
    func testAFileStarWroteIsNotFastReadable() throws {
        let width = 16, height = 4
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: width * height * 3)
        for i in 0..<(width * height * 3) { data[i] = UInt16(truncatingIfNeeded: i * 977) }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                       componentsPerPixel: 3),
                             bytesPerRow: width * 3 * MemoryLayout<UInt16>.size,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)
        let path = scratch.appendingPathComponent("written-by-star.tiff").path
        XCTAssertTrue(mat.write(to: path))

        XCTAssertFalse(MatWrapper.tiffIsFastReadable(path),
                       "cv::imwrite's own output was accepted by the direct read")

        // and it still round-trips through the fallback
        let reloaded = try XCTUnwrap(MatWrapper.load(fromFilename: path))
        XCTAssertEqual(reloaded.cols, width)
        XCTAssertEqual(reloaded.rows, height)
        XCTAssertEqual(reloaded.channels, 3)
    }

    /// Anything that is not a TIFF at all, and files that are damaged. The probe reads
    /// untrusted bytes and computes offsets from them, so it has to refuse rather than
    /// reach past the end of a file — and it must not throw, since `mat_wrapper_load` is
    /// called for every image star opens.
    func testNonTiffAndDamagedFilesAreRefusedWithoutReadingPastTheEnd() throws {
        func path(_ name: String, _ bytes: [UInt8]) throws -> String {
            let p = scratch.appendingPathComponent(name).path
            try Data(bytes).write(to: URL(fileURLWithPath: p))
            return p
        }

        // a valid header pointing at an IFD that is not there
        XCTAssertFalse(MatWrapper.tiffIsFastReadable(
            try path("truncated.tiff", [0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00])))
        // an IFD whose strip offset is past the end of the file
        var spec = Spec()
        spec.height = 4
        let good = try write(spec, named: "for-truncation")
        let full = try Data(contentsOf: URL(fileURLWithPath: good))
        XCTAssertFalse(MatWrapper.tiffIsFastReadable(
            try path("cut-short.tiff", Array(full.prefix(full.count / 2)))),
            "a file cut in half was still accepted")
        // empty, tiny, and not a TIFF
        XCTAssertFalse(MatWrapper.tiffIsFastReadable(try path("empty.tiff", [])))
        XCTAssertFalse(MatWrapper.tiffIsFastReadable(try path("tiny.tiff", [0x49, 0x49])))
        XCTAssertFalse(MatWrapper.tiffIsFastReadable(
            try path("prose.txt", Array("this is not a tiff".utf8))))
        XCTAssertFalse(MatWrapper.tiffIsFastReadable(
            scratch.appendingPathComponent("no-such-file.tiff").path))

        // pseudo-random bytes behind a valid TIFF header: the probe will read tags that
        // mean nothing and must still come back with an answer
        var noise: [UInt8] = [0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00]
        var state: UInt64 = 0xfeed
        for _ in 0..<4096 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            noise.append(UInt8((state >> 33) & 0xff))
        }
        XCTAssertFalse(MatWrapper.tiffIsFastReadable(try path("noise.tiff", noise)),
                       "random tags were read as a valid fast-path TIFF")
    }
}
