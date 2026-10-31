import Foundation

// star-gherkin-gen: turns gherkin/features/*.feature + steps.json + params.json into the generated
// Swift and Kotlin sources every client compiles. See gherkin/README.md.
//
// Only the feature name, tags, scenario name and step keyword/text are taken from the parser, and
// the keyword is trimmed, so the output is identical across gherkin 9.x and current cucumber-gherkin.

struct GenError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Parsed model

struct ParsedStep { let keyword: String; let text: String; let line: Int }
struct ParsedFeature {
    let file: String          // path relative to the repo root, for messages
    let basename: String
    let name: String
    /// The text under the `Feature:` line.
    let description: String
    let tags: [String]
    let scenario: String
    let steps: [ParsedStep]
}

/// A `steps.json` text is literal text, with inline arguments in it: `"<name>"` takes a double-quoted string from the feature
/// (`I click "<id>"` matches `I click "startup.horizon.no"`), `<name:int>` takes a bare integer (`I go to frame <n:int>`).
/// `{placeholder}`s are not arguments: they stay literal in the feature and the runner supplies their values.
enum StepPart { case literal(String), quoted(String), integer(String) }

struct StepDef {
    let caseName: String
    let text: String
    let parts: [StepPart]

    init(caseName: String, text: String) {
        self.caseName = caseName
        self.text = text
        self.parts = parseStepParts(text)
    }

    /// The names of the inline arguments, in order (`id` in `I click "<id>"`).
    var argumentNames: [String] {
        parts.compactMap { part -> String? in
            switch part {
            case .literal: return nil
            case .quoted(let name), .integer(let name): return name
            }
        }
    }

    /// The arguments `featureText` gives this step, or nil when it is not this step. A step with no inline arguments matches only its own text.
    func match(_ featureText: String) -> [String]? {
        var rest = Substring(featureText)
        var args: [String] = []
        for part in parts {
            switch part {
            case .literal(let s):
                guard rest.hasPrefix(s) else { return nil }
                rest = rest.dropFirst(s.count)
            case .quoted:
                guard rest.first == "\"" else { return nil }
                rest = rest.dropFirst()
                guard let end = rest.firstIndex(of: "\"") else { return nil }
                args.append(String(rest[..<end]))
                rest = rest[rest.index(after: end)...]
            case .integer:
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                guard !digits.isEmpty else { return nil }
                args.append(String(digits))
                rest = rest.dropFirst(digits.count)
            }
        }
        return rest.isEmpty ? args : nil
    }
}

func parseStepParts(_ text: String) -> [StepPart] {
    let marker = try! NSRegularExpression(pattern: #""<([a-z][A-Za-z0-9]*)>"|<([a-z][A-Za-z0-9]*):int>"#)
    let ns = text as NSString
    var parts: [StepPart] = []
    var last = 0
    for m in marker.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        if m.range.location > last { parts.append(.literal(ns.substring(with: NSRange(location: last, length: m.range.location - last)))) }
        if m.range(at: 1).location != NSNotFound { parts.append(.quoted(ns.substring(with: m.range(at: 1)))) }
        else { parts.append(.integer(ns.substring(with: m.range(at: 2)))) }
        last = m.range.location + m.range.length
    }
    if last < ns.length { parts.append(.literal(ns.substring(from: last))) }
    return parts
}

/// The step a feature line is, and the arguments it gives.
func lookup(_ s: ParsedStep, in steps: [StepDef]) -> (def: StepDef, args: [String])? {
    for def in steps { if let args = def.match(s.text) { return (def, args) } }
    return nil
}

// MARK: - SHA-256 (Foundation-only: CryptoKit is absent on Linux)

func sha256Hex(_ data: [UInt8]) -> String {
    let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    var msg = data
    let bitLen = UInt64(data.count) * 8
    msg.append(0x80)
    while msg.count % 64 != 56 { msg.append(0) }
    for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }
    func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    for chunk in stride(from: 0, to: msg.count, by: 64) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let o = chunk + i * 4
            w[i] = UInt32(msg[o]) << 24 | UInt32(msg[o + 1]) << 16 | UInt32(msg[o + 2]) << 8 | UInt32(msg[o + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
        h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }
    return h.map { String(format: "%08x", $0) }.joined()
}

// MARK: - Ruby gherkin discovery (ported from Preffect-Mobile's Parser.swift)

