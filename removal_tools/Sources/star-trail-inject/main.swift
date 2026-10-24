import ArgumentParser
import Foundation
import RemovalCore
import RemovalIO

/// Run once to BUILD a synthetic dataset; never at test time. Same spec + seed + base = same bytes.
@main
struct StarTrailInject: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "star-trail-inject",
        abstract: "Draws satellites, airplanes and meteors into a clean base sequence with an exact answer key.",
        discussion: "Writes <out>/base (unchanged copy), <out>/injected (16-bit TIFF) and <out>/labels.json (confirmed: true).")

    @Option(help: "Directory of a clean, lossless base sequence.") var base: String
    @Option(help: "Output dataset directory.") var out: String
    @Option(help: "Spec JSON (InjectionSpec). Defaults to the standard SNR sweep.") var spec: String?
    @Flag(help: "Declare the base clean, which makes labels.json \"complete\": true. Only after proving it with --unchanged-outside.")
    var baseIsClean = false

    func run() throws {
        do { try build() }
        catch let e as VerifyError { FileHandle.standardError.write(Data("star-trail-inject: \(e)\n".utf8)); throw ExitCode(2) }
    }

    func build() throws {
        let sp = try spec.map { try JSONDecoder().decode(InjectionSpec.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) } ?? InjectionSpec()
        let files = try ImageIO.imageFiles(in: base)
        guard files.count >= 2 else { throw VerifyError.badInput("base needs at least 2 frames") }
        let fm = FileManager.default
        for d in ["base", "injected"] { try fm.createDirectory(atPath: (out as NSString).appendingPathComponent(d), withIntermediateDirectories: true) }

        let first = try ImageIO.load((base as NSString).appendingPathComponent(files[0]))
        guard first.bitDepth == 16 else { throw VerifyError.badInput("base must be 16-bit lossless (TIFF/PNG)") }
        let planned = TrailInjection.plan(spec: sp, frames: files.count, width: first.raster.width, height: first.raster.height)

        var labels = LabelSet(frames: [:], sky: nil, complete: baseIsClean ? true : nil)
        var injected: [InjectedObject] = []
        for (i, name) in files.enumerated() {
            let src = (base as NSString).appendingPathComponent(name)
            let dst = (out as NSString).appendingPathComponent("base/\(name)")
            if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
            try fm.copyItem(atPath: src, toPath: dst)       // an unchanged copy, byte for byte
            var (raster, _) = try ImageIO.load(src)
            let bg = raster.brightness
            let sigma = Stats.madSigma(bg.minus(StarCheck.blockMedianBackground(bg)).data)
            var objs: [LabelObject] = []
            for o in planned where o.frame == i {
                let label = TrailInjection.render(o, into: &raster, sigma: sigma)
                objs.append(label)
                injected.append(InjectedObject(frame: i, label: label, snr: o.snr))
            }
            labels.frames[name] = objs
            try ImageIO.save(raster, to: (out as NSString).appendingPathComponent("injected/\(name)"), bitDepth: 16)
        }
        labels.frames = labels.frames.filter { !$0.value.isEmpty }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(labels).write(to: URL(fileURLWithPath: (out as NSString).appendingPathComponent("labels.json")))
        try enc.encode(["spec": sp]).write(to: URL(fileURLWithPath: (out as NSString).appendingPathComponent("injection-spec.json")))
        print("injected \(injected.count) objects into \(files.count) frames → \(out)")
    }
}
