import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// Every user-visible string in star, in the language the user reads.
///
/// ## Why this and not `String(localized:)`
///
/// The obvious answer on Apple platforms is a `.xcstrings` catalog and `String(localized:)`.
/// It does not work here: `star` and `stard` ship on Linux and Windows, and SwiftPM does not
/// compile `.xcstrings` — it copies the file into the bundle verbatim and every lookup then
/// silently returns the key. (Measured, not assumed: a `swift build` of a package with an
/// `.xcstrings` resource resolves `hello_world` to the fallback.) A `.lproj/.strings` layout
/// *does* survive SwiftPM, but `String(format:)` with `%@` needs `String: CVarArg`, which
/// only holds on Darwin.
///
/// So the tables are plain JSON, the substitution is ours, and the placeholder syntax is
/// `{0}`/`{1}` — which is also what the Kotlin client's `MessageFormat`-shaped catalogue
/// uses. One catalogue, four clients, three operating systems, no per-platform branch.
///
/// ## Choosing the language
///
/// In order: an explicit override (a `--language` flag, or the user's pick in a gui menu),
/// then `STAR_LANG`, then whatever the OS says the user prefers, then English. The override
/// is the only mutable part; everything else is read once.
///
/// ## Threading
///
/// Lookups are synchronous because they happen inside SwiftUI view bodies and inside string
/// interpolation, where `await` is not available. A lock rather than an actor, therefore, and
/// `@unchecked Sendable` to say so out loud.
public final class StarLocalization: @unchecked Sendable {

    public static let shared = StarLocalization()

    private let lock = NSLock()

    /// Tables already read off disk, keyed by language code. Populated lazily — a run in one
    /// language never pays to parse the other twenty-one.
    private var tables: [String: [String: String]] = [:]

    /// The user's explicit pick, if they made one. `nil` means "follow the system".
    private var overrideCode: String?

    /// Resolved from `overrideCode` + the environment. Cached because it is read on every
    /// single lookup and the resolution walks a preference list.
    private var resolvedCode: String?

    /// Keys we have already complained about, so a missing string in a view body does not
    /// produce a log line per frame.
    private var reportedMissing: Set<String> = []

    private lazy var manifest: StarLanguageManifest = Self.loadManifest()

    private init() {}

    // MARK: - Available languages

    /// Every language star ships, in the order a picker should show them (English first,
    /// then alphabetical by English name).
    public var languages: [StarLanguage] {
        lock.lock(); defer { lock.unlock() }
        return manifest.languages
    }

    /// The language the sources are written in, and the fallback for any key a translation
    /// is missing.
    public static let sourceLanguageCode = "en"

    public func language(forCode code: String) -> StarLanguage? {
        lock.lock(); defer { lock.unlock() }
        return manifest.languages.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }

    // MARK: - Current language

    /// The language being displayed right now.
    public var current: StarLanguage {
        let code = currentCode
        return language(forCode: code)
            ?? StarLanguage(code: "en", nativeName: "English", englishName: "English")
    }

    public var currentCode: String {
        lock.lock()
        if let resolvedCode {
            lock.unlock()
            return resolvedCode
        }
        let candidates = manifest.languages.map(\.code)
        let override = overrideCode
        lock.unlock()

        let resolved = Self.resolve(override: override, against: candidates)

        lock.lock()
        resolvedCode = resolved
        lock.unlock()
        return resolved
    }

    /// The user's explicit choice, or `nil` when star is following the system.
    ///
    /// Setting this to a language star does not ship is not an error — the resolver falls
    /// through to the system preference exactly as if nothing had been set — but it does log,
    /// because a typo in `--language` is otherwise invisible.
    public var languageOverride: String? {
        get {
            lock.lock(); defer { lock.unlock() }
            return overrideCode
        }
        set {
            lock.lock()
            let known = manifest.languages.map(\.code)
            overrideCode = newValue
            resolvedCode = nil          // force re-resolution on next read
            lock.unlock()

            if let newValue,
               !newValue.isEmpty,
               Self.bestMatch(for: newValue, in: known) == nil
            {
                Log.w("unknown language '\(newValue)' — falling back to the system language. "
                        + "star has: \(known.joined(separator: ", "))")
            }
        }
    }

    /// Convenience for clients that store the user's pick as "follow the system" plus a code.
    public func setLanguage(_ language: StarLanguage?) {
        languageOverride = language?.code
    }

    // MARK: - Lookup

    /// The localized string for `key`, or the English one, or — if the key is in no table at
    /// all — the key itself, which is ugly on screen and therefore easy to spot in review.
    public func string(forKey key: String) -> String {
        let code = currentCode

        if let value = table(for: code)[key] { return value }

        if code != Self.sourceLanguageCode,
           let value = table(for: Self.sourceLanguageCode)[key]
        {
            reportMissing(key: key, language: code, fellBackToEnglish: true)
            return value
        }

        reportMissing(key: key, language: code, fellBackToEnglish: false)
        return key
    }