/// Where the Ruby `gherkin` CLI may live, in order: $GHERKIN_BIN, the Intel-Homebrew/system gem path,
/// Apple-silicon Homebrew, each Homebrew Ruby's gem bin directory, then whatever is on PATH.
func gherkinCandidates() -> [String] {
    var paths: [String] = []
    let env = ProcessInfo.processInfo.environment
    if let e = env["GHERKIN_BIN"], !e.isEmpty { paths.append(e) }
    paths += ["/usr/local/bin/gherkin", "/opt/homebrew/bin/gherkin"]
    let gems = "/opt/homebrew/lib/ruby/gems"
    let versions = (try? FileManager.default.contentsOfDirectory(atPath: gems)) ?? []
    paths += versions.sorted(by: >).map { "\(gems)/\($0)/bin/gherkin" }
    for dir in (env["PATH"] ?? "").split(separator: ":") { paths.append("\(dir)/gherkin") }
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
}

func run(_ exe: String, _ args: [String]) -> (status: Int32, out: Data, err: Data)? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe()
    // stderr goes to a file, not a pipe: reading two pipes needs threads, and a full one blocks the child.
    let errURL = FileManager.default.temporaryDirectory.appendingPathComponent("star-gherkin-gen-\(UUID().uuidString).err")
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: errURL) }
    guard let errHandle = try? FileHandle(forWritingTo: errURL) else { return nil }
    p.standardOutput = out
    p.standardError = errHandle
    do { try p.run() } catch { return nil }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    try? errHandle.close()
    return (p.terminationStatus, outData, (try? Data(contentsOf: errURL)) ?? Data())
}

/// The first candidate whose `--help` actually runs (system Ruby's gherkin 9.0.0 is present on an
/// Apple-silicon Mac but its x86_64-only protobuf never loads), plus whether it takes `--format`.
func findGherkin() throws -> (path: String, formatArgs: [String]) {
    let candidates = gherkinCandidates()
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
        guard let r = run(c, ["--help"]), r.status == 0 else { continue }
        let help = String(decoding: r.out, as: UTF8.self)
        // cucumber-gherkin >= ~20 dropped --format and writes ndjson by default.
        return (c, help.contains("--format") ? ["--format=ndjson"] : [])
    }
    throw GenError("no working Ruby `gherkin` found; tried: \(candidates.joined(separator: ", "))\nInstall one:\n\n\tgem install cucumber-gherkin\n\nor point $GHERKIN_BIN at it.")
}

// MARK: - Parsing

