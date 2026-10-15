import XCTest
@testable import RemovalCore

/// Deterministic noise so tests are stable.
struct LCG {
    var s: UInt64
    mutating func next() -> Float {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Float((s >> 33) & 0xFFFFFF) / Float(0xFFFFFF)
    }
    mutating func gauss() -> Float {
        var t: Float = 0
        for _ in 0..<12 { t += next() }
        return t - 6
    }
}

func flatPlane(_ w: Int, _ h: Int, level: Float = 0.2, noise: Float = 0.003, seed: UInt64 = 1) -> Plane {
    var g = LCG(s: seed)
    var p = Plane(width: w, height: h)
    for i in 0..<p.data.count { p.data[i] = level + noise * g.gauss() }
    return p
}

/// y = 0.2215 x + 190 style line, drawn into a plane with a hard 8 px wide core.
func paintLine(_ p: inout Plane, from a: Point, to b: Point, width: Double, amplitude: Float) {
    for y in 0..<p.height { for x in 0..<p.width {
        if Geometry.distance(from: Point(x: Double(x), y: Double(y)), toSegment: a, b) <= width / 2 { p[x, y] += amplitude }
    } }
}

final class TrailCheckTests: XCTestCase {
    let a = Point(x: 40, y: 100), b = Point(x: 340, y: 150)
    var obj: LabelObject { LabelObject(id: "t", class: .airplane, points: [[40, 100], [340, 150]], width: 8, confirmed: true) }

    func testInputAgainstItselfIsRatioOne() {
        var p = flatPlane(400, 250)
        paintLine(&p, from: a, to: b, width: 8, amplitude: 0.3)
        let m = TrailCheck.measure(input: p, output: p, object: obj)
        XCTAssertEqual(m.stretches.count, 6)
        for s in m.stretches { XCTAssertEqual(s.ratio ?? 0, 1, accuracy: 1e-6) }
        XCTAssertEqual(m.measurableFraction, 1, accuracy: 1e-9)
    }

    func testRemovedLineHasRatioNearZero() {
        var input = flatPlane(400, 250, seed: 1)
        paintLine(&input, from: a, to: b, width: 8, amplitude: 0.3)
        let output = flatPlane(400, 250, seed: 2)
        let m = TrailCheck.measure(input: input, output: output, object: obj)
        XCTAssertLessThan(m.worstRatio ?? 9, 0.05)
        XCTAssertEqual(m.fractionRemoved, 1, accuracy: 1e-9)
    }

    func testKnownPartialRatio() {
        var input = flatPlane(400, 250, noise: 0.001)
        paintLine(&input, from: a, to: b, width: 8, amplitude: 0.4)
        var output = flatPlane(400, 250, noise: 0.001)
        paintLine(&output, from: a, to: b, width: 8, amplitude: 0.1)   // 25% left
        let m = TrailCheck.measure(input: input, output: output, object: obj)
        for s in m.stretches { XCTAssertEqual(s.ratio ?? 0, 0.25, accuracy: 0.03) }
    }

    func testOneStretchLeftBehindIsTheWorst() {
        var input = flatPlane(400, 250, noise: 0.001)
        paintLine(&input, from: a, to: b, width: 8, amplitude: 0.4)
        var output = flatPlane(400, 250, noise: 0.001)
        paintLine(&output, from: Point(x: 150, y: 118.333), to: Point(x: 190, y: 125), width: 8, amplitude: 0.4)
        let m = TrailCheck.measure(input: input, output: output, object: obj)
        XCTAssertGreaterThan(m.worstRatio ?? 0, 0.8)
        XCTAssertLessThan(m.fractionRemoved, 1)
    }

    func testFaintTrailIsUnmeasurable() {
        var input = flatPlane(400, 250, noise: 0.01)
        paintLine(&input, from: a, to: b, width: 8, amplitude: 0.001)   // ~0.1 sigma per pixel
        let m = TrailCheck.measure(input: input, output: input, object: obj)
        XCTAssertLessThan(m.measurableFraction, 0.2)
    }
}

final class StarCheckTests: XCTestCase {
    func starField(scale: Float) -> Plane {
        var p = flatPlane(300, 300, noise: 0.002)
        let centres = [(60, 60), (150, 80), (240, 100), (90, 200), (200, 220), (260, 260)]
        for (cx, cy) in centres {
            for dy in -3...3 { for dx in -3...3 {
                let r2 = Float(dx * dx + dy * dy)
                p[cx + dx, cy + dy] += scale * 0.5 * exp(-r2 / 2)
            } }
        }
        return p
    }

