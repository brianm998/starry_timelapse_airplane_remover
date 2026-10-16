import ArgumentParser
import Foundation
import StarCore

// star-output-verify: the checks behind the Gherkin steps `the run used the requested settings`,
// `every input frame has a processed output frame`, `the output frames keep the input's format, size and bit depth`,
// `the output frames were processed in … mode` and `the output video has one frame per output frame`.
//
// Every subcommand prints a report and exits 1 when a check fails.  `--report-only` prints the measurements and
// exits 0, which is how thresholds are measured before they are set (see thresholds.json).

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Collects findings; `finish` throws a combined failure so the report names every problem, not just the first.
struct Report {
    var lines: [String] = []
    var problems: [String] = []
    mutating func note(_ s: String) { lines.append(s) }
    mutating func problem(_ s: String) { problems.append(s); lines.append("FAIL: \(s)") }

    func finish(reportOnly: Bool, reportPath: String?) throws {
        for l in lines { print(l) }
        if let reportPath {
            let body = ["problems": problems, "lines": lines] as [String: Any]
            if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: reportPath))
            }
        }
        if !problems.isEmpty && !reportOnly {
            throw Failure("\(problems.count) check(s) failed:\n" + problems.map { "  - \($0)" }.joined(separator: "\n"))
        }
    }
}

struct CommonOptions: ParsableArguments {
    @Flag(help: "Print measurements and never fail; used to measure thresholds.")
    var reportOnly = false
    @Option(help: "Also write the report as JSON here.")
    var report: String?
}

let imageExtensions: Set<String> = ["tif", "tiff", "jpg", "jpeg", "png"]

