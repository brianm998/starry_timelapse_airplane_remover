import XCTest
import Foundation
import StarCpp
@testable import StarCppBridge

/// The cloud-aware stage of the star aligned merge: a second merge aligned to the motion
/// of clouds, blended in where it explains the frame better (see
/// `CLOUD_AWARE_MERGE_IMPLEMENTATION.md`, and the "Cloud-aware merge" section of
/// `ImageAligner.cpp`).
///
/// Every scene here is synthetic and 1536x1024 at the least — large enough for several
/// fully measured rows of the 384px motion tiles (7 x 4 of them), 16 bit, three channels,
/// with noise, because a noiseless frame makes the stage's own noise estimate zero and
/// that is not the input it has to be right on.  Stars are static, so the neighbours'
/// homographies are the identity and their stars are already aligned; the cloud is what
/// moves.
///
/// What each test pins is a property the stage was built to have, each of which was found
/// to be broken at some point on real footage: it must not touch a clear sky, must follow
/// a moving cloud without losing the stars in it or letting a trail back in, must stay out
/// of the ground and the frame edges, and must answer the same whichever merge path made
/// the star merge and however many threads loaded it.
final class CloudAwareMergeTests: XCTestCase {

    // MARK: - the synthetic scene

    static let width = 1536
    static let height = 1024
    static let baseIndex = 10
    static let pixelThreshold = 1.2

    /// Deterministic noise, roughly Gaussian (a sum of four uniforms), from a hash.
    private static func noise(_ seed: UInt64, _ x: Int, _ y: Int, _ c: Int) -> Double {
        var h = seed &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(truncatingIfNeeded: x) &* 0xBF58_476D_1CE4_E5B9
        h ^= UInt64(truncatingIfNeeded: y) &* 0x94D0_49BB_1331_11EB
        h ^= UInt64(truncatingIfNeeded: c) &* 0xD6E8_FEB8_6659_FD93
        var sum = 0.0
        for _ in 0..<4 {
            h ^= h >> 30; h = h &* 0xBF58_476D_1CE4_E5B9
            h ^= h >> 27; h = h &* 0x94D0_49BB_1331_11EB
            h ^= h >> 31
            sum += Double(h >> 11) / Double(1 << 53)
        }
        return (sum - 2.0) * 1.7320508          // unit variance
    }

    struct Star: Sendable { let x: Double, y: Double, amplitude: Double }

    /// What a scene is made of.  A frame is `scene(at: t)` with the cloud moved `speed * t`
    /// pixels along x.  `shiftX` samples the scene that many pixels to the right, which is
    /// how a neighbour with a non-identity homography is made: its content is displaced by
    /// `-shiftX` and the translation `+shiftX` puts it back.
    struct Scene: Sendable {
        var cloudAmplitude = 4000.0
        var cloudSpeed = 40.0
        var cloudCentre = (x: 760.0, y: 470.0)
        var cloudSigma = (x: 330.0, y: 230.0)
        /// How much of a star the cloud in front of it hides.
        var cloudTransmittance = 0.0
        var noiseSigma = 60.0
        var stars: [Star] = []

        /// Texture wavelengths between about 18 and 70px, so it is cloud structure at the
        /// scale the stage correlates, and not noise or a gradient.
        private static let texture: [(kx: Double, ky: Double, phase: Double, weight: Double)] = {
            var rng: UInt64 = 0x1234_5678_9ABC_DEF0
            func next() -> Double {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                return Double(rng >> 11) / Double(1 << 53)
            }
            return (0..<10).map { _ in
                let wavelength = 18.0 + 52.0 * next()
                let angle = 2.0 * Double.pi * next()
                let k = 2.0 * Double.pi / wavelength
                return (k * cos(angle), k * sin(angle), 2.0 * Double.pi * next(), 0.4 + 0.6 * next())
            }
        }()

        func cloud(x: Double, y: Double, at t: Int) -> Double {
            let cx = x - cloudSpeed * Double(t)
            let ex = (cx - cloudCentre.x) / cloudSigma.x
            let ey = (y - cloudCentre.y) / cloudSigma.y
            let envelope = exp(-0.5 * (ex * ex + ey * ey))
            if envelope < 1e-4 { return 0 }
            var tex = 0.0, total = 0.0
            for c in Self.texture {
                tex += c.weight * cos(c.kx * cx + c.ky * y + c.phase)
                total += c.weight
            }
            return cloudAmplitude * envelope * (0.55 + 0.45 * tex / total)
        }