func parseFeature(at url: URL, root: URL, gherkin: (path: String, formatArgs: [String])) throws -> ParsedFeature {
    let rel = url.path.hasPrefix(root.path + "/") ? String(url.path.dropFirst(root.path.count + 1)) : url.path
    let basename = url.deletingPathExtension().lastPathComponent
    guard let r = run(gherkin.path, ["--no-source", "--no-pickles", "--predictable-ids"] + gherkin.formatArgs + [url.path]) else {
        throw GenError("\(rel): could not launch \(gherkin.path)")
    }
    guard r.status == 0 else {
        throw GenError("\(rel): gherkin exited \(r.status): \(String(decoding: r.err, as: UTF8.self))")
    }

    var feature: [String: Any]?
    for line in String(decoding: r.out, as: UTF8.self).split(whereSeparator: \.isNewline) {
        guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        if let pe = obj["parseError"] as? [String: Any] {
            let loc = (pe["source"] as? [String: Any])?["location"] as? [String: Any]
            throw GenError("\(rel):\(loc?["line"] ?? "?"): \(pe["message"] ?? "parse error")")
        }
        if let doc = obj["gherkinDocument"] as? [String: Any], let f = doc["feature"] as? [String: Any] { feature = f }
    }
    guard let feature else { throw GenError("\(rel): no Feature found") }

    let featureLine = (feature["location"] as? [String: Any])?["line"] as? Int ?? 0
    let tags = (feature["tags"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
    let children = feature["children"] as? [[String: Any]] ?? []

    var scenarios: [[String: Any]] = []
    for child in children {
        if let bg = child["background"] as? [String: Any] {
            throw GenError("\(rel):\(line(of: bg)): Background is not supported in the pilot")
        }
        if let rule = child["rule"] as? [String: Any] {
            throw GenError("\(rel):\(line(of: rule)): Rule is not supported in the pilot")
        }
        if let sc = child["scenario"] as? [String: Any] {
            let keyword = (sc["keyword"] as? String ?? "")
            if keyword.contains("Outline") || keyword.contains("Template") || !((sc["examples"] as? [Any]) ?? []).isEmpty {
                throw GenError("\(rel):\(line(of: sc)): Scenario Outline is not supported in the pilot")
            }
            scenarios.append(sc)
        }
    }
    guard scenarios.count == 1 else {
        let at = scenarios.count > 1 ? line(of: scenarios[1]) : featureLine
        throw GenError("\(rel):\(at): a feature file must hold exactly one Scenario (found \(scenarios.count)); there is no state reset between scenarios")
    }
    let sc = scenarios[0]
    let steps = (sc["steps"] as? [[String: Any]] ?? []).map {
        ParsedStep(keyword: ($0["keyword"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                   text: $0["text"] as? String ?? "",
                   line: line(of: $0))
    }
    return ParsedFeature(file: rel, basename: basename, name: feature["name"] as? String ?? "",
                         description: (feature["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                         tags: tags, scenario: sc["name"] as? String ?? "", steps: steps)
}

func line(of node: [String: Any]) -> Int { (node["location"] as? [String: Any])?["line"] as? Int ?? 0 }

// MARK: - Test data manifest

let dataPrefix = "data:"

/// Names in `test_data/datasets.json`, which is the single source of truth for out-of-repo datasets.
func loadDatasetNames(_ url: URL) throws -> Set<String> {
    guard let data = try? Data(contentsOf: url) else { throw GenError("test_data/datasets.json: cannot read it") }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any], let ds = obj["datasets"] as? [String: Any] else {
        throw GenError("test_data/datasets.json must be {\"release\": …, \"datasets\": {name: {…}}}")
    }
    return Set(ds.keys)
}

/// Fails, with params.json:line, on a `data:<name>` value the manifest does not have.
func checkDataParams(_ params: [String: [String: String]], featureParams: [String: [String: String]], manifest: Set<String>, paramsURL: URL) throws {
    let lines = ((try? String(contentsOf: paramsURL, encoding: .utf8)) ?? "").components(separatedBy: "\n")
    var sections = params
    for (f, v) in featureParams { sections["features.\(f)"] = v }
    for (section, values) in sections.sorted(by: { $0.key < $1.key }) {
        for (key, value) in values.sorted(by: { $0.key < $1.key }) where value.hasPrefix(dataPrefix) {
            let name = String(value.dropFirst(dataPrefix.count))
            guard manifest.contains(name) else {
                let n = lines.firstIndex { $0.contains("\"\(key)\"") && $0.contains(value) }.map { $0 + 1 } ?? 0
                throw GenError("gherkin/params.json:\(n): \(section).\(key) is `\(value)` but test_data/datasets.json has no dataset `\(name)` (has: \(manifest.sorted().joined(separator: ", ")))")
            }
        }
    }
}

// MARK: - Validation

let clientTags: [(tag: String, key: String)] = [("@cli", "cli"), ("@mac-gui", "mac-gui"), ("@desktop", "desktop")]
let stepKeywords = ["Given", "When", "Then", "And", "But"]

func isLowerCamel(_ s: String) -> Bool {
    guard let f = s.first, f.isLowercase, f.isASCII else { return false }
    return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
}

func placeholders(in text: String) -> [String] {
    var result: [String] = []
    var current: String?
    for ch in text {
        if ch == "{" { current = "" }
        else if ch == "}", let c = current { result.append(c); current = nil }
        else if current != nil { current!.append(ch) }
    }
    return result
}

/// Setting steps: exactly one of each group, all before the step that opens or imports the sequence. Runners collect them and
/// apply them when the sequence opens, which is when the GUIs ask.
let settingGroups: [(name: String, cases: Set<String>)] = [
    ("horizon", ["horizonYes", "horizonNo"]),
    ("camera", ["cameraStatic", "cameraMoving"]),
    ("clean method", ["cleanAuto", "cleanSelective", "cleanAutoSelective"]),
]
let openCases: Set<String> = ["openSequence", "importVideo", "importVideoBackground"]

func validateSettings(_ f: ParsedFeature, steps: [StepDef]) throws {
    let cases = f.steps.map { lookup($0, in: steps)?.def.caseName ?? "" }
    guard let openIdx = cases.firstIndex(where: { openCases.contains($0) }) else {
        throw GenError("\(f.file): no step opens the sequence (`I open the sequence …` or `I import the video …`)")
    }
    if cases.filter({ openCases.contains($0) }).count != 1 {
        throw GenError("\(f.file):\(f.steps[openIdx].line): exactly one open or import step is required")
    }
    for g in settingGroups {
        let hits = cases.indices.filter { g.cases.contains(cases[$0]) }
        guard hits.count == 1 else {
            throw GenError("\(f.file):\(hits.dropFirst().first.map { f.steps[$0].line } ?? f.steps[openIdx].line): exactly one \(g.name) step is required (found \(hits.count))")
        }
        if hits[0] > openIdx {
            throw GenError("\(f.file):\(f.steps[hits[0]].line): the \(g.name) step must come before the open or import step")
        }
    }
}

/// A UI feature (`@ui`) is run by the two clients that have a UI, and by both: one on a single client is what the parity plan exists to prevent,
/// so that takes a tag that says it is deliberate. It has no settings steps and need not open a sequence (it may start on the start screen).
func validateUITags(_ f: ParsedFeature) throws {
    let macOnly = f.tags.contains("@ui-mac-gui-only"), desktopOnly = f.tags.contains("@ui-desktop-only")
    guard f.tags.contains("@ui") else {
        if macOnly || desktopOnly { throw GenError("\(f.file): @ui-mac-gui-only and @ui-desktop-only go with @ui") }
        return
    }
    if f.tags.contains("@cli") { throw GenError("\(f.file): a @ui feature has no UI to drive in the cli: remove @cli") }
    let mac = f.tags.contains("@mac-gui"), desktop = f.tags.contains("@desktop")
    if macOnly && desktopOnly { throw GenError("\(f.file): @ui-mac-gui-only and @ui-desktop-only together say nothing runs") }
    if (macOnly || desktopOnly) && f.description.isEmpty {
        throw GenError("\(f.file): a @ui feature for one client says why in the text under its Feature: line")
    }
    if macOnly {
        guard mac && !desktop else { throw GenError("\(f.file): @ui-mac-gui-only wants @mac-gui and not @desktop") }
    } else if desktopOnly {
        guard desktop && !mac else { throw GenError("\(f.file): @ui-desktop-only wants @desktop and not @mac-gui") }
    } else if !(mac && desktop) {
        throw GenError("\(f.file): a @ui feature runs on both clients: it needs @mac-gui and @desktop (or @ui-mac-gui-only / @ui-desktop-only, if one client is deliberate)")
    }
}

/// What a UI step may name: an argument called `id` is an identifier in `gherkin/ui/ids.json` (or in one of its `prefix*` families), one called `key`
/// is a key of the English catalogue, one called `command` is a command of `gherkin/ui/commands.json`, and one called `fixture` is a file of
/// `gherkin/ui/fixtures/prefs/` (without `.json`), and one called `code` is a language of the catalogue (`de`, `pt-BR`). A feature that names a control neither client has is a failure here, not a timeout in a runner.
struct UIReferences {
    let ids: [String]
    let catalogueKeys: Set<String>
    /// The `id`s of `gherkin/ui/commands.json`: what an argument called `command` may name.
    let commandIds: Set<String>
    /// The preference files of `gherkin/ui/fixtures/prefs/`, by name without `.json`: what an argument called `fixture` may name.
    let prefsFixtures: Set<String>
    /// The languages of the catalogue (the files of `StarCore/.../Localizations/` but `languages.json`): what an argument called `code` may name.
    let languages: Set<String>

    func covers(id: String) -> Bool {
        ids.contains { $0.hasSuffix("*") ? id.hasPrefix(String($0.dropLast())) : $0 == id }
    }
}

func loadUIReferences(root: URL) throws -> UIReferences {
    let idsURL = root.appendingPathComponent("gherkin/ui/ids.json")
    guard let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: idsURL)) as? [String: Any], let ids = obj["ids"] as? [String] else {
        throw GenError("gherkin/ui/ids.json must be an object with an \"ids\" array")
    }
    let enURL = root.appendingPathComponent("StarCore/Sources/StarCore/Resources/Localizations/en.json")
    guard let en = try JSONSerialization.jsonObject(with: Data(contentsOf: enURL)) as? [String: String] else {
        throw GenError("the English catalogue (en.json) must be a flat object")
    }
    let commandsURL = root.appendingPathComponent("gherkin/ui/commands.json")
    guard let commands = (try JSONSerialization.jsonObject(with: Data(contentsOf: commandsURL)) as? [String: Any])?["commands"] as? [[String: String]] else {
        throw GenError("gherkin/ui/commands.json must be an object with a \"commands\" array")
    }
    let fixturesURL = root.appendingPathComponent("gherkin/ui/fixtures/prefs")
    let fixtureFiles = (try? FileManager.default.contentsOfDirectory(atPath: fixturesURL.path)) ?? []
    let prefsFixtures = Set(fixtureFiles.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) })
    let languageFiles = (try? FileManager.default.contentsOfDirectory(atPath: enURL.deletingLastPathComponent().path)) ?? []
    let languages = Set(languageFiles.filter { $0.hasSuffix(".json") && $0 != "languages.json" }.map { String($0.dropLast(".json".count)) })
    return UIReferences(ids: ids, catalogueKeys: Set(en.keys), commandIds: Set(commands.compactMap { $0["id"] }), prefsFixtures: prefsFixtures, languages: languages)
}

func validate(_ f: ParsedFeature, steps: [StepDef], defaults: [String: String], featureParams: [String: String], references: UIReferences) throws {
    try validateUITags(f)
    if !f.tags.contains("@ui") { try validateSettings(f, steps: steps) }
    if !isLowerCamel(f.basename) { throw GenError("\(f.file): basename `\(f.basename)` must be lowerCamelCase") }
    if !f.tags.contains("@\(f.basename)") { throw GenError("\(f.file): missing its own tag @\(f.basename)") }
    if f.steps.isEmpty { throw GenError("\(f.file): the scenario has no steps") }
    for s in f.steps {
        guard stepKeywords.contains(s.keyword) else {
            throw GenError("\(f.file):\(s.line): step keyword `\(s.keyword)` is not one of \(stepKeywords.joined(separator: ", "))")
        }
        guard let found = lookup(s, in: steps) else {
            throw GenError("\(f.file):\(s.line): step text has no match in steps.json: \"\(s.text)\"")
        }
        for (name, arg) in zip(found.def.argumentNames, found.args) {
            if name == "id" && !references.covers(id: arg) {
                throw GenError("\(f.file):\(s.line): \"\(arg)\" is not in gherkin/ui/ids.json: a control a step names is one both clients carry (add it there, and to each client)")
            }
            if name == "command" && !references.commandIds.contains(arg) {
                throw GenError("\(f.file):\(s.line): \"\(arg)\" is not a command of gherkin/ui/commands.json")
            }
            if name == "code" && !references.languages.contains(arg) {
                throw GenError("\(f.file):\(s.line): \"\(arg)\" is not a language of the catalogue (a file of StarCore/Sources/StarCore/Resources/Localizations/)")
            }
            if name == "fixture" && !references.prefsFixtures.contains(arg) {
                throw GenError("\(f.file):\(s.line): \"\(arg)\" is not a file of gherkin/ui/fixtures/prefs/ (without .json)")
            }
            if name == "key" && found.def.caseName == "idReads" && !references.catalogueKeys.contains(arg) {
                throw GenError("\(f.file):\(s.line): \"\(arg)\" is not a key of the English catalogue")
            }
        }
        for p in placeholders(in: s.text) where featureParams[p] == nil && defaults[p] == nil {
            throw GenError("\(f.file):\(s.line): {\(p)} has no value for feature \(f.basename) and no default in params.json")
        }
    }
}

// MARK: - Emission

func camelToUpperSnake(_ s: String) -> String {
    var out = ""
    for (i, ch) in s.enumerated() {
        if ch.isUppercase && i > 0 { out.append("_") }
        out.append(contentsOf: String(ch).uppercased())
    }
    return out
}

func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

func swiftString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
func kotlinString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$") + "\""
}

func header(_ hash: String) -> String {
    "// @generated by star-gherkin-gen — do not edit.\n// source-hash: \(hash)\n"
}

func dictLiteral(_ d: [String: String], quote: (String) -> String, indent: String) -> String {
    d.keys.sorted().map { "\(indent)\(quote($0)): \(quote(d[$0]!))" }.joined(separator: ",\n")
}

func keywordCase(_ k: String) -> String { k.lowercased() }

struct Output { let path: String; let content: String }

/// The `data:<name>` datasets a client's features need: every placeholder of every step of every feature tagged for the
/// client, resolved the way a runner does (client override, then default). Sorted, so the file is stable.
func datasetNames(for client: (tag: String, key: String), features: [ParsedFeature], params: [String: [String: String]],
                  featureParams: [String: [String: String]]) -> [String] {
    var names = Set<String>()
    for f in features where f.tags.contains(client.tag) {
        for s in f.steps {
            for p in placeholders(in: s.text) {
                if let v = featureParams[f.basename]?[p] ?? params[client.key]?[p] ?? params["default"]?[p], v.hasPrefix(dataPrefix) {
                    names.insert(String(v.dropFirst(dataPrefix.count)))
                }
            }
        }
    }
    return names.sorted()
}

func emit(features: [ParsedFeature], steps: [StepDef], params: [String: [String: String]], featureParams: [String: [String: String]], hash: String) -> (outputs: [Output], cleanDirs: [String]) {
    let h = header(hash)
    var outs: [Output] = []
    let defaults = params["default"] ?? [:]
    func caseFor(_ s: ParsedStep) -> String { lookup(s, in: steps)!.def.caseName }
    func argsFor(_ s: ParsedStep) -> [String] { lookup(s, in: steps)!.args }
    let clientKeys = clientTags.map(\.key)

    // ── Swift kernel ──
    let swiftEnum = steps.map { "    case \($0.caseName) = \(swiftString($0.text))" }.joined(separator: "\n")
    outs.append(Output(path: "gherkin/StarGherkin/Sources/StarGherkinKernel/Generated/StepAction.generated.swift", content: """
    \(h)
    public enum StepAction: String, CaseIterable, Sendable {
    \(swiftEnum)
    }

    """))

    var swiftFeatures = ""
    for f in features {
        let stepsLit = f.steps.map { s -> String in
            let args = argsFor(s)
            let tail = args.isEmpty ? "" : ", args: [\(args.map(swiftString).joined(separator: ", "))]"
            return "            Step(.\(keywordCase(s.keyword)), .\(caseFor(s))\(tail))"
        }.joined(separator: ",\n")
        swiftFeatures += """
            public static let \(f.basename) = Feature(
                id: \(swiftString(f.basename)),
                name: \(swiftString(f.name)),
                tags: [\(f.tags.map(swiftString).joined(separator: ", "))],
                scenario: \(swiftString(f.scenario)),
                steps: [
        \(stepsLit)
                ])

        """ + "\n"
    }
    let swiftOverrides = clientKeys.map { k in
        let body = dictLiteral(params[k] ?? [:], quote: swiftString, indent: "            ")
        return body.isEmpty ? "        \(swiftString(k)): [:]" : "        \(swiftString(k)): [\n\(body),\n        ]"
    }.joined(separator: ",\n")
    let swiftFeatureParams = featureParams.keys.sorted().map { k in
        "        \(swiftString(k)): [\n\(dictLiteral(featureParams[k]!, quote: swiftString, indent: "            ")),\n        ]"
    }.joined(separator: ",\n")
    outs.append(Output(path: "gherkin/StarGherkin/Sources/StarGherkinKernel/Generated/Features.generated.swift", content: """
    \(h)
    public enum Features {
    \(swiftFeatures)    public static let all: [Feature] = [\(features.map(\.basename).joined(separator: ", "))]
    }

    extension Params {
        public static let defaults: [String: String] = [
    \(dictLiteral(defaults, quote: swiftString, indent: "        ")),
        ]
        public static let overrides: [String: [String: String]] = [
    \(swiftOverrides),
        ]
        public static let features: [String: [String: String]] = [
    \(swiftFeatureParams),
        ]
    }

    """))

    // ── Swift test entry points ──
    func swiftTests(tag: String, runner: String, cls: String, mainActor: Bool) -> String {
        let methods = features.filter { $0.tags.contains(tag) }.map {
            "    func test\(capitalised($0.basename))Feature() throws {\n        try \(runner)(testCase: self).run(Features.\($0.basename))\n    }\n"
        }.joined(separator: "\n")
        return """
        \(h)
        import StarGherkinKernel
        import XCTest

        \(mainActor ? "@MainActor\n" : "")final class \(cls): XCTestCase {
        \(methods)}

        """
    }
    outs.append(Output(path: "cli/Tests/GherkinTests/GeneratedFeatureTests.swift",
                       content: swiftTests(tag: "@cli", runner: "CliFeatureRunner", cls: "GeneratedFeatureTests", mainActor: false)))
    outs.append(Output(path: "gui/starUITests/GeneratedFeatureUITests.swift",
                       content: swiftTests(tag: "@mac-gui", runner: "GuiFeatureRunner", cls: "GeneratedFeatureUITests", mainActor: true)))

    // ── Kotlin ──
    let ktPkg = "star-desktop/src/gherkinTest/kotlin/com/star/desktop/gherkin/generated"
    let ktEnum = steps.map { "    \(camelToUpperSnake($0.caseName))(\(kotlinString($0.text)))" }.joined(separator: ",\n")
    outs.append(Output(path: "\(ktPkg)/StepAction.kt", content: """
    \(h)
    package com.star.desktop.gherkin.generated

    enum class StepAction(val text: String) {
    \(ktEnum);
    }

    """))

    var ktFeatures = ""
    for f in features {
        let stepsLit = f.steps.map { s -> String in
            let args = argsFor(s)
            let tail = args.isEmpty ? "" : ", listOf(\(args.map(kotlinString).joined(separator: ", ")))"
            return "            Step(StepKeyword.\(s.keyword.uppercased()), StepAction.\(camelToUpperSnake(caseFor(s)))\(tail))"
        }.joined(separator: ",\n")
        ktFeatures += """
            val \(f.basename) = Feature(
                id = \(kotlinString(f.basename)),
                name = \(kotlinString(f.name)),
                tags = listOf(\(f.tags.map(kotlinString).joined(separator: ", "))),
                scenario = \(kotlinString(f.scenario)),
                steps = listOf(
        \(stepsLit)
                ))

        """ + "\n"
    }
    let ktOverrides = clientKeys.map { k in
        let body = dictLiteral(params[k] ?? [:], quote: kotlinString, indent: "            ").replacingOccurrences(of: ": ", with: " to ")
        return body.isEmpty ? "        \(kotlinString(k)) to mapOf()" : "        \(kotlinString(k)) to mapOf(\n\(body),\n        )"
    }.joined(separator: ",\n")
    let ktFeatureParams = featureParams.keys.sorted().map { k in
        "        \(kotlinString(k)) to mapOf(\n\(dictLiteral(featureParams[k]!, quote: kotlinString, indent: "            ").replacingOccurrences(of: ": ", with: " to ")),\n        )"
    }.joined(separator: ",\n")
    outs.append(Output(path: "\(ktPkg)/Features.kt", content: """
    \(h)
    package com.star.desktop.gherkin.generated

    import com.star.desktop.gherkin.Feature
    import com.star.desktop.gherkin.Step
    import com.star.desktop.gherkin.StepKeyword

    object Features {
    \(ktFeatures)    val all: List<Feature> = listOf(\(features.map(\.basename).joined(separator: ", ")))
    }

    object GeneratedParams {
        val defaults: Map<String, String> = mapOf(
    \(dictLiteral(defaults, quote: kotlinString, indent: "        ").replacingOccurrences(of: ": ", with: " to ")),
        )
        val overrides: Map<String, Map<String, String>> = mapOf(
    \(ktOverrides),
        )
        val features: Map<String, Map<String, String>> = mapOf(
    \(ktFeatureParams),
        )
    }

    """))

    let ktMethods = features.filter { $0.tags.contains("@desktop") }.map {
        "    @Test\n    fun \($0.basename)Feature() = DesktopFeatureRunner().run(Features.\($0.basename))\n"
    }.joined(separator: "\n")
    outs.append(Output(path: "\(ktPkg)/GeneratedFeatureTests.kt", content: """
    \(h)
    package com.star.desktop.gherkin.generated

    import com.star.desktop.gherkin.DesktopFeatureRunner
    import kotlin.test.Test

    class GeneratedFeatureTests {
    \(ktMethods)}

    """))

    // ── dataset lists: CI fetches exactly these ──
    for c in clientTags {
        let names = datasetNames(for: c, features: features, params: params, featureParams: featureParams)
        outs.append(Output(path: "gherkin/generated/datasets-\(c.key).txt", content: names.map { $0 + "\n" }.joined()))
        // CI builds its (client, OS, feature) matrix from this.
        let ids = features.filter { $0.tags.contains(c.tag) }.map { "\"\($0.basename)\"" }.joined(separator: ", ")
        outs.append(Output(path: "gherkin/generated/features-\(c.key).json", content: "[\(ids)]\n"))
        // …and fetches only what its feature needs: { "<feature>": ["<dataset>", …] }
        let perFeature = features.filter { $0.tags.contains(c.tag) }.map { f in
            "  \"\(f.basename)\": [\(datasetNames(for: c, features: [f], params: params, featureParams: featureParams).map { "\"\($0)\"" }.joined(separator: ", "))]"
        }.joined(separator: ",\n")
        outs.append(Output(path: "gherkin/generated/feature-datasets-\(c.key).json", content: "{\n\(perFeature)\n}\n"))
    }

    return (outs, [
        "gherkin/generated",
        "gherkin/StarGherkin/Sources/StarGherkinKernel/Generated",
        ktPkg,
        "cli/Tests/GherkinTests/GeneratedFeatureTests.swift",
        "gui/starUITests/GeneratedFeatureUITests.swift",
    ])
}