func imageFiles(in dir: String) throws -> [String] {
    let names = try FileManager.default.contentsOfDirectory(atPath: dir)
    return names.filter { !$0.hasPrefix(".") && imageExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
}

struct Thresholds: Decodable {
    struct Auto: Decodable {
        let minChangedFraction: Double
        let minMeanRatio: Double
        let maxMeanRatio: Double
        let maxBlackFraction: Double
        let maxSaturatedFraction: Double
    }
    struct Selective: Decodable {
        /// Per-channel difference, in 8-bit levels, above which a pixel counts as changed (JPEG re-encode noise sits below it).
        let toleranceLevels: Double
        let maxChangedFraction: Double
        let minFramesChanged: Int
    }
    let auto: Auto
    let selective: Selective
}

func loadThresholds(_ path: String?) throws -> Thresholds? {
    guard let path else { return nil }
    return try JSONDecoder().decode(Thresholds.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
}

// MARK: - pixel statistics

struct PairStats {
    var changedFraction = 0.0      // pixels differing by more than the tolerance in any channel
    var meanInput = 0.0
    var meanOutput = 0.0
    var blackFraction = 0.0        // output pixels with every channel 0
    var saturatedFraction = 0.0    // output pixels with every channel at the maximum
}

/// Compares two same-shaped images.  `tolerance` is in units of the image's own bit depth scaled to 8-bit levels.
func compare(_ a: PixelatedImage, _ b: PixelatedImage, toleranceLevels: Double) throws -> PairStats {
    guard a.width == b.width, a.height == b.height, a.componentsPerPixel == b.componentsPerPixel else {
        throw Failure("shape differs: \(a.width)x\(a.height)x\(a.componentsPerPixel) vs \(b.width)x\(b.height)x\(b.componentsPerPixel)")
    }
    let comps = a.componentsPerPixel
    let pixels = a.width * a.height

    func run<T: FixedWidthInteger>(_ x: UnsafeBufferPointer<T>, _ y: UnsafeBufferPointer<T>, maxValue: Double, scale: Double) -> PairStats {
        let tol = toleranceLevels * scale
        var changed = 0, black = 0, saturated = 0
        var sumA = 0.0, sumB = 0.0
        for p in 0..<pixels {
            var differs = false, allBlack = true, allMax = true
            for c in 0..<comps {
                let i = p * comps + c
                let va = Double(x[i]), vb = Double(y[i])
                sumA += va; sumB += vb
                if abs(va - vb) > tol { differs = true }
                if vb != 0 { allBlack = false }
                if vb != maxValue { allMax = false }
            }
            if differs { changed += 1 }
            if allBlack { black += 1 }
            if allMax { saturated += 1 }
        }
        let n = Double(pixels)
        return PairStats(changedFraction: Double(changed) / n,
                         meanInput: sumA / (n * Double(comps)) / scale,
                         meanOutput: sumB / (n * Double(comps)) / scale,
                         blackFraction: Double(black) / n, saturatedFraction: Double(saturated) / n)
    }

    switch (a.imageData, b.imageData) {
    case (.eightBit(let x), .eightBit(let y)):
        return run(x, y, maxValue: 255, scale: 1)
    case (.sixteenBit(let x), .sixteenBit(let y)):
        return run(x, y, maxValue: 65535, scale: 257)
    default:
        throw Failure("bit depth differs")
    }
}

func load(_ path: String) throws -> PixelatedImage {
    guard let image = PixelatedImage(filename: path) else { throw Failure("cannot decode \(path)") }
    return image
}

// MARK: - settings

struct Settings: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "The run's saved config.json has the requested settings.")
    @Option(help: "The run's config.json.") var config: String
    @Option(help: "yes | no") var horizon: String
    @Option(help: "static | moving") var camera: String
    @Option(help: "auto | selective | autoSelective") var clean: String
    @OptionGroup var common: CommonOptions

    func run() throws {
        var r = Report()
        guard let data = FileManager.default.contents(atPath: config),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure("cannot read \(config)")
        }
        func expect(_ name: String, _ got: Any?, _ want: Bool) {
            let shown = (got as? Bool).map { $0 ? "true" : "false" } ?? "missing"
            r.note("\(name) = \(shown) (wanted \(want))")
            if (got as? Bool) != want { r.problem("\(name) is \(shown), the feature asked for \(want)") }
        }
        expect("horizonDetectionEnabled", json["horizonDetectionEnabled"], horizon == "yes")
        expect("tripodHeadWasMoving", json["tripodHeadWasMoving"], camera == "moving")

        // CleanMethod encodes as {"automatic": {"_0": <selective?>}} or {"selective": {}}
        var got = "missing"
        if let m = json["cleanMethod"] as? [String: Any] {
            if m["selective"] != nil { got = "selective" }
            else if let a = m["automatic"] as? [String: Any] { got = (a["_0"] as? Bool) == true ? "autoSelective" : "auto" }
        }
        r.note("cleanMethod = \(got) (wanted \(clean))")
        if got != clean { r.problem("cleanMethod is \(got), the feature asked for \(clean)") }
        try r.finish(reportOnly: common.reportOnly, reportPath: common.report)
    }
}

// MARK: - frames

struct Frames: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Every input frame has an output frame of the same name; the frame count matches the source video.")
    @Option(help: "Directory of input frames.") var inputDir: String
    @Option(help: "Directory of output frames.") var outputDir: String
    @Option(help: "For video input: the source video, whose frame count the input frames must equal.") var video: String?
    @OptionGroup var common: CommonOptions

    func run() throws {
        var r = Report()
        let inputs = try imageFiles(in: inputDir), outputs = Set(try imageFiles(in: outputDir))
        r.note("\(inputs.count) input frames, \(outputs.count) output frames")
        if inputs.isEmpty { r.problem("no input frames in \(inputDir)") }
        let missing = inputs.filter { !outputs.contains($0) }
        if !missing.isEmpty { r.problem("\(missing.count) input frames have no output: \(missing.prefix(5).joined(separator: ", "))") }
        let extra = outputs.subtracting(inputs)
        if !extra.isEmpty { r.problem("\(extra.count) output frames match no input: \(extra.sorted().prefix(5).joined(separator: ", "))") }
        if let video {
            let n = try probeFrameCount(video)
            r.note("source video has \(n) frames")
            if n != inputs.count { r.problem("source video has \(n) frames but \(inputs.count) frames were extracted") }
        }
        try r.finish(reportOnly: common.reportOnly, reportPath: common.report)
    }
}

