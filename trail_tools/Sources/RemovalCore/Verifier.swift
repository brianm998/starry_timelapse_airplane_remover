import Foundation

public struct FrameInputs {
    public var name: String            // input file name, the label key
    public var input: Raster
    public var output: Raster
    public var base: Raster?           // Star's output on the un-injected base (differential mode)
    public init(name: String, input: Raster, output: Raster, base: Raster? = nil) {
        self.name = name; self.input = input; self.output = output; self.base = base
    }
}

public struct VerifyOptions: Sendable {
    public var expect: [TrailClass: Expectation] = [:]
    public var stars = false
    public var unchangedOutside = false
    public var differential = false
    /// Judge the fraction of measurable objects that pass (thresholds.removed_fraction_min) instead of every object. For
    /// classifier-dependent modes whose per-object verdicts differ between platforms while the totals do not.
    public var aggregate = false
    /// Objects too faint to measure are reported and skipped instead of failing as label errors. For hand-labelled real
    /// data that deliberately includes faint streaks; synthetic datasets keep the strict default.
    public var skipUnmeasurable = false
    /// "<frame base name>|<object id>" of objects that must be removed whatever the aggregate fraction says.
    public var pins: Set<String> = []
    /// Judge only the pinned objects: per-object and fraction failures are reported but do not fail the run. For `selective`, which
    /// leaves most faint labelled streaks alone by design.
    public var pinsOnly = false
    public var reportOnly = true
    public var dataset = ""
    public var cleanMethod = ""
    /// For --unchanged-outside validity: whether the input is lossless and the method is selective.
    public var inputIsLossless = false
    public init() {}

    public enum Expectation: String, Sendable { case removed, kept }

    public static func parseExpect(_ s: String) throws -> [TrailClass: Expectation] {
        var out: [TrailClass: Expectation] = [:]
        for part in s.split(separator: ",") {
            let kv = part.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, let c = TrailClass(rawValue: kv[0]), let e = Expectation(rawValue: kv[1]) else {
                throw VerifyError.badInput("bad --expect entry '\(part)' (want class=removed|kept)")
            }
            out[c] = e
        }
        return out
    }
}

public struct ObjectReport: Codable, Sendable {
    public var frame: String
    public var id: String
    public var `class`: TrailClass
    public var expectation: String
    public var measurement: TrailMeasurement?
    /// pass, fail, labelError, or (without thresholds) reported
    public var status: String
    public var baseline: Baseline.Outcome?
    public var detail: String?
    public var crop: String?
    /// Why Star left this object in (only with `--temp`: a `-w --keep-temp-files` run's decision data). Diagnosis only: never changes pass/fail.
    public var diagnosis: String?
}

public struct Summary: Codable, Sendable {
    public var objects = 0
    public var passed = 0
    public var failed = 0
    public var labelErrors = 0
    public var unmeasurableSkipped = 0
    /// Pinned objects that were checked / that were not removed.
    public var pinsChecked = 0
    public var pinsFailed = 0
    /// passed / (passed + failed), the aggregate-mode statistic.
    public var passFraction: Double?
    public var knownFailures = 0
    public var faintSkipped = 0
    public var unmeasurableObjects = 0
    public var reportOnly = true
    public var ok = true
}

public struct Report: Codable, Sendable {
    public var summary = Summary()
    public var objects: [ObjectReport] = []
    public var stars: [String: StarMeasurement] = [:]
    public var starsStatus: String?
    public var collateral: [String: [ChangedComponent]] = [:]
    public var collateralArea = 0
    /// Frames listed in the baseline's `collateral` section: area per frame, not counted in `collateralArea`.
    public var collateralKnown: [String: Int] = [:]
    public var collateralFixed: [String] = []
    public var collateralStatus: String?
    public var differential: [String: DifferentialFrame] = [:]
    public var messages: [String] = []
}

public struct DifferentialFrame: Codable, Sendable {
    public var outsideFraction: Double
    public var sigma: Double
    public var status: String?
}