    func testFindsAllInjectedPeaksAndRecoversFluxScale() {
        let input = starField(scale: 1)
        var output = input
        for i in 0..<output.data.count { output.data[i] = 0.2 + (input.data[i] - 0.2) * 0.9 }
        let (m, peaks) = StarCheck.measure(input: input, output: output)
        XCTAssertEqual(m.peaks, 6)
        XCTAssertEqual(m.medianRatio, 0.9, accuracy: 0.05)
        XCTAssertEqual(m.fractionBelowHalf, 0)
        XCTAssertEqual(peaks.count, 6)
    }

    func testLostStarsAreCounted() {
        let input = starField(scale: 1)
        var output = input
        for dy in -4...4 { for dx in -4...4 { output[60 + dx, 60 + dy] = 0.2; output[150 + dx, 80 + dy] = 0.2 } }
        let (m, _) = StarCheck.measure(input: input, output: output)
        XCTAssertEqual(m.fractionBelowHalf, 2.0 / 6.0, accuracy: 1e-9)
    }

    func testIncludeFilterExcludesPeaks() {
        let input = starField(scale: 1)
        let (m, _) = StarCheck.measure(input: input, output: input) { x, _ in x > 100 }
        XCTAssertEqual(m.peaks, 4)
    }
}

final class CollateralTests: XCTestCase {
    func testUnlabelledChangedBlobIsReportedOnce() {
        let w = 200, h = 120
        let input = Raster(width: w, height: h, channels: 3, fill: 0.3)
        var output = input
        // inside the footprint: must be ignored
        for x in 20...120 { for c in 0..<3 { output.data[(60 * w + x) * 3 + c] = 0.9 } }
        // an unlabelled 5x4 blob outside it
        for y in 20..<24 { for x in 150..<155 { output.data[(y * w + x) * 3 + 1] = 0.5 } }
        let obj = LabelObject(id: "a", class: .airplane, points: [[20, 60], [120, 60]], width: 8, confirmed: true)
        let fp = Collateral.footprint(width: w, height: h, objects: [obj], margin: 10)
        let comps = Collateral.changedComponents(input: input, output: output, footprint: fp)
        XCTAssertEqual(comps.count, 1)
        XCTAssertEqual(comps[0].area, 20)
        XCTAssertEqual(comps[0].minX, 150); XCTAssertEqual(comps[0].maxX, 154)
        XCTAssertEqual(comps[0].minY, 20); XCTAssertEqual(comps[0].maxY, 23)
        XCTAssertEqual(comps[0].peakDifference, 0.2, accuracy: 1e-6)
    }

    func testIdenticalImagesHaveNoComponents() {
        let r = Raster(width: 50, height: 50, channels: 3, fill: 0.5)
        let fp = [Bool](repeating: false, count: 2500)
        XCTAssertTrue(Collateral.changedComponents(input: r, output: r, footprint: fp).isEmpty)
    }
}

final class VerifierTests: XCTestCase {
    func raster(_ p: Plane) -> Raster { Raster(width: p.width, height: p.height, channels: 1, data: p.data) }

    func setup() -> (FrameInputs, FrameInputs, LabelSet) {
        var input = flatPlane(400, 250, noise: 0.002, seed: 1)
        paintLine(&input, from: Point(x: 40, y: 100), to: Point(x: 340, y: 150), width: 8, amplitude: 0.3)
        let gone = flatPlane(400, 250, noise: 0.002, seed: 2)
        let obj = LabelObject(id: "o1", class: .airplane, points: [[40, 100], [340, 150]], width: 8, confirmed: true)
        let draft = LabelObject(id: "draft", class: .airplane, points: [[10, 10], [200, 10]], width: 8, confirmed: false)
        let labels = LabelSet(frames: ["f.tif": [obj, draft]], complete: true)
        return (FrameInputs(name: "f.tif", input: raster(input), output: raster(gone)),
                FrameInputs(name: "f.tif", input: raster(input), output: raster(input)), labels)
    }

    func thresholds() -> Thresholds {
        var t = Thresholds()
        t.removed_max = Threshold(value: 0.2, measured: "synthetic test")
        return t
    }

    func testRemovedPassesAndKeptTrailFails_ignoringDrafts() throws {
        let (removed, kept, labels) = setup()
        var o = VerifyOptions(); o.expect = [.airplane: .removed]; o.reportOnly = false
        let (good, _) = try Verifier.verify(frames: [removed], labels: labels, options: o, thresholds: thresholds(), baseline: nil)
        XCTAssertTrue(good.summary.ok)
        XCTAssertEqual(good.summary.objects, 1, "unconfirmed objects are not checked")
        let (bad, crops) = try Verifier.verify(frames: [kept], labels: labels, options: o, thresholds: thresholds(), baseline: nil)
        XCTAssertFalse(bad.summary.ok)
        XCTAssertEqual(bad.objects[0].status, "fail")
        XCTAssertEqual(crops.count, 1)
    }