// MARK: - format

struct Format: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Output frames keep the input's extension, size, channels and bit depth, and decode.")
    @Option var inputDir: String
    @Option var outputDir: String
    @OptionGroup var common: CommonOptions

    func run() throws {
        var r = Report()
        for name in try imageFiles(in: inputDir) {
            let outPath = "\(outputDir)/\(name)"
            guard FileManager.default.fileExists(atPath: outPath) else { continue }   // `frames` reports it
            do {
                let a = try load("\(inputDir)/\(name)"), b = try load(outPath)
                let ad = "\(a.width)x\(a.height) \(a.componentsPerPixel)ch \(a.bitsPerComponent)bit"
                let bd = "\(b.width)x\(b.height) \(b.componentsPerPixel)ch \(b.bitsPerComponent)bit"
                r.note("\(name): input \(ad), output \(bd)")
                if ad != bd { r.problem("\(name): input is \(ad) but output is \(bd)") }
            } catch {
                r.problem("\(name): \(error)")
            }
        }
        try r.finish(reportOnly: common.reportOnly, reportPath: common.report)
    }
}

// MARK: - mode

struct Mode: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "How the output frames were processed: automatic, selective or auto selective.")
    @Option(help: "auto | selective | autoSelective") var mode: String
    @Option var inputDir: String
    @Option var outputDir: String
    @Option(help: "The run's kept temp directory; auto selective needs its outlier data.") var tempDir: String?
    @Option(help: "thresholds.json") var thresholds: String?
    @OptionGroup var common: CommonOptions

    func run() throws {
        var r = Report()
        let th = try loadThresholds(thresholds)
        if th == nil && !common.reportOnly { throw Failure("--thresholds is required unless --report-only") }
        var framesChanged = 0
        for name in try imageFiles(in: inputDir) {
            let outPath = "\(outputDir)/\(name)"
            guard FileManager.default.fileExists(atPath: outPath) else { continue }
            let a = try load("\(inputDir)/\(name)"), b = try load(outPath)
            let tol = mode == "selective" ? (th?.selective.toleranceLevels ?? 0) : 0
            let s = try compare(a, b, toleranceLevels: tol)
            let meanRatio = s.meanInput > 0 ? s.meanOutput / s.meanInput : 0
            r.note(String(format: "%@: changed=%.5f meanRatio=%.4f black=%.5f saturated=%.5f", name, s.changedFraction, meanRatio, s.blackFraction, s.saturatedFraction))
            if s.changedFraction > 0 { framesChanged += 1 }
            guard let th else { continue }
            switch mode {
            case "auto", "autoSelective":
                let t = th.auto
                if s.changedFraction < t.minChangedFraction { r.problem("\(name): only \(s.changedFraction) of pixels changed, an automatic clean recomputes nearly all (min \(t.minChangedFraction))") }
                if meanRatio < t.minMeanRatio || meanRatio > t.maxMeanRatio { r.problem("\(name): mean brightness ratio \(meanRatio) outside \(t.minMeanRatio)...\(t.maxMeanRatio)") }
                if s.blackFraction > t.maxBlackFraction { r.problem("\(name): \(s.blackFraction) of the output is black (max \(t.maxBlackFraction))") }
                if s.saturatedFraction > t.maxSaturatedFraction { r.problem("\(name): \(s.saturatedFraction) of the output is saturated (max \(t.maxSaturatedFraction))") }
            case "selective":
                if s.changedFraction > th.selective.maxChangedFraction { r.problem("\(name): \(s.changedFraction) of pixels changed, selective paints only trails (max \(th.selective.maxChangedFraction))") }
            default:
                throw Failure("unknown --mode \(mode)")
            }
        }
        if mode == "selective", let th {
            r.note("\(framesChanged) frames changed")
            if framesChanged < th.selective.minFramesChanged { r.problem("only \(framesChanged) frames changed, need at least \(th.selective.minFramesChanged): selective removed nothing") }
        }
        if mode == "autoSelective" {
            guard let tempDir else { throw Failure("--temp-dir is required for autoSelective") }
            let dir = "\(tempDir)/auto-selective-processed"
            let n = (try? FileManager.default.contentsOfDirectory(atPath: dir).filter { !$0.hasPrefix(".") }.count) ?? 0
            r.note("\(dir): \(n) files")
            if n == 0 { r.problem("no outlier data under \(dir): the run did not process auto selectively") }
        }
        try r.finish(reportOnly: common.reportOnly, reportPath: common.report)
    }
}