    /// `string(forKey:)` with `{0}`, `{1}`, … replaced by `arguments`.
    ///
    /// Positional rather than in-order because word order is not universal: German puts the
    /// number last where English puts it first, and a translator has to be able to move the
    /// placeholder without the substitution following it.
    ///
    /// `Any`, not `CustomStringConvertible`, so that anything which can go into a `"\(…)"` can
    /// go in here: several of the values these sentences are about — a frame, a processing
    /// state — interpolate perfectly well but conform to nothing. Substitution uses
    /// `String(describing:)`, which is exactly what interpolation would have done.
    public func string(forKey key: String, _ arguments: [Any]) -> String {
        Self.substitute(arguments, into: string(forKey: key))
    }

    /// Look a key up in a specific language, ignoring the current one. For the daemon, which
    /// answers to whatever locale the client announced, and for tests.
    public func string(forKey key: String, language code: String) -> String {
        if let value = table(for: code)[key] { return value }
        return table(for: Self.sourceLanguageCode)[key] ?? key
    }

    /// Every key in the English table. Used by the parity test and by the sync tooling.
    public func allKeys() -> [String] {
        table(for: Self.sourceLanguageCode).keys.sorted()
    }

    // MARK: - Substitution

    static func substitute(_ arguments: [Any], into format: String) -> String {
        guard !arguments.isEmpty else { return format }
        var result = format
        // Highest index first: replacing {1} before {10} would corrupt {10} into
        // "<arg1>0" for any format with more than ten placeholders.
        for index in stride(from: arguments.count - 1, through: 0, by: -1) {
            result = result.replacingOccurrences(of: "{\(index)}",
                                                 with: String(describing: arguments[index]))
        }
        return result
    }

    // MARK: - Tables

    private func table(for code: String) -> [String: String] {
        lock.lock()
        if let cached = tables[code] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let loaded = Self.loadTable(code: code)

        lock.lock()
        tables[code] = loaded
        lock.unlock()
        return loaded
    }

    private static func loadTable(code: String) -> [String: String] {
        guard let url = resourceURL(named: code, extension: "json") else {
            Log.w("no localization table for '\(code)'")
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            Log.e("could not read localization table \(url.path): \(error)")
            return [:]
        }
    }

    private static func loadManifest() -> StarLanguageManifest {
        let fallback = StarLanguageManifest(
          sourceLanguage: "en",
          languages: [StarLanguage(code: "en", nativeName: "English", englishName: "English")])

        guard let url = resourceURL(named: "languages", extension: "json") else {
            Log.e("localization manifest is missing from the bundle — English only")
            return fallback
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(StarLanguageManifest.self, from: data)
        } catch {
            Log.e("could not read the localization manifest at \(url.path): \(error)")
            return fallback
        }
    }