    func testReportOnlyWithoutThresholdsStillReports() throws {
        let (_, kept, labels) = setup()
        var o = VerifyOptions(); o.expect = [.airplane: .removed]; o.reportOnly = true
        let (r, _) = try Verifier.verify(frames: [kept], labels: labels, options: o, thresholds: Thresholds(), baseline: nil)
        XCTAssertTrue(r.summary.ok)
        XCTAssertEqual(r.objects[0].measurement?.worstRatio ?? 0, 1, accuracy: 1e-6)
    }

    func testEnforcingWithoutThresholdsIsBadInput() {
        let (_, kept, labels) = setup()
        var o = VerifyOptions(); o.expect = [.airplane: .removed]; o.reportOnly = false
        XCTAssertThrowsError(try Verifier.verify(frames: [kept], labels: labels, options: o, thresholds: Thresholds(), baseline: nil))
    }

    func testBaselineRatchet() throws {
        let (removed, kept, labels) = setup()
        var o = VerifyOptions(); o.expect = [.airplane: .removed]; o.reportOnly = false
        o.dataset = "ds"; o.cleanMethod = "selective"
        let base = Baseline(entries: [BaselineEntry(dataset: "ds", frame: "f.tif", object: "o1", cleanMethod: "selective", worstRatio: 1, date: "2026-10-14")])
        let (known, _) = try Verifier.verify(frames: [kept], labels: labels, options: o, thresholds: thresholds(), baseline: base)
        XCTAssertTrue(known.summary.ok); XCTAssertEqual(known.objects[0].status, "knownFailure")
        let (fixed, _) = try Verifier.verify(frames: [removed], labels: labels, options: o, thresholds: thresholds(), baseline: base)
        XCTAssertFalse(fixed.summary.ok)
        XCTAssertTrue(fixed.objects[0].detail?.contains("removal-baseline.json") ?? false)
        let (regress, _) = try Verifier.verify(frames: [kept], labels: labels, options: o, thresholds: thresholds(), baseline: Baseline())
        XCTAssertFalse(regress.summary.ok)
    }

    func testFaintObjectsAreReportedNotRequired() throws {
        let (_, kept, labels) = setup()    // the trail has contrast 0.3 and is left in place
        var o = VerifyOptions(); o.expect = [.airplane: .removed]; o.reportOnly = false
        var t = thresholds(); t.min_required_contrast = Threshold(value: 0.5, measured: "synthetic test")
        let (r, _) = try Verifier.verify(frames: [kept], labels: labels, options: o, thresholds: t, baseline: nil)
        XCTAssertTrue(r.summary.ok)
        XCTAssertEqual(r.objects[0].status, "faint")
        XCTAssertEqual(r.summary.faintSkipped, 1)
        t.min_required_contrast = Threshold(value: 0.1, measured: "synthetic test")
        let (r2, _) = try Verifier.verify(frames: [kept], labels: labels, options: o, thresholds: t, baseline: nil)
        XCTAssertFalse(r2.summary.ok)
    }

    func testBaselinedCollateralFrameIsReportedNotCounted() throws {
        // output differs from input in a blob far from the label, on frame f.tif
        let (_, clean, labels) = setup()      // output identical to input
        var changed = clean
        for y in 200..<210 { for x in 300..<310 { changed.output.data[y * 400 + x] += 0.3 } }
        var o = VerifyOptions(); o.unchangedOutside = true; o.reportOnly = false
        o.cleanMethod = "selective"; o.inputIsLossless = true; o.dataset = "ds"
        var t = Thresholds(); t.unchanged_outside_max_area = Threshold(value: 10, measured: "synthetic test")
        let (r0, _) = try Verifier.verify(frames: [changed], labels: labels, options: o, thresholds: t, baseline: nil)
        XCTAssertFalse(r0.summary.ok)
        let base = Baseline(collateral: [CollateralBaselineEntry(dataset: "ds", frame: "f.tif", cleanMethod: "selective", area: 100, bug: "BUG-001", date: nil)])
        let (r1, _) = try Verifier.verify(frames: [changed], labels: labels, options: o, thresholds: t, baseline: base)
        XCTAssertTrue(r1.summary.ok)
        XCTAssertEqual(r1.collateralKnown["f.tif"], 100)
        XCTAssertEqual(r1.collateralArea, 0)
        // once the frame is clean the stale entry fails the run
        let (r2, _) = try Verifier.verify(frames: [clean], labels: labels, options: o, thresholds: t, baseline: base)
        XCTAssertFalse(r2.summary.ok)
        XCTAssertEqual(r2.collateralFixed, ["f.tif"])
    }