public enum Verifier {
    /// Returns the report and the crops (file name → PNG) for failing objects and collateral components.
    public static func verify(frames: [FrameInputs], labels: LabelSet, options: VerifyOptions,
                              thresholds: Thresholds, baseline: Baseline?) throws -> (Report, [String: Data]) {
        var report = Report()
        var crops: [String: Data] = [:]
        report.summary.reportOnly = options.reportOnly

        if options.unchangedOutside {
            guard options.cleanMethod == "selective" else {
                throw VerifyError.badInput("--unchanged-outside is only valid for the selective clean method (got '\(options.cleanMethod)')")
            }
            guard options.inputIsLossless else {
                throw VerifyError.badInput("--unchanged-outside needs lossless input (16-bit TIFF/PNG): JPEG is re-encoded on output")
            }
            guard labels.complete == true else {
                throw VerifyError.badInput("--unchanged-outside needs a label set with \"complete\": true")
            }
        }
        if options.differential && frames.contains(where: { $0.base == nil }) {
            throw VerifyError.badInput("differential mode needs a base output for every frame")
        }

        let missing = thresholds.missing(
            forRemoved: options.expect.values.contains(.removed), kept: options.expect.values.contains(.kept),
            stars: options.stars, unchanged: options.unchangedOutside, differential: options.differential, aggregate: options.aggregate)
        if !missing.isEmpty && !options.reportOnly {
            throw VerifyError.badInput("thresholds not set (they come from Phase 4 measurements; use --report-only until then): \(missing.joined(separator: ", "))")
        }
        if !missing.isEmpty { report.messages.append("thresholds not set: \(missing.joined(separator: ", ")); reporting only") }

        let removedMax = thresholds.removed_max?.value
        let keptMin = thresholds.kept_min?.value
        let sky = labels.skyPolygon

        for f in frames {
            guard f.input.width == f.output.width, f.input.height == f.output.height else {
                throw VerifyError.badInput("\(f.name): input and output sizes differ")
            }
            let objects = (labels.frames[f.name] ?? []).filter(\.confirmed)
            let inB = f.input.brightness, outB = f.output.brightness
            let baseB = f.base?.brightness
            let checked = objects.filter { options.expect[$0.class] != nil }

            for o in checked {
                let exp = options.expect[o.class]!
                var rep = ObjectReport(frame: f.name, id: o.id, class: o.class, expectation: exp.rawValue,
                                       measurement: nil, status: "reported", baseline: nil, detail: nil, crop: nil, diagnosis: nil)
                // differential mode compares output with the base output; the injected contrast is the input's.
                let m = TrailCheck.measure(input: inB, output: baseB.map { outB.minus($0) } ?? outB, object: o)
                rep.measurement = m
                report.summary.objects += 1
                if m.measurableFraction < 0.8 && options.skipUnmeasurable {
                    rep.status = "unmeasurable"
                    rep.detail = String(format: "only %.0f%% of the length is measurable in the input: skipped", m.measurableFraction * 100)
                    report.summary.unmeasurableSkipped += 1
                    report.objects.append(rep)
                    continue
                }
                if m.measurableFraction < 0.8 {
                    rep.status = "labelError"
                    rep.detail = String(format: "only %.0f%% of the length is measurable in the input: bad label", m.measurableFraction * 100)
                    report.summary.labelErrors += 1
                    report.summary.unmeasurableObjects += 1
                    report.objects.append(rep)
                    continue
                }
                let ratios = m.stretches.compactMap(\.ratio)
                let median = m.medianRatio ?? .nan
                if exp == .removed, let floor = thresholds.min_required_contrast?.value {
                    let c = Stats.median(m.stretches.filter(\.measurable).map { Float($0.inputContrast) })
                    if Double(c) < floor {
                        rep.status = "faint"
                        rep.detail = String(format: "input contrast %.4f is below min_required_contrast %.4f: reported, not required", Double(c), floor)
                        report.summary.faintSkipped += 1
                        report.objects.append(rep)
                        continue
                    }
                }
                var passed: Bool?
                switch exp {
                case .removed: if let t = removedMax { passed = median <= t }
                case .kept: if let t = keptMin { passed = median >= t }
                }
                if exp == .removed, options.pins.contains("\(LabelSet.baseName(f.name))|\(o.id)"), let t = removedMax {
                    report.summary.pinsChecked += 1
                    if median > t {
                        report.summary.pinsFailed += 1
                        rep.detail = (rep.detail.map { $0 + "; " } ?? "") + String(format: "pinned object not removed (median ratio %.3f > %.3f)", median, t)
                    }
                }
                if let passed {
                    var status = passed ? "pass" : "fail"
                    if let baseline, !options.differential {
                        let oc = baseline.outcome(dataset: options.dataset, frame: f.name, object: o.id,
                                                  cleanMethod: options.cleanMethod, passed: passed)
                        rep.baseline = oc
                        switch oc {
                        case .pass: break
                        case .knownFailure: status = "knownFailure"; report.summary.knownFailures += 1
                        case .regression: break
                        case .fixed:
                            status = "fail"
                            rep.detail = "now passes: remove it from removal-baseline.json"
                        }
                    }
                    rep.status = status
                    if status == "pass" { report.summary.passed += 1 }
                    else if status == "fail" { report.summary.failed += 1 }
                    if !passed {
                        let poly = o.polyline
                        let b = Geometry.bounds(of: poly, margin: o.width / 2 + 40, width: inB.width, height: inB.height)
                        guard b.x1 > b.x0, b.y1 > b.y0 else { report.objects.append(rep); continue }
                        let name = "\(LabelSet.baseName(f.name))_\(o.id).png"
                        crops[name] = Crops.sideBySide(input: inB, output: outB, x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1)
                        rep.crop = name
                    }
                }
                report.objects.append(rep)
            }

            if options.stars {
                let all = labels.frames[f.name] ?? []
                let polys = all.map { ($0.polyline, 40.0) }
                let (sm, _) = StarCheck.measure(input: inB, output: baseB ?? outB) { x, y in
                    if let sky, !Geometry.contains(polygon: sky, Point(x: Double(x), y: Double(y))) { return false }
                    let p = Point(x: Double(x), y: Double(y))
                    return !polys.contains { Geometry.distance(from: p, toPolyline: $0.0) < $0.1 }
                }
                report.stars[f.name] = sm
            }

            if options.unchangedOutside {
                let fp = Collateral.footprint(width: inB.width, height: inB.height, objects: objects, margin: 10)
                let comps = Collateral.changedComponents(input: f.input, output: f.output, footprint: fp)
                report.collateral[f.name] = comps
                let area = comps.reduce(0) { $0 + $1.area }
                if let baseline, baseline.collateral.contains(where: { $0.dataset == options.dataset && $0.frame == f.name && $0.cleanMethod == options.cleanMethod }) {
                    report.collateralKnown[f.name] = area
                } else {
                    report.collateralArea += area
                }
                for (i, c) in comps.prefix(8).enumerated() {
                    let m = 12
                    let name = "\(LabelSet.baseName(f.name))_changed\(i).png"
                    crops[name] = Crops.sideBySide(input: inB, output: outB, x0: max(0, c.minX - m), y0: max(0, c.minY - m),
                                                   x1: min(inB.width - 1, c.maxX + m), y1: min(inB.height - 1, c.maxY + m))
                }
            }

            if options.differential, let baseB {
                let fp = Collateral.footprint(width: inB.width, height: inB.height, objects: objects, margin: 10)
                let (frac, sigma) = Collateral.differentialOutside(output: outB, base: baseB, footprint: fp)
                var status: String?
                if let t = thresholds.differential_outside_max?.value { status = frac <= t ? "pass" : "fail" }
                report.differential[f.name] = DifferentialFrame(outsideFraction: frac, sigma: sigma, status: status)
            }
        }

        if options.stars {
            let ms = report.stars.values
            if let lo = thresholds.stars_median_min?.value, let hi = thresholds.stars_median_max?.value,
               let lost = thresholds.stars_lost_max?.value {
                let ok = ms.allSatisfy { $0.medianRatio >= lo && $0.medianRatio <= hi && $0.fractionBelowHalf <= lost }
                report.starsStatus = ok ? "pass" : "fail"
            }
        }
        if options.unchangedOutside, let t = thresholds.unchanged_outside_max_area?.value {
            report.collateralStatus = Double(report.collateralArea) <= t ? "pass" : "fail"
            // a baselined frame that is now within the limit has been fixed (or labelled): the entry must go
            for (frame, area) in report.collateralKnown.sorted(by: { $0.key < $1.key }) where Double(area) <= t {
                report.collateralFixed.append(frame)
                report.messages.append("\(frame): unchanged-outside area \(area) is now within the limit: remove it from removal-baseline.json")
                report.collateralStatus = "fail"
            }
        }

        let judged = report.summary.passed + report.summary.failed
        if judged > 0 { report.summary.passFraction = Double(report.summary.passed) / Double(judged) }
        var ok = report.summary.failed == 0 && report.summary.labelErrors == 0
        if options.aggregate, let t = thresholds.removed_fraction_min?.value {
            ok = (report.summary.passFraction ?? 0) >= t && report.summary.labelErrors == 0
        }
        if options.pinsOnly && !options.expect.isEmpty { ok = report.summary.labelErrors == 0 && report.summary.pinsChecked > 0 }
        if report.summary.pinsFailed > 0 { ok = false }
        if report.starsStatus == "fail" || report.collateralStatus == "fail" { ok = false }
        if report.differential.values.contains(where: { $0.status == "fail" }) { ok = false }
        report.summary.ok = ok
        return (report, crops)
    }
}