// MARK: - Main

func findRoot() throws -> URL {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--root"), i + 1 < args.count { return URL(fileURLWithPath: args[i + 1]).standardizedFileURL }
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    while true {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("gherkin/steps.json").path) { return dir }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { throw GenError("cannot find the repo root (no gherkin/steps.json above \(FileManager.default.currentDirectoryPath)); pass --root") }
        dir = parent
    }
}

func generate() throws {
    let fm = FileManager.default
    let root = try findRoot()
    let gdir = root.appendingPathComponent("gherkin")
    let featuresDir = gdir.appendingPathComponent("features")
    let stepsURL = gdir.appendingPathComponent("steps.json")
    let paramsURL = gdir.appendingPathComponent("params.json")

    let featureFiles = try fm.contentsOfDirectory(atPath: featuresDir.path).filter { $0.hasSuffix(".feature") }.sorted()
    guard !featureFiles.isEmpty else { throw GenError("no .feature files in gherkin/features") }

    // steps.json
    guard let stepsRaw = try JSONSerialization.jsonObject(with: Data(contentsOf: stepsURL)) as? [[String: String]] else {
        throw GenError("gherkin/steps.json must be an array of {\"case\", \"text\"} objects")
    }
    let steps = try stepsRaw.map { d -> StepDef in
        guard let c = d["case"], let t = d["text"], isLowerCamel(c) else { throw GenError("gherkin/steps.json: every entry needs a lowerCamelCase \"case\" and a \"text\": \(d)") }
        return StepDef(caseName: c, text: t)
    }
    for (i, s) in steps.enumerated() {
        if steps[..<i].contains(where: { $0.caseName == s.caseName || $0.text == s.text }) { throw GenError("gherkin/steps.json: duplicate case or text: \(s.caseName)") }
    }

    // params.json: { "default": {...}, "cli": {...}, "mac-gui": {...}, "desktop": {...} }
    guard var rawParams = try JSONSerialization.jsonObject(with: Data(contentsOf: paramsURL)) as? [String: Any] else {
        throw GenError("gherkin/params.json must be a JSON object")
    }
    let featureParams = (rawParams.removeValue(forKey: "features") as? [String: [String: String]]) ?? [:]
    guard let params = rawParams as? [String: [String: String]], let defaults = params["default"] else {
        throw GenError("gherkin/params.json must be {\"default\": {...}, \"cli\": {...}, \"mac-gui\": {...}, \"desktop\": {...}, \"features\": {name: {...}}} with string values")
    }
    for key in params.keys where key != "default" && !clientTags.contains(where: { $0.key == key }) {
        throw GenError("gherkin/params.json: unknown client override `\(key)` (expected cli, mac-gui or desktop)")
    }

    let datasetsURL = root.appendingPathComponent("test_data/datasets.json")
    try checkDataParams(params, featureParams: featureParams, manifest: try loadDatasetNames(datasetsURL), paramsURL: paramsURL)

    // hash of every input file, sorted by path, concatenated
    var inputs = featureFiles.map { featuresDir.appendingPathComponent($0) }
    inputs += [stepsURL, paramsURL, datasetsURL]
    inputs.sort { $0.path < $1.path }
    var all: [UInt8] = []
    for u in inputs { all += [UInt8](try Data(contentsOf: u)) }
    let hash = sha256Hex(all)

    let gherkin = try findGherkin()
    let features = try featureFiles.map { try parseFeature(at: featuresDir.appendingPathComponent($0), root: root, gherkin: gherkin) }
    for name in featureParams.keys where !features.contains(where: { $0.basename == name }) {
        throw GenError("gherkin/params.json: features.\(name) has no matching feature file")
    }
    let references = try loadUIReferences(root: root)
    for f in features { try validate(f, steps: steps, defaults: defaults, featureParams: featureParams[f.basename] ?? [:], references: references) }

    let (outputs, clean) = emit(features: features, steps: steps, params: params, featureParams: featureParams, hash: hash)
    for c in clean { try? fm.removeItem(at: root.appendingPathComponent(c)) }
    for o in outputs {
        let url = root.appendingPathComponent(o.path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try o.content.write(to: url, atomically: true, encoding: .utf8)
    }
    print("star-gherkin-gen: \(features.count) feature(s), \(steps.count) step(s), parser \(gherkin.path), source-hash \(hash)")
    for o in outputs { print("  wrote \(o.path)") }
}

do { try generate() } catch {
    FileHandle.standardError.write(Data("star-gherkin-gen: error: \(error)\n".utf8))
    exit(1)
}
