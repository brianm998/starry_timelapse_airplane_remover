import ArgumentParser
import Foundation
import RemovalCore
import RemovalIO

@main
struct StarRemovalVerify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "star-removal-verify",
        abstract: "Checks that labelled airplanes/satellites are gone from Star's output, and nothing else was damaged.",
        discussion: "Exit 0 = pass, 1 = failure, 2 = bad input (labels, missing frames, wrong mode).")

    @Option(help: "Directory of input frames.") var input: String
    @Option(help: "Directory of Star's output frames (matched to input by base name).") var output: String
    @Option(help: "labels.json") var labels: String
    @Option(help: "e.g. \"airplane=removed,satellite=removed\"") var expect: String = ""
    @Flag(help: "Check the stars as a flux-ratio distribution.") var stars = false
    @Flag(help: "Report everything that changed outside the labelled trails (selective + lossless input + complete labels only).")
    var unchangedOutside = false
    @Option(help: "Star's output on the un-injected base: differential mode for synthetic datasets.") var baseOutput: String?
    @Option(help: "The star_temp directory of a `-w --keep-temp-files` run (diagnostics only).") var temp: String?
    @Option(help: "gherkin/removal-thresholds.json") var thresholds: String?
    @Option(help: "gherkin/removal-baseline.json (real-data ratchet).") var baseline: String?
    @Option(help: "Dataset name, the baseline key.") var dataset: String = ""
    @Option(help: "Clean method used: selective | automatic:true | automatic:false.") var cleanMethod: String = ""
    @Option(help: "Where to write report.json.") var report: String
    @Option(help: "Directory for failure crops.") var crops: String
    @Flag(help: "Always exit 0 and print the numbers. The only mode usable until thresholds are measured.")
    var reportOnly = false

    func run() throws {
        do { try execute() }
        catch let e as VerifyError { FileHandle.standardError.write(Data("star-removal-verify: \(e)\n".utf8)); throw ExitCode(2) }
    }

    func execute() throws {
        var opts = VerifyOptions()
        opts.expect = try VerifyOptions.parseExpect(expect)
        opts.stars = stars
        opts.unchangedOutside = unchangedOutside
        opts.differential = baseOutput != nil
        opts.reportOnly = reportOnly
        opts.dataset = dataset
        opts.cleanMethod = cleanMethod

        let labelSet = try LabelSet.load(from: URL(fileURLWithPath: labels))
        let th = try thresholds.map { try Thresholds.load(from: URL(fileURLWithPath: $0)) } ?? Thresholds()
        let bl = try baseline.map { try Baseline.load(from: URL(fileURLWithPath: $0)) }

        let outFiles = try ImageIO.imageFiles(in: output)
        let baseFiles = try baseOutput.map { try ImageIO.imageFiles(in: $0) } ?? []
        func find(_ files: [String], _ name: String) -> String? {
            files.first { LabelSet.baseName($0) == LabelSet.baseName(name) }
        }

        // Only frames that carry labels need checking, plus every frame when stars are measured.
        var frames: [FrameInputs] = []
        var lossless = true
        for name in try ImageIO.imageFiles(in: input) {
            let labelled = !(labelSet.frames[name] ?? []).filter(\.confirmed).isEmpty
            if !labelled && !stars && !unchangedOutside { continue }
            guard let outName = find(outFiles, name) else {
                throw VerifyError.badInput("no output frame for \(name) in \(output)")
            }
            let (inR, depth) = try ImageIO.load((input as NSString).appendingPathComponent(name))
            let (outR, _) = try ImageIO.load((output as NSString).appendingPathComponent(outName))
            if depth != 16 { lossless = false }
            if ["jpg", "jpeg"].contains((name as NSString).pathExtension.lowercased()) { lossless = false }
            var baseR: Raster?
            if let baseOutput {
                guard let bn = find(baseFiles, name) else { throw VerifyError.badInput("no base output for \(name)") }
                baseR = try ImageIO.load((baseOutput as NSString).appendingPathComponent(bn)).raster
            }
            frames.append(FrameInputs(name: name, input: inR, output: outR, base: baseR))
        }
        if frames.isEmpty { throw VerifyError.badInput("no labelled frames matched the input directory") }
        opts.inputIsLossless = lossless

        let (rep, cropData) = try Verifier.verify(frames: frames, labels: labelSet, options: opts, thresholds: th, baseline: bl)

        try FileManager.default.createDirectory(atPath: crops, withIntermediateDirectories: true)
        for (name, data) in cropData { try data.write(to: URL(fileURLWithPath: (crops as NSString).appendingPathComponent(name))) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(rep).write(to: URL(fileURLWithPath: report))

        printSummary(rep)
        if let temp { print("note: --temp \(temp) decision diagnostics are not implemented yet (see GHERKIN_REMOVAL_VALIDATION_PLAN_RESULT.md)") }
        print("report: \(report)\ncrops: \(crops)")
        if !reportOnly && !rep.summary.ok { throw ExitCode(rep.summary.labelErrors > 0 && rep.summary.failed == 0 ? 2 : 1) }
    }

    func printSummary(_ r: Report) {
        func f(_ d: Double?) -> String { d.map { String(format: "%.3f", $0) } ?? "-" }
        for o in r.objects {
            let m = o.measurement
            print("\(o.frame) \(o.id) [\(o.class.rawValue)=\(o.expectation)] \(o.status)"
                  + " worst=\(f(m?.worstRatio)) best=\(f(m?.bestRatio))"
                  + " removed=\(f(m?.fractionRemoved)) measurable=\(f(m?.measurableFraction))"
                  + (o.detail.map { " — \($0)" } ?? ""))
        }
        for (frame, s) in r.stars.sorted(by: { $0.key < $1.key }) {
            print("\(frame) stars: n=\(s.peaks) median=\(f(s.medianRatio)) p5=\(f(s.p5)) p95=\(f(s.p95)) <0.5=\(f(s.fractionBelowHalf))")
        }
        for (frame, c) in r.collateral.sorted(by: { $0.key < $1.key }) where !c.isEmpty {
            print("\(frame) changed outside labelled trails: \(c.count) components, area \(c.reduce(0) { $0 + $1.area })")
        }
        for (frame, d) in r.differential.sorted(by: { $0.key < $1.key }) {
            print("\(frame) differential outside: \(f(d.outsideFraction)) of pixels > 6σ")
        }
        for m in r.messages { print("note: \(m)") }
        let s = r.summary
        print("summary: objects=\(s.objects) passed=\(s.passed) failed=\(s.failed) labelErrors=\(s.labelErrors) knownFailures=\(s.knownFailures) reportOnly=\(s.reportOnly) ok=\(s.ok)")
    }
}