    /// `Bundle.module.url(forResource:withExtension:subdirectory:)` is the documented way in,
    /// but a `.copy`'d directory does not always register its contents with the bundle's
    /// resource index on every platform, so fall back to walking `resourceURL` directly.
    private static func resourceURL(named name: String, extension ext: String) -> URL? {
        if let url = Bundle.module.url(forResource: name,
                                       withExtension: ext,
                                       subdirectory: localizationsDirectoryName)
        {
            return url
        }
        if let root = Bundle.module.resourceURL {
            let url = root
              .appendingPathComponent(localizationsDirectoryName)
              .appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static let localizationsDirectoryName = "Localizations"

    private func reportMissing(key: String, language: String, fellBackToEnglish: Bool) {
        lock.lock()
        let alreadyReported = reportedMissing.contains(key)
        if !alreadyReported { reportedMissing.insert(key) }
        lock.unlock()

        guard !alreadyReported else { return }

        if fellBackToEnglish {
            Log.d("no '\(language)' translation for '\(key)' — showing English")
        } else {
            Log.w("no localized string for '\(key)' in any language — showing the key")
        }
    }

    // MARK: - Resolution

    /// Work out which of `candidates` to display, given the user's override and the machine.
    static func resolve(override: String?, against candidates: [String]) -> String {
        if let override, !override.isEmpty, let match = bestMatch(for: override, in: candidates) {
            return match
        }
        for preference in systemPreferredLanguages() {
            if let match = bestMatch(for: preference, in: candidates) { return match }
        }
        return sourceLanguageCode
    }

    /// The environment variable that names a language for star specifically, ahead of anything
    /// the machine says. Useful for scripts, CI, and reproducing a translation bug.
    public static let languageEnvironmentVariable = "STAR_LANG"

    /// What the user reads, best guess first.
    ///
    /// The environment goes ahead of `Locale.preferredLanguages`, on every platform, and the
    /// ordering took a round of getting wrong to settle. `Locale.preferredLanguages` is always
    /// populated, so putting it first meant `LANG=fr_FR.UTF-8 star` printed English — which is
    /// not what a Unix user who exported that variable is asking for.
    ///
    /// Nothing is lost by the swap. A gui launched from Finder or Dock inherits no `LANG` at
    /// all (launchd does not set one), so it falls straight through to
    /// `Locale.preferredLanguages` and follows System Settings as it should. And in a macOS
    /// terminal, `LANG` is derived from that same system setting by default, so the two agree
    /// except when the user has deliberately overridden one of them — in which case the
    /// deliberate one should win.
    static func systemPreferredLanguages() -> [String] {
        var result: [String] = []
        let environment = ProcessInfo.processInfo.environment

        if let raw = environment[languageEnvironmentVariable], !raw.isEmpty {
            result.append(raw)
        }

        // The order the C library itself resolves these in.
        for variable in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            guard let raw = environment[variable], !raw.isEmpty else { continue }
            if let tag = posixLocaleToLanguageTag(raw) { result.append(tag) }
        }

        result.append(contentsOf: Locale.preferredLanguages)
        result.append(Locale.current.identifier)

        return result
    }

    /// `bn_BD.UTF-8` ⇒ `bn-BD`. Returns nil for the C/POSIX locale, which means "no
    /// preference expressed" rather than "prefer English" — the next source should get a say.
    static func posixLocaleToLanguageTag(_ raw: String) -> String? {
        var value = raw
        for separator in [".", "@"] {
            if let index = value.firstIndex(of: Character(separator)) {
                value = String(value[value.startIndex ..< index])
            }
        }
        value = value.replacingOccurrences(of: "_", with: "-")
        if value.isEmpty || value == "C" || value.caseInsensitiveCompare("POSIX") == .orderedSame {
            return nil
        }
        return value
    }

    /// Match one requested tag against what star ships.
    ///
    /// Three passes, most specific first: the whole tag, then the tag minus its trailing
    /// subtags, then any shipped language with the same base. The last pass is what sends
    /// `pt-PT` to `pt-BR` and `zh-Hant-TW` to `zh-Hans` — an imperfect match, but a Brazilian
    /// UI is closer to what a Portuguese speaker wants than an English one.
    static func bestMatch(for requested: String, in candidates: [String]) -> String? {
        let wanted = requested.replacingOccurrences(of: "_", with: "-")
        guard !wanted.isEmpty else { return nil }

        func find(_ tag: String) -> String? {
            candidates.first { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }

        if let exact = find(wanted) { return exact }

        var parts = wanted.split(separator: "-").map(String.init)
        while parts.count > 1 {
            parts.removeLast()
            if let match = find(parts.joined(separator: "-")) { return match }
        }

        let base = parts.first ?? wanted
        return candidates.first {
            $0.split(separator: "-").first.map(String.init)?
              .caseInsensitiveCompare(base) == .orderedSame
        }
    }
}

// MARK: - Command line

extension StarLocalization {

    /// Pull `--language` out of raw `argv` and apply it, before any argument parser has run.
    ///
    /// This has to happen first, and cannot be done from the parsed value. `swift-argument-parser`
    /// builds its help text by instantiating the command, which evaluates every `help:` expression
    /// — so by the time a parsed `--language` is readable, the help the user asked for has already
    /// been rendered in the old language. `star --language fr --help` would print English.
    ///
    /// Accepts `--language fr` and `--language=fr`. Unknown values are left to
    /// `languageOverride`, which warns and falls back rather than refusing to start: failing to
    /// run because a language tag was misspelled would be a poor trade.
    ///
    /// Returns the value found, if any, so a caller can tell "not given" from "given and ignored".
    @discardableResult
    public static func applyEarlyLanguageSelection(
      arguments: [String] = CommandLine.arguments,
      flag: String = "--language") -> String?
    {
        var found: String?
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if argument == flag {
                let next = arguments.index(after: index)
                if next < arguments.endIndex { found = arguments[next] }
            } else if argument.hasPrefix("\(flag)=") {
                found = String(argument.dropFirst(flag.count + 1))
            }
            index = arguments.index(after: index)
        }

        if let found, !found.isEmpty {
            shared.languageOverride = found
        }
        return found
    }

    /// The `--list-languages` output: every tag star accepts, with the language's own name and
    /// its English name, and a mark against the one that would be used right now.
    public func languageListing() -> String {
        let active = currentCode
        let width = languages.map(\.code.count).max() ?? 0
        return languages.map { language in
            let mark = language.code == active ? "*" : " "
            let padding = String(repeating: " ", count: width - language.code.count + 2)
            return "\(mark) \(language.code)\(padding)\(language.nativeName) (\(language.englishName))"
        }.joined(separator: "\n")
    }
}

// MARK: - The call-site API

/// The localized string for `key`.
///
/// Deliberately a short free function rather than `StarLocalization.shared.string(forKey:)`:
/// there are well over a thousand call sites, and a long one would push view code onto extra
/// lines everywhere. Greppable as `localized("`.
public func localized(_ key: String) -> String {
    StarLocalization.shared.string(forKey: key)
}

/// The localized string for `key`, with `{0}`, `{1}`, … replaced by `arguments`.
public func localized(_ key: String, _ arguments: Any...) -> String {
    StarLocalization.shared.string(forKey: key, arguments)
}