    func testPassRuleUsesTheMedianStretchNotTheWorst() throws {
        // 6 stretches; only one is left in place (ratio ~1), the other five are gone
        var input = flatPlane(400, 250, noise: 0.001)
        paintLine(&input, from: Point(x: 40, y: 100), to: Point(x: 340, y: 150), width: 8, amplitude: 0.4)
        var output = flatPlane(400, 250, noise: 0.001, seed: 9)
        paintLine(&output, from: Point(x: 150, y: 118.333), to: Point(x: 190, y: 125), width: 8, amplitude: 0.4)
        let labels = LabelSet(frames: ["f.tif": [LabelObject(id: "o", class: .airplane, points: [[40, 100], [340, 150]], width: 8, confirmed: true)]])
        var o = VerifyOptions(); o.expect = [.airplane: .removed]; o.reportOnly = false
        let (r, _) = try Verifier.verify(frames: [FrameInputs(name: "f.tif", input: raster(input), output: raster(output))],
                                         labels: labels, options: o, thresholds: thresholds(), baseline: nil)
        XCTAssertGreaterThan(r.objects[0].measurement?.worstRatio ?? 0, 0.8)
        XCTAssertLessThan(r.objects[0].measurement?.medianRatio ?? 1, 0.2)
        XCTAssertEqual(r.objects[0].status, "pass")
    }

    func testAggregateModeJudgesTheFractionAndUnmeasurableCanBeSkipped() throws {
        let (removed, kept, _) = setup()
        // two objects on the same frame: one real trail, one on empty sky (unmeasurable)
        let good = LabelObject(id: "good", class: .airplane, points: [[40, 100], [340, 150]], width: 8, confirmed: true)
        let ghost = LabelObject(id: "ghost", class: .airplane, points: [[10, 200], [300, 220]], width: 8, confirmed: true)
        let labels = LabelSet(frames: ["f.tif": [good, ghost]])
        var o = VerifyOptions(); o.expect = [.airplane: .removed]; o.reportOnly = false; o.aggregate = true; o.skipUnmeasurable = true
        var t = thresholds(); t.removed_fraction_min = Threshold(value: 0.7, measured: "synthetic test")
        let (r1, _) = try Verifier.verify(frames: [removed], labels: labels, options: o, thresholds: t, baseline: nil)
        XCTAssertTrue(r1.summary.ok)
        XCTAssertEqual(r1.summary.unmeasurableSkipped, 1)
        XCTAssertEqual(r1.summary.passFraction, 1)
        let (r2, _) = try Verifier.verify(frames: [kept], labels: labels, options: o, thresholds: t, baseline: nil)
        XCTAssertFalse(r2.summary.ok)
        XCTAssertEqual(r2.summary.passFraction, 0)
        // without --skip-unmeasurable the ghost is a label error
        o.skipUnmeasurable = false
        let (r3, _) = try Verifier.verify(frames: [removed], labels: labels, options: o, thresholds: t, baseline: nil)
        XCTAssertFalse(r3.summary.ok)
    }

    func testUnchangedOutsideRefusals() {
        let (removed, _, labels) = setup()
        var o = VerifyOptions(); o.unchangedOutside = true; o.reportOnly = true
        o.cleanMethod = "automatic:false"; o.inputIsLossless = true
        XCTAssertThrowsError(try Verifier.verify(frames: [removed], labels: labels, options: o, thresholds: Thresholds(), baseline: nil))
        o.cleanMethod = "selective"; o.inputIsLossless = false
        XCTAssertThrowsError(try Verifier.verify(frames: [removed], labels: labels, options: o, thresholds: Thresholds(), baseline: nil))
        o.inputIsLossless = true
        var incomplete = labels; incomplete.complete = false
        XCTAssertThrowsError(try Verifier.verify(frames: [removed], labels: incomplete, options: o, thresholds: Thresholds(), baseline: nil))
        XCTAssertNoThrow(try Verifier.verify(frames: [removed], labels: labels, options: o, thresholds: Thresholds(), baseline: nil))
    }

    func testBadLabelIsALabelErrorNotAFailOrPass() throws {
        let (_, kept, _) = setup()
        // a "trail" on empty background
        let obj = LabelObject(id: "ghost", class: .airplane, points: [[10, 200], [300, 220]], width: 8, confirmed: true)
        let labels = LabelSet(frames: ["f.tif": [obj]])
        var o = VerifyOptions(); o.expect = [.airplane: .removed]; o.reportOnly = false
        let (r, _) = try Verifier.verify(frames: [kept], labels: labels, options: o, thresholds: thresholds(), baseline: nil)
        XCTAssertEqual(r.objects[0].status, "labelError")
        XCTAssertFalse(r.summary.ok)
    }
}

final class PNGTests: XCTestCase {
    func testSignatureAndChunks() {
        let d = PNG.encode(rgb: [UInt8](repeating: 128, count: 4 * 3 * 3), width: 4, height: 3)
        XCTAssertEqual(Array(d.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // the file ends with the IEND chunk: length 0, "IEND", and its fixed CRC
        XCTAssertEqual(Array(d.suffix(12)), [0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
    }
}