        static func sky(x: Double, y: Double, channel c: Int) -> Double {
            5200 + 0.7 * y + 0.2 * x + 350 * Double(c)
        }

        static func makeStars(count: Int, width: Int, height: Int, seed: UInt64) -> [Star] {
            var rng = seed
            func next() -> Double {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                return Double(rng >> 11) / Double(1 << 53)
            }
            return (0..<count).map { _ in
                Star(x: 40 + next() * Double(width - 80), y: 40 + next() * Double(height - 80),
                     amplitude: 9000 + 14000 * next())
            }
        }
    }

    /// A trail in one frame only: a straight line two pixels wide.
    struct Trail: Sendable {
        var from = (x: 120.0, y: 700.0)
        var to = (x: 1400.0, y: 380.0)
        var amplitude = 22000.0

        func contribution(x: Int, y: Int) -> Double {
            let dx = to.x - from.x, dy = to.y - from.y
            let length2 = dx * dx + dy * dy
            let t = ((Double(x) - from.x) * dx + (Double(y) - from.y) * dy) / length2
            if t < 0 || t > 1 { return 0 }
            let px = from.x + t * dx, py = from.y + t * dy
            let d = ((Double(x) - px) * (Double(x) - px) + (Double(y) - py) * (Double(y) - py)).squareRoot()
            return d < 1.0 ? amplitude : (d < 2.0 ? amplitude * (2.0 - d) : 0)
        }
    }

    /// Planes shared by the rows being rendered on different threads; each row only ever
    /// touches its own part, which is what makes handing them out unchecked safe.
    private final class Planes: @unchecked Sendable {
        let shared: UnsafeMutablePointer<Double>
        let transmittance: UnsafeMutablePointer<Double>
        let stars: UnsafeMutablePointer<Double>
        let out: UnsafeMutablePointer<UInt16>
        init(width: Int, height: Int) {
            let n = width * height
            shared = .allocate(capacity: n); shared.initialize(repeating: 0, count: n)
            transmittance = .allocate(capacity: n); transmittance.initialize(repeating: 1, count: n)
            stars = .allocate(capacity: n); stars.initialize(repeating: 0, count: n)
            out = .allocate(capacity: n * 3)
        }
        deinit { shared.deallocate(); transmittance.deallocate(); stars.deallocate() }
    }