// MARK: - video

func probeFrameCount(_ video: String) throws -> Int {
    let out = try runTool(ToolPaths.ffprobe, ["-v", "error", "-count_frames", "-select_streams", "v:0",
                                              "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", video])
    guard let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw Failure("ffprobe gave no frame count for \(video): \(out)") }
    return n
}

func runTool(_ exe: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { throw Failure("cannot run \(exe): \(error). Set \(ToolPaths.directoryOverrideVariable).") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw Failure("\(exe) exited \(p.terminationStatus)") }
    return String(decoding: data, as: UTF8.self)
}

struct VideoCheck: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "video", abstract: "The output video has one frame per output frame, at the right size, rate and codec.")
    @Option(help: "The video file the client said it wrote.") var video: String
    @Option var outputDir: String
    @Option(help: "Expected codec name as ffprobe prints it, e.g. prores or h264.") var codec: String?
    @Option(help: "Expected frame rate as ffprobe prints it, e.g. 30/1.") var frameRate: String?
    @OptionGroup var common: CommonOptions

    func run() throws {
        var r = Report()
        guard FileManager.default.fileExists(atPath: video) else { throw Failure("no video at \(video)") }
        let frames = try imageFiles(in: outputDir)
        guard let sample = frames.first else { throw Failure("no output frames in \(outputDir)") }
        let image = try load("\(outputDir)/\(sample)")
        let csv = try runTool(ToolPaths.ffprobe, ["-v", "error", "-count_frames", "-select_streams", "v:0", "-show_entries",
                                                 "stream=nb_read_frames,width,height,codec_name,r_frame_rate", "-of", "csv=p=0", video])
        // ffprobe orders the fields codec_name,width,height,r_frame_rate,nb_read_frames
        let f = csv.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").map(String.init)
        guard f.count == 5 else { throw Failure("unexpected ffprobe output: \(csv)") }
        r.note("video: codec \(f[0]) \(f[1])x\(f[2]) at \(f[3]), \(f[4]) frames; \(frames.count) output frames of \(image.width)x\(image.height)")
        if Int(f[4]) != frames.count { r.problem("video has \(f[4]) frames, expected \(frames.count)") }
        if Int(f[1]) != image.width || Int(f[2]) != image.height { r.problem("video is \(f[1])x\(f[2]), frames are \(image.width)x\(image.height)") }
        if let codec, f[0] != codec { r.problem("video codec is \(f[0]), expected \(codec)") }
        if let frameRate, f[3] != frameRate { r.problem("video frame rate is \(f[3]), expected \(frameRate)") }
        try r.finish(reportOnly: common.reportOnly, reportPath: common.report)
    }
}

@main
struct StarOutputVerify: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "star-output-verify",
        abstract: "Checks what a Gherkin scenario run produced.",
        subcommands: [Settings.self, Frames.self, Format.self, Mode.self, VideoCheck.self])
}
