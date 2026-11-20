import XCTest

/// Xcode 27's type checker gives up on a `Log.i("a" + "b" + …)` with a long `+` chain: `Log`
/// has several overloads (an `@autoclosure () -> String?` and generic `T?` / `[T]?` forms),
/// so the solver cannot fix the chain's type up front and its cost grows exponentially with
/// every `+`. A message is written as one interpolated literal instead. This reads the
/// sources, because no test can see a compiler that is not installed.
final class LogMessageConcatenationTests: XCTestCase {

    /// The most `+` operators a `Log.*` call's own argument list may hold.
    private let limit = 2

    func testNoLogCallBuildsItsMessageWithLongPlusChain() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/StarCore")
        let files = try XCTUnwrap(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            checked += 1
            for call in Self.logCalls(in: Array(text.utf8)) where call.pluses > limit {
                offenders.append("\(url.lastPathComponent):\(call.line) has \(call.pluses) `+`")
            }
        }
        XCTAssertGreaterThan(checked, 50, "did not find the StarCore sources")
        XCTAssertEqual(offenders, [],
                       "Log calls with more than \(limit) `+`: write one interpolated literal")
    }

    func testScannerCountsAndSkips() {
        func counts(_ s: String) -> [Int] { Self.logCalls(in: Array(s.utf8)).map(\.pluses) }
        XCTAssertEqual(counts(#"Log.i("a" + "b" + "c" + "d")"#), [3])
        XCTAssertEqual(counts(#"Log.i("a + b + c + d \(x + y + z) \(f("+ +"))")"#), [0])
        XCTAssertEqual(counts("Log.i(\"\"\"\n a + b + \\(1 + 2) \\\n \"\"\")"), [0])
        XCTAssertEqual(counts(##"Log.d(#"a + \#(x + 1) + b"# + "c")"##), [1])
        XCTAssertEqual(counts("Log.w(f(a + b + c) + x) // + + +"), [1])
        XCTAssertEqual(counts("Log.w(a /* + + */ + b += c)"), [1])
        XCTAssertEqual(counts("Log.e(a+b + c)"), [1])
        XCTAssertEqual(counts("// Log.i(a + b + c + d)\nlet s = \"Log.i(a + b + c + d)\""), [])
    }

    // MARK: - scanner

    struct Call { var line: Int; var pluses: Int }

    /// Every `Log.<name>(` in code (not in a comment or literal) and the number of binary
    /// `+` at the top level of its argument list.
    static func logCalls(in b: [UInt8]) -> [Call] {
        var calls: [Call] = []
        var i = 0
        while i < b.count {
            if let end = skipNonCode(b, i) { i = end; continue }
            if b[i] == UInt8(ascii: "L"), matches(b, i, "Log."),
               i == 0 || !isIdent(b[i - 1]) {
                var j = i + 4
                while j < b.count, isLetter(b[j]) { j += 1 }
                if j > i + 4, j < b.count, b[j] == UInt8(ascii: "(") {
                    var n = 0
                    _ = scanArgs(b, j + 1, &n)
                    let line = b[..<i].filter { $0 == 10 }.count + 1
                    calls.append(Call(line: line, pluses: n))
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return calls
    }

    /// From just after an opening paren to just after its match, counting top-level `+`.
    private static func scanArgs(_ b: [UInt8], _ start: Int, _ pluses: inout Int) -> Int {
        var i = start
        var depth = 0
        while i < b.count {
            if let end = skipNonCode(b, i) { i = end; continue }
            let c = b[i]
            switch c {
            case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"):
                if depth == 0 { return i + 1 }
                depth -= 1
            case UInt8(ascii: "+"):
                if depth == 0, i > 0, i + 1 < b.count,
                   isSpace(b[i - 1]), isSpace(b[i + 1]) { pluses += 1 }
            default: break
            }
            i += 1
        }
        return i
    }

    /// If a comment or string literal starts at `i`, the index just after it.
    private static func skipNonCode(_ b: [UInt8], _ i: Int) -> Int? {
        if matches(b, i, "//") {
            var j = i
            while j < b.count, b[j] != 10 { j += 1 }
            return j
        }
        if matches(b, i, "/*") {
            var j = i + 2, nest = 1
            while j < b.count, nest > 0 {
                if matches(b, j, "/*") { nest += 1; j += 2 }
                else if matches(b, j, "*/") { nest -= 1; j += 2 }
                else { j += 1 }
            }
            return j
        }
        var j = i
        while j < b.count, b[j] == UInt8(ascii: "#") { j += 1 }
        let hashes = j - i
        guard j < b.count, b[j] == UInt8(ascii: "\"") else { return nil }
        // A lone `#` that is not followed by a quote is not a literal.
        let multi = matches(b, j, "\"\"\"")
        j += multi ? 3 : 1
        let closer = String(repeating: "\"", count: multi ? 3 : 1)
            + String(repeating: "#", count: hashes)
        let escape = "\\" + String(repeating: "#", count: hashes) + "("
        while j < b.count {
            if matches(b, j, escape) {
                var ignored = 0
                j = scanArgs(b, j + escape.utf8.count, &ignored)
            } else if b[j] == UInt8(ascii: "\\") {
                j += 2 + hashes
            } else if matches(b, j, closer) {
                return j + closer.utf8.count
            } else {
                j += 1
            }
        }
        return j
    }

    private static func matches(_ b: [UInt8], _ i: Int, _ s: String) -> Bool {
        let u = Array(s.utf8)
        guard i + u.count <= b.count else { return false }
        return Array(b[i..<(i + u.count)]) == u
    }
    private static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
    private static func isLetter(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
    }
    private static func isIdent(_ c: UInt8) -> Bool {
        isLetter(c) || (c >= 48 && c <= 57) || c == 95
    }
}