    /// One frame of `scene` at time `t`, BGR, 16 bit.
    static func render(_ scene: Scene, at t: Int, shiftX: Int = 0, trail: Trail? = nil,
                       width: Int = width, height: Int = height) -> MatWrapper {
        let planes = Planes(width: width, height: height)
        let seed = UInt64(0xC10D_0000 + t * 977 + shiftX)

        DispatchQueue.concurrentPerform(iterations: height) { y in
            for x in 0..<width {
                let cloud = scene.cloud(x: Double(x + shiftX), y: Double(y), at: t)
                var value = cloud
                if let trail { value += trail.contribution(x: x, y: y) }
                planes.shared[y * width + x] = value
                if scene.cloudTransmittance > 0 {
                    planes.transmittance[y * width + x] = 1.0 - scene.cloudTransmittance
                        * min(1.0, cloud / max(scene.cloudAmplitude, 1))
                }
            }
        }
        // stars: a small Gaussian each, scaled by what the cloud lets through
        for s in scene.stars {
            let sx = s.x - Double(shiftX)
            for y in max(0, Int(s.y) - 3)...min(height - 1, Int(s.y) + 3) {
                for x in max(0, Int(sx) - 3)...min(width - 1, Int(sx) + 3) {
                    let dx = Double(x) - sx, dy = Double(y) - s.y
                    planes.stars[y * width + x] += s.amplitude * exp(-(dx * dx + dy * dy) / (2 * 0.85 * 0.85))
                }
            }
        }
        DispatchQueue.concurrentPerform(iterations: height) { y in
            for x in 0..<width {
                let i = y * width + x
                for c in 0..<3 {
                    let v = Scene.sky(x: Double(x + shiftX), y: Double(y), channel: c)
                        + planes.shared[i] * [0.9, 1.0, 1.1][c]
                        + planes.stars[i] * planes.transmittance[i]
                        + scene.noiseSigma * noise(seed, x, y, c)
                    planes.out[i * 3 + c] = UInt16(max(0, min(65535, v.rounded())))
                }
            }
        }
        // the Mat takes the output buffer; the scratch planes go with `planes`
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 16, componentsPerPixel: 3),
                          bytesPerRow: width * 3 * MemoryLayout<UInt16>.size,
                          data: UnsafeMutableRawPointer(planes.out), takeOwnership: true)
    }

    // MARK: - plumbing

    // Set once in setUp and guarded by `lock` where they change; the compiler cannot see that.
    nonisolated(unsafe) private static var directory: URL!
    nonisolated(unsafe) private static var written = Set<String>()
    private static let lock = NSLock()

    override class func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CloudAwareMergeTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Without this every filename source loads as nothing and a merge silently runs on
        // the base frame alone, which makes most of the assertions below pass for the wrong
        // reason.  `merge` checks that its sources load.
        ImageCache.setLoader { MatWrapper.load(fromFilename: $0) }
    }

    override class func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    /// The path of frame `t` of the named scene, rendering and writing it on first use.
    private func framePath(_ key: String, _ scene: Scene, t: Int, shiftX: Int = 0,
                           trail: Trail? = nil) throws -> String {
        let name = "\(key)-\(t)-\(shiftX)-\(trail == nil ? "n" : "t").tiff"
        let path = Self.directory.appendingPathComponent(name).path
        Self.lock.lock(); defer { Self.lock.unlock() }
        if !Self.written.contains(name) {
            let mat = Self.render(scene, at: t, shiftX: shiftX, trail: trail)
            XCTAssertTrue(mat.write(to: path), "could not write \(path)")
            Self.written.insert(name)
        }
        return path
    }

    private func identity() -> MatWrapper {
        MatWrapper(homographyValues: [1, 0, 0, 0, 1, 0, 0, 0, 1])
    }

    private func translation(x: Double) -> MatWrapper {
        MatWrapper(homographyValues: [1, 0, x, 0, 1, 0, 0, 0, 1])
    }

    struct Setup {
        var offsets = [-4, -3, -2, -1, 1, 2, 3, 4]
        /// Offsets whose neighbour has no homography at all.
        var withoutHomography: Set<Int> = []
        /// Per offset, how far the neighbour's content is displaced; its homography is
        /// the translation that puts it back.
        var shifts: [Int: Int] = [:]
        var trailInBase: Trail? = nil
    }

    struct Merge {
        var merged: MatWrapper
        var warpCount: Int
    }

    /// One merge of `scene`'s frame `baseIndex` against its neighbours.
    private func merge(_ key: String, _ scene: Scene, _ setup: Setup = Setup(),
                       cloudAware: Bool, sky: MatWrapper? = nil,
                       streaming: Bool = false, loadConcurrency: Int = 1, useGPU: Bool = false,
                       debugDir: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) throws -> Merge {
        let baseT = 0
        let base = try XCTUnwrap(MatWrapper.load(
          fromFilename: try framePath(key, scene, t: baseT, trail: setup.trailInBase)),
                                 file: file, line: line)
        var infos: [AlignmentNeighborInfo] = []
        var homography: [Int: MatWrapper] = [:]
        for offset in setup.offsets {
            let shift = setup.shifts[offset] ?? 0
            let path = try framePath(key, scene, t: baseT + offset, shiftX: shift)
            infos.append(AlignmentNeighborInfo(filename: path, maskFilename: nil, keypoints: nil,
                                               frameIndex: Int32(Self.baseIndex + offset)))
            if !setup.withoutHomography.contains(offset) {
                homography[offset] = shift == 0 ? identity() : translation(x: Double(shift))
            }
        }
        for info in infos {
            XCTAssertNotNil(ImageCache.load(info.filename), "\(info.filename) did not load",
                            file: file, line: line)
        }
        let scratch = Self.directory.appendingPathComponent("scratch").path
        let result = try XCTUnwrap(ImageAligner.alignAndMedianMerge(
          baseImage: base, baseFrameIndex: Int32(Self.baseIndex),
          neighbors: infos, homography: homography,
          outlierThreshold: Self.pixelThreshold, includeAll: false,
          scratchDir: scratch,
          streamingThresholdBytes: streaming ? 1 : 0,
          loadConcurrency: loadConcurrency,
          useGPU: useGPU,
          cloudAware: cloudAware, skyMask: sky, cloudDebugDir: debugDir),
                                   file: file, line: line)
        return Merge(merged: result.merged, warpCount: result.warpCount)
    }

    /// The frame as a flat BGR array of 16 bit values.
    private func pixels(_ mat: MatWrapper) throws -> [UInt16] {
        let base = try XCTUnwrap(mat.dataPtr)
        var out = [UInt16](repeating: 0, count: mat.rows * mat.cols * mat.channels)
        for y in 0..<mat.rows {
            let row = base.advanced(by: y * mat.step).assumingMemoryBound(to: UInt16.self)
            for i in 0..<(mat.cols * mat.channels) { out[y * mat.cols * mat.channels + i] = row[i] }
        }
        return out
    }

    private func luma(_ p: [UInt16], width: Int, height: Int) -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            out[i] = 0.0722 * Double(p[i * 3]) + 0.7152 * Double(p[i * 3 + 1]) + 0.2126 * Double(p[i * 3 + 2])
        }
        return out
    }

    /// Three successive box blurs of radius r over a plane, edges replicated.
    private func blur(_ a: [Double], width: Int, height: Int, radius r: Int) -> [Double] {
        var cur = a
        for _ in 0..<3 {
            var tmp = [Double](repeating: 0, count: cur.count)
            let win = Double(2 * r + 1)
            for y in 0..<height {
                var s = 0.0
                for x in -r...r { s += cur[y * width + min(max(x, 0), width - 1)] }
                for x in 0..<width {
                    tmp[y * width + x] = s / win
                    s += cur[y * width + min(x + r + 1, width - 1)] - cur[y * width + max(x - r, 0)]
                }
            }
            var out = [Double](repeating: 0, count: cur.count)
            for x in 0..<width {
                var s = 0.0
                for y in -r...r { s += tmp[min(max(y, 0), height - 1) * width + x] }
                for y in 0..<height {
                    out[y * width + x] = s / win
                    s += tmp[min(y + r + 1, height - 1) * width + x] - tmp[max(y - r, 0) * width + x]
                }
            }
            cur = out
        }
        return cur
    }

    /// Correlation, over the cloud, of the base frame's band-passed (2 to 24px) luma with
    /// the candidate's: 1.0 means the cloud's structure is the base frame's own.  The same
    /// measure the implementation guide scores real frames with, on a crop.
    private func cloudCorrelation(base: [UInt16], candidate: [UInt16], scene: Scene,
                                  width: Int = CloudAwareMergeTests.width,
                                  height: Int = CloudAwareMergeTests.height) -> Double {
        let lb = luma(base, width: width, height: height)
        let lc = luma(candidate, width: width, height: height)
        func bandPass(_ a: [Double]) -> [Double] {
            let fine = blur(a, width: width, height: height, radius: 2)
            let coarse = blur(a, width: width, height: height, radius: 24)
            return zip(fine, coarse).map { $0 - $1 }
        }
        let bb = bandPass(lb), bc = bandPass(lc)
        var xs: [Double] = [], ys: [Double] = []
        for y in 100..<(height - 100) {
            for x in 100..<(width - 100) {
                if scene.cloud(x: Double(x), y: Double(y), at: 0) > 0.4 * scene.cloudAmplitude {
                    xs.append(bb[y * width + x]); ys.append(bc[y * width + x])
                }
            }
        }
        precondition(xs.count > 10000, "cloud region too small to measure")
        let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<xs.count {
            sxy += (xs[i] - mx) * (ys[i] - my)
            sxx += (xs[i] - mx) * (xs[i] - mx)
            syy += (ys[i] - my) * (ys[i] - my)
        }
        return sxy / (sxx * syy).squareRoot()
    }

    /// A star's amplitude: the brightest of the 3x3 around it minus the median of the
    /// 5 to 8px ring around that.
    private func starAmplitude(_ l: [Double], at star: Star, width: Int = CloudAwareMergeTests.width) -> Double {
        let cx = Int(star.x.rounded()), cy = Int(star.y.rounded())
        var peak = -Double.infinity
        for y in (cy - 1)...(cy + 1) { for x in (cx - 1)...(cx + 1) { peak = max(peak, l[y * width + x]) } }
        var ring: [Double] = []
        for y in (cy - 8)...(cy + 8) {
            for x in (cx - 8)...(cx + 8) {
                let d2 = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                if d2 >= 25 && d2 <= 64 { ring.append(l[y * width + x]) }
            }
        }
        ring.sort()
        return peak - ring[ring.count / 2]
    }

    /// Stars at least 14px from each other and from every frame border, brightest first.
    private func isolated(_ stars: [Star], inside region: (Star) -> Bool) -> [Star] {
        var picked: [Star] = []
        for s in stars.sorted(by: { $0.amplitude > $1.amplitude }) where region(s) {
            let clear = stars.allSatisfy { o in
                (o.x == s.x && o.y == s.y) || hypot(o.x - s.x, o.y - s.y) >= 14
            }
            if clear { picked.append(s) }
        }
        return picked
    }

    // MARK: - scenes shared between tests

    private static let staticStars = Scene.makeStars(count: 160, width: width, height: height, seed: 77)

    private var movingCloud: Scene {
        var s = Scene()
        s.stars = Self.staticStars
        return s
    }

    private var clearSky: Scene {
        var s = Scene()
        s.cloudAmplitude = 0
        s.stars = Self.staticStars
        return s
    }

    // MARK: - 1. a clear sky is untouched

    /// Sky gradient, point stars, noise and a trail in the base frame only, with nothing
    /// moving: the star merge already explains the base, so the output has to be the star
    /// merge byte for byte.  This is the property that makes the stage safe to leave on.
    func testAStaticSceneIsByteIdentical() throws {
        let setup = Setup(trailInBase: Trail())
        let off = try merge("clear", clearSky, setup, cloudAware: false)
        let on = try merge("clear", clearSky, setup, cloudAware: true)
        XCTAssertEqual(on.warpCount, off.warpCount)
        XCTAssertEqual(try pixels(on.merged), try pixels(off.merged),
                       "a scene with nothing moving must come out exactly as the star merge")
    }

    // MARK: - 2. a moving cloud keeps its shape

    /// A band-limited textured blob moving 40px a frame over point stars, with a trail in
    /// the base frame only.  Today's merge takes each pixel of the blob from a different
    /// moment, which shows as lost correlation with the base frame's own cloud; with the
    /// stage the cloud is the base frame's again, the trail is still gone, and the stars
    /// inside the cloud and outside it are still there.
    func testAMovingCloudKeepsItsShape() throws {
        let scene = movingCloud
        let setup = Setup(trailInBase: Trail())
        let base = try pixels(try XCTUnwrap(MatWrapper.load(
          fromFilename: try framePath("cloud", scene, t: 0, trail: setup.trailInBase))))
        let off = try merge("cloud", scene, setup, cloudAware: false)
        let on = try merge("cloud", scene, setup, cloudAware: true)
        let offPixels = try pixels(off.merged), onPixels = try pixels(on.merged)

        let corrOff = cloudCorrelation(base: base, candidate: offPixels, scene: scene)
        let corrOn = cloudCorrelation(base: base, candidate: onPixels, scene: scene)
        print("cloud correlation: flag off \(corrOff), flag on \(corrOn)")
        XCTAssertGreaterThan(corrOn, 0.9, "the cloud must keep the base frame's structure")
        XCTAssertLessThan(corrOff, corrOn - 0.15, "and today's merge must clearly not")

        // the trail: mean luma on the line against beside it, in units of pixel noise
        let trail = try XCTUnwrap(setup.trailInBase)
        func trailContrast(_ p: [UInt16]) -> Double {
            let l = luma(p, width: Self.width, height: Self.height)
            var on = 0.0, side = 0.0, n = 0.0
            let dx = trail.to.x - trail.from.x, dy = trail.to.y - trail.from.y
            let length = hypot(dx, dy), nx = -dy / length, ny = dx / length
            for i in 0..<600 {
                let t = 0.05 + 0.9 * Double(i) / 600
                let px = trail.from.x + t * dx, py = trail.from.y + t * dy
                func at(_ off: Double) -> Double {
                    l[Int((py + off * ny).rounded()) * Self.width + Int((px + off * nx).rounded())]
                }
                on += at(0)
                side += (at(-9) + at(9)) / 2
                n += 1
            }
            return (on - side) / n
        }
        let noise = 60.0
        XCTAssertGreaterThan(trailContrast(base), 20 * noise, "the trail has to be there to be removed")
        XCTAssertLessThan(abs(trailContrast(offPixels)), 1.5 * noise)
        XCTAssertLessThan(abs(trailContrast(onPixels)), 1.5 * noise,
                          "the trail must still be removed inside and outside the cloud")

        // stars: their amplitude in the output against the star merge's own, inside the
        // cloud and in clear sky
        let lOff = luma(offPixels, width: Self.width, height: Self.height)
        let lOn = luma(onPixels, width: Self.width, height: Self.height)
        let inCloud = isolated(scene.stars) { s in
            scene.cloud(x: s.x, y: s.y, at: 0) > 0.5 * scene.cloudAmplitude
        }
        let inClear = isolated(scene.stars) { s in scene.cloud(x: s.x, y: s.y, at: 0) < 0.02 * scene.cloudAmplitude }
        XCTAssertGreaterThan(inCloud.count, 3)
        XCTAssertGreaterThan(inClear.count, 10)
        for (name, group) in [("inside the cloud", inCloud), ("in clear sky", inClear)] {
            let ratios = group.prefix(40).map { starAmplitude(lOn, at: $0) / starAmplitude(lOff, at: $0) }
            let median = ratios.sorted()[ratios.count / 2]
            let kept = Double(ratios.filter { $0 >= 0.8 }.count) / Double(ratios.count)
            print("stars \(name): median amplitude ratio \(median), kept >= 80%: \(kept) of \(ratios.count)")
            XCTAssertGreaterThan(median, 0.9, "stars \(name)")
            XCTAssertGreaterThan(kept, 0.9, "stars \(name)")
        }
    }

    // MARK: - 3. stars behind thin cloud

    /// A semi-transparent moving cloud over the stars: each star shines through at a
    /// fraction that changes as the cloud passes, and the output has to keep them.
    func testStarsBehindThinCloudAreKept() throws {
        var scene = movingCloud
        scene.cloudAmplitude = 2500
        scene.cloudTransmittance = 0.55
        let off = try merge("thin", scene, cloudAware: false)
        let on = try merge("thin", scene, cloudAware: true)
        let lOff = luma(try pixels(off.merged), width: Self.width, height: Self.height)
        let lOn = luma(try pixels(on.merged), width: Self.width, height: Self.height)
        let behind = isolated(scene.stars) { s in scene.cloud(x: s.x, y: s.y, at: 0) > 0.4 * scene.cloudAmplitude }
        XCTAssertGreaterThan(behind.count, 3)
        for star in behind.prefix(30) {
            let ratio = starAmplitude(lOn, at: star) / starAmplitude(lOff, at: star)
            XCTAssertGreaterThanOrEqual(ratio, 0.8, "star at (\(star.x), \(star.y))")
        }
    }

    // MARK: - 4. the end of a sequence

    /// The first frame of a sequence has neighbours on one side only: +1...+4.  The
    /// velocity then comes from +2 alone, and the stage still has to keep the cloud.
    func testSequenceEndWithNeighboursOnOneSide() throws {
        let scene = movingCloud
        let setup = Setup(offsets: [1, 2, 3, 4])
        let base = try pixels(try XCTUnwrap(MatWrapper.load(fromFilename: try framePath("cloud", scene, t: 0))))
        let off = try merge("cloud", scene, setup, cloudAware: false)
        let on = try merge("cloud", scene, setup, cloudAware: true)
        XCTAssertEqual(on.warpCount, 4)
        let corrOff = cloudCorrelation(base: base, candidate: try pixels(off.merged), scene: scene)
        let corrOn = cloudCorrelation(base: base, candidate: try pixels(on.merged), scene: scene)
        print("one sided: correlation flag off \(corrOff), flag on \(corrOn)")
        XCTAssertGreaterThan(corrOn, 0.85)
        XCTAssertGreaterThan(corrOn, corrOff + 0.1)

        // and with only ±1 to go on, the shortest neighbour set the stage accepts
        let nearest = try merge("cloud", scene, Setup(offsets: [-1, 1]), cloudAware: true)
        XCTAssertEqual(nearest.warpCount, 2)
    }

    // MARK: - 5. a neighbour without a homography

    /// Absent from both stacks, as it is from today's.
    func testANeighbourWithoutAHomographyIsSkipped() throws {
        let setup = Setup(withoutHomography: [3])
        let scene = movingCloud
        let off = try merge("cloud", scene, setup, cloudAware: false)
        let on = try merge("cloud", scene, setup, cloudAware: true)
        XCTAssertEqual(off.warpCount, 7)
        XCTAssertEqual(on.warpCount, 7)
        let base = try pixels(try XCTUnwrap(MatWrapper.load(fromFilename: try framePath("cloud", scene, t: 0))))
        XCTAssertGreaterThan(cloudCorrelation(base: base, candidate: try pixels(on.merged), scene: scene), 0.85)

        // and on a clear sky it changes nothing at all, whichever neighbour is missing
        let clearOff = try merge("clear", clearSky, setup, cloudAware: false)
        let clearOn = try merge("clear", clearSky, setup, cloudAware: true)
        XCTAssertEqual(try pixels(clearOn.merged), try pixels(clearOff.merged))
    }

    // MARK: - 6. the ground and the frame edges stay out

    /// The sky mask covers the top half and the cloud is in the bottom half, which is the
    /// ground: nothing more than 48px below the mask's edge may change, because the weight
    /// blur is 3 x 16px and the stage forces the weight to zero on the ground.
    func testTheGroundStaysOut() throws {
        var scene = movingCloud
        scene.cloudCentre = (x: 760, y: 780)       // in the bottom half
        scene.cloudSigma = (x: 330, y: 150)
        let height = Self.height, width = Self.width
        let skyMat = Self.makeMask(width: width, height: height) { _, y in y < height / 2 }

        let off = try merge("ground", scene, cloudAware: false, sky: skyMat)
        let on = try merge("ground", scene, cloudAware: true, sky: skyMat)
        let a = try pixels(off.merged), b = try pixels(on.merged)
        let firstRow = height / 2 + 48
        XCTAssertEqual(Array(a[(firstRow * width * 3)...]), Array(b[(firstRow * width * 3)...]),
                       "ground more than 48px below the horizon must be the star merge")
        // the same scene with no mask at all must change, or the test proves nothing
        let unmasked = try merge("ground", scene, cloudAware: true)
        XCTAssertNotEqual(try pixels(unmasked.merged), a, "the cloud has to be there to be kept out")
    }

    /// A neighbour displaced by 400px leaves a strip of the frame that its warp does not
    /// reach.  Where a source is missing the weight is forced to zero, so pixels more than
    /// 48px inside that strip must be the star merge.
    func testAnUncoveredEdgeStripStaysOut() throws {
        let scene = movingCloud
        var setup = Setup()
        setup.shifts[2] = 400                 // uncovers columns 0..<400 of that neighbour's warp
        let off = try merge("edge", scene, setup, cloudAware: false)
        let on = try merge("edge", scene, setup, cloudAware: true)
        XCTAssertEqual(off.warpCount, 8)
        XCTAssertEqual(on.warpCount, 8)
        let a = try pixels(off.merged), b = try pixels(on.merged)
        let width = Self.width
        var differing = 0, inStrip = 0
        for y in 0..<Self.height {
            for x in 0..<(400 - 48) {
                inStrip += 1
                for c in 0..<3 where a[(y * width + x) * 3 + c] != b[(y * width + x) * 3 + c] { differing += 1 }
            }
        }
        XCTAssertGreaterThan(inStrip, 0)
        XCTAssertEqual(differing, 0, "pixels more than 48px inside an uncovered strip must be the star merge")
        // and the cloud beyond the strip has to have been kept, or this passes by doing nothing
        let base = try pixels(try XCTUnwrap(MatWrapper.load(fromFilename: try framePath("edge", scene, t: 0))))
        XCTAssertGreaterThan(cloudCorrelation(base: base, candidate: b, scene: scene),
                             cloudCorrelation(base: base, candidate: a, scene: scene) + 0.1)
    }

    private static func makeMask(width: Int, height: Int, _ sky: (Int, Int) -> Bool) -> MatWrapper {
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for y in 0..<height { for x in 0..<width { data[y * width + x] = sky(x, y) ? 255 : 0 } }
        return MatWrapper(width: width, height: height,
                          cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                          bytesPerRow: width, data: UnsafeMutableRawPointer(data), takeOwnership: true)
    }

    // MARK: - 7. every path gives the same answer

    /// The streaming merge, the resident one, and every load concurrency must agree to the
    /// bit once the stage is on: the stage reads the same pixels and sorts them, and
    /// nothing in it depends on the order sources arrived in.
    func testEveryMergePathAndLoadConcurrencyAgree() throws {
        let scene = movingCloud
        let reference = try pixels(try merge("cloud", scene, cloudAware: true).merged)
        let streamed = try pixels(try merge("cloud", scene, cloudAware: true, streaming: true).merged)
        XCTAssertEqual(streamed, reference, "the streaming path must match the resident one")
        for concurrency in [2, 4] {
            let threaded = try pixels(try merge("cloud", scene, cloudAware: true,
                                                loadConcurrency: concurrency).merged)
            XCTAssertEqual(threaded, reference, "loadConcurrency \(concurrency)")
        }
        let both = try pixels(try merge("cloud", scene, cloudAware: true, streaming: true,
                                        loadConcurrency: 4).merged)
        XCTAssertEqual(both, reference)
    }

    // MARK: - 8. restricting to a region changes nothing

    /// The stage computes only inside the region its weight can reach.  A cloud that fills
    /// part of the frame gives it a region smaller than the frame, and switching the
    /// restriction off must give the same bytes.
    func testRestrictingToARegionChangesNothing() throws {
        var scene = movingCloud
        scene.cloudCentre = (x: 520, y: 380)
        scene.cloudSigma = (x: 200, y: 130)
        let scratch = Self.directory.appendingPathComponent("debug-region").path
        let restricted = try pixels(try merge("small", scene, cloudAware: true, debugDir: scratch).merged)

        // the weight image says how much of the frame the cloud reached
        let alpha = try XCTUnwrap(MatWrapper.load(fromFilename: "\(scratch)/cloud-alpha-\(Self.baseIndex).tif"))
        let a = try XCTUnwrap(alpha.dataPtr).assumingMemoryBound(to: UInt8.self)
        var minX = Self.width, maxX = -1, minY = Self.height, maxY = -1
        for y in 0..<alpha.rows {
            for x in 0..<alpha.cols where a[y * alpha.step + x] > 0 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        XCTAssertGreaterThan(maxX, minX, "the cloud must have produced a weight")
        XCTAssertLessThan((maxX - minX + 1) * (maxY - minY + 1), Self.width * Self.height / 2,
                          "the weight must cover well under the whole frame, or nothing was restricted")

        ia_debug_set_cloud_region_restriction(false)
        defer { ia_debug_set_cloud_region_restriction(true) }
        let whole = try pixels(try merge("small", scene, cloudAware: true).merged)
        XCTAssertEqual(whole, restricted, "restricting the stage to its region must not change a byte")
    }

    // MARK: - 9. the GPU path

    /// With `useGPU` the star merge comes from the fused Metal kernel and the stage runs
    /// on the CPU after it, deriving its own coverage plane.  It has to work, keep the
    /// cloud, and leave a static scene exactly as the GPU merge made it.
    func testTheStageWorksAfterTheGPUMerge() throws {
        try XCTSkipUnless(GPUCapability.isAvailable(), "no GPU on this machine")
        // The handlers are registered by StarCore at startup; here nothing else has.
        XCTAssertTrue(GPUOps.registerIfAvailable())
        let scene = movingCloud
        let base = try pixels(try XCTUnwrap(MatWrapper.load(fromFilename: try framePath("cloud", scene, t: 0))))
        let on = try merge("cloud", scene, cloudAware: true, useGPU: true)
        XCTAssertEqual(on.warpCount, 8)
        let corr = cloudCorrelation(base: base, candidate: try pixels(on.merged), scene: scene)
        XCTAssertGreaterThan(corr, 0.9)

        let clearOff = try merge("clear", clearSky, cloudAware: false, useGPU: true)
        let clearOn = try merge("clear", clearSky, cloudAware: true, useGPU: true)
        XCTAssertEqual(try pixels(clearOn.merged), try pixels(clearOff.merged))

        // against the CPU path: the GPU merge differs from the CPU kernel by a documented
        // small amount, and the stage must not widen it into something visible
        let cpu = try pixels(try merge("cloud", scene, cloudAware: true).merged)
        let gpu = try pixels(on.merged)
        var total = 0.0
        for i in 0..<cpu.count { total += abs(Double(cpu[i]) - Double(gpu[i])) }
        let meanDifference = total / Double(cpu.count)
        print("GPU versus CPU, flag on: mean absolute difference \(meanDifference)")
        XCTAssertLessThan(meanDifference, 0.05 * scene.noiseSigma,
                          "the GPU and CPU merges must stay close with the stage on")
    }
}
