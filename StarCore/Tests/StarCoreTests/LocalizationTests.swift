import XCTest
import Foundation
@testable import StarCore

/// The localization catalogue is data, and data rots quietly: a key renamed in one language and not
/// the others shows English to some users and nothing to none of them, with no compiler to notice.
/// These tests are the thing that notices.
///
/// The parity test in particular is load-bearing. `StarLocalization` falls back to English for a
/// missing key, which is the right runtime behaviour and exactly why a missing key would otherwise
/// never be reported by anything.
final class LocalizationTests: XCTestCase {

    // MARK: - The catalogue on disk

    /// Every table the manifest promises is actually in the bundle and parses.
    func testEveryDeclaredLanguageHasATable() throws {
        let languages = StarLocalization.shared.languages
        XCTAssertGreaterThanOrEqual(languages.count, 22,
                                    "star is supposed to ship English plus 21 other languages")

        for language in languages {
            let table = try loadTable(language.code)
            XCTAssertFalse(table.isEmpty, "\(language.code).json is empty or unreadable")
        }
    }

    /// English is the source language, so every other table must have exactly its keys — no
    /// missing ones (which would silently show English) and no extra ones (which would be dead
    /// weight, and usually means a key was renamed in en.json and not here).
    func testEveryLanguageHasExactlyTheEnglishKeys() throws {
        let english = Set(try loadTable("en").keys)
        XCTAssertFalse(english.isEmpty, "the English table is missing")

        for language in StarLocalization.shared.languages where language.code != "en" {
            let keys = Set(try loadTable(language.code).keys)

            let missing = english.subtracting(keys).sorted()
            let extra = keys.subtracting(english).sorted()

            XCTAssertTrue(missing.isEmpty,
                          "\(language.code).json is missing \(missing.count) key(s): "
                            + missing.prefix(10).joined(separator: ", "))
            XCTAssertTrue(extra.isEmpty,
                          "\(language.code).json has \(extra.count) key(s) that are not in en.json: "
                            + extra.prefix(10).joined(separator: ", "))
        }
    }

    /// A translation that drops a `{0}` loses the number, filename or path the sentence was about;
    /// one that invents a `{3}` renders the literal braces on screen. Both are invisible until a
    /// user in that language hits the string, so check the placeholder sets match English.
    func testPlaceholdersSurviveTranslation() throws {
        let english = try loadTable("en")

        for language in StarLocalization.shared.languages where language.code != "en" {
            let table = try loadTable(language.code)
            for (key, source) in english {
                guard let translated = table[key] else { continue } // parity test covers this
                XCTAssertEqual(placeholders(in: source), placeholders(in: translated),
                               "\(language.code).json '\(key)' does not use the same placeholders "
                                 + "as English")
            }
        }
    }

    /// No table should contain an empty string: an untranslated entry left blank renders as nothing
    /// at all, which reads as a broken UI rather than as a missing translation.
    func testNoTableHasEmptyValues() throws {
        for language in StarLocalization.shared.languages {
            for (key, value) in try loadTable(language.code) {
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(language.code).json '\(key)' is empty")
            }
        }
    }

    /// The manifest has to be usable as a language picker: unique codes, and names in both the
    /// language itself and English so a lost user can find their way back.
    func testManifestIsWellFormed() {
        let languages = StarLocalization.shared.languages
        XCTAssertEqual(languages.first?.code, "en", "English should lead the picker")
        XCTAssertEqual(Set(languages.map(\.code)).count, languages.count, "duplicate language code")

        for language in languages {
            XCTAssertFalse(language.nativeName.isEmpty, "\(language.code) has no native name")
            XCTAssertFalse(language.englishName.isEmpty, "\(language.code) has no English name")
        }

        XCTAssertTrue(languages.contains { $0.code == "bn" }, "Bangla is required")
        XCTAssertTrue(languages.first { $0.code == "ar" }?.rightToLeft == true)
        XCTAssertTrue(languages.first { $0.code == "ur" }?.rightToLeft == true)
    }

    // MARK: - Lookup

    func testLookupFallsBackToTheKeyWhenNothingHasIt() {
        XCTAssertEqual(StarLocalization.shared.string(forKey: "no.such.key.exists"),
                       "no.such.key.exists")
    }

    func testLookupInASpecificLanguageIgnoresTheCurrentOne() throws {
        // Any key at all, as long as it is one the catalogue really has.
        let key = "warning.title.low_system_memory"
        XCTAssertEqual(StarLocalization.shared.string(forKey: key, language: "en"), "Low Memory")

        // A language with no table falls back to English rather than returning the key.
        XCTAssertEqual(StarLocalization.shared.string(forKey: key, language: "xx-YY"), "Low Memory")
    }

    // MARK: - Substitution

    func testSubstitutionReplacesPositionalPlaceholders() {
        XCTAssertEqual(StarLocalization.substitute(["7", "9"], into: "{0} of {1}"), "7 of 9")
    }

    /// Positional placeholders exist so a translator can reorder them; the substitution has to
    /// honour that rather than filling them left to right.
    func testSubstitutionHonoursReorderedPlaceholders() {
        XCTAssertEqual(StarLocalization.substitute(["7", "9"], into: "{1} ← {0}"), "9 ← 7")
    }

    /// Naive left-to-right replacement turns `{10}` into "<arg1>0" once `{1}` has been done.
    func testSubstitutionHandlesMoreThanTenArguments() {
        let arguments = (0...10).map { "a\($0)" }
        XCTAssertEqual(StarLocalization.substitute(arguments, into: "{10}/{1}"), "a10/a1")
    }

    func testSubstitutionLeavesTheFormatAloneWithNoArguments() {
        XCTAssertEqual(StarLocalization.substitute([], into: "{0} untouched"), "{0} untouched")
    }

    // MARK: - Choosing a language

    func testExactAndPrefixMatching() {
        let shipped = StarLocalization.shared.languages.map(\.code)

        XCTAssertEqual(StarLocalization.bestMatch(for: "fr", in: shipped), "fr")
        XCTAssertEqual(StarLocalization.bestMatch(for: "pt-BR", in: shipped), "pt-BR")
        // Case and separator normalisation — POSIX locales arrive as bn_BD.
        XCTAssertEqual(StarLocalization.bestMatch(for: "BN", in: shipped), "bn")
        XCTAssertEqual(StarLocalization.bestMatch(for: "bn_BD", in: shipped), "bn")
        // A region we do not ship falls back to the language we do.
        XCTAssertEqual(StarLocalization.bestMatch(for: "fr-CA", in: shipped), "fr")
        // And a language we do not ship at all matches nothing, rather than matching something.
        XCTAssertNil(StarLocalization.bestMatch(for: "sw", in: shipped))
        XCTAssertNil(StarLocalization.bestMatch(for: "", in: shipped))
    }

    /// The two tags that need real work: the shipped table names a script or a region that the
    /// requested tag does not, so neither an exact nor a prefix match finds it.
    func testScriptAndRegionFallback() {
        let shipped = StarLocalization.shared.languages.map(\.code)

        XCTAssertEqual(StarLocalization.bestMatch(for: "zh", in: shipped), "zh-Hans")
        XCTAssertEqual(StarLocalization.bestMatch(for: "zh-CN", in: shipped), "zh-Hans")
        XCTAssertEqual(StarLocalization.bestMatch(for: "zh-Hant-TW", in: shipped), "zh-Hans")
        XCTAssertEqual(StarLocalization.bestMatch(for: "pt", in: shipped), "pt-BR")
        XCTAssertEqual(StarLocalization.bestMatch(for: "pt-PT", in: shipped), "pt-BR")
    }

    func testPosixLocaleParsing() {
        XCTAssertEqual(StarLocalization.posixLocaleToLanguageTag("bn_BD.UTF-8"), "bn-BD")
        XCTAssertEqual(StarLocalization.posixLocaleToLanguageTag("de_DE@euro"), "de-DE")
        XCTAssertEqual(StarLocalization.posixLocaleToLanguageTag("ja"), "ja")
        // C/POSIX means "no preference", not "prefer English" — the next source gets a say.
        XCTAssertNil(StarLocalization.posixLocaleToLanguageTag("C"))
        XCTAssertNil(StarLocalization.posixLocaleToLanguageTag("POSIX"))
        XCTAssertNil(StarLocalization.posixLocaleToLanguageTag(""))
    }

    func testResolutionPrefersTheOverrideThenTheSystemThenEnglish() {
        let shipped = ["en", "fr", "ja"]

        XCTAssertEqual(StarLocalization.resolve(override: "ja", against: shipped), "ja")
        // An override naming a language we do not ship is ignored rather than fatal.
        XCTAssertEqual(StarLocalization.resolve(override: "sw", against: ["en"]), "en")
        XCTAssertEqual(StarLocalization.resolve(override: nil, against: ["en"]), "en")
    }

    /// Setting and clearing the override has to take effect on the very next lookup — the gui's
    /// language menu changes it while views are on screen.
    func testOverrideTakesEffectImmediately() {
        let localization = StarLocalization.shared
        let original = localization.languageOverride
        defer { localization.languageOverride = original }

        localization.languageOverride = "fr"
        XCTAssertEqual(localization.currentCode, "fr")
        XCTAssertEqual(localization.current.nativeName, "Français")

        localization.languageOverride = "bn"
        XCTAssertEqual(localization.currentCode, "bn")

        localization.languageOverride = nil
        XCTAssertNotEqual(localization.currentCode, "bn",
                          "clearing the override should go back to the system language")
    }

    /// The end-to-end path a client actually uses: pick a language, call the free function, get
    /// that language's words back.
    func testLocalizedFreeFunctionUsesTheChosenLanguage() throws {
        let localization = StarLocalization.shared
        let original = localization.languageOverride
        defer { localization.languageOverride = original }

        let key = "warning.title.low_system_memory"
        localization.languageOverride = "en"
        let english = localized(key)

        for code in ["fr", "ja", "bn", "ar"] {
            localization.languageOverride = code
            let translated = localized(key)
            XCTAssertEqual(translated, try loadTable(code)[key],
                           "localized() did not return the \(code) string")
            XCTAssertNotEqual(translated, english,
                              "\(code) '\(key)' is still the English text")
        }
    }

    // MARK: - Helpers

    private func loadTable(_ code: String) throws -> [String: String] {
        let url = try XCTUnwrap(bundledLocalization(named: code),
                                "no \(code).json in the StarCore resource bundle")
        return try JSONDecoder().decode([String: String].self, from: try Data(contentsOf: url))
    }

    private func bundledLocalization(named code: String) -> URL? {
        let directory = StarLocalization.localizationsDirectoryName
        if let url = Bundle.module.url(forResource: code,
                                       withExtension: "json",
                                       subdirectory: directory)
        {
            return url
        }
        guard let root = Bundle.module.resourceURL else { return nil }
        let url = root.appendingPathComponent(directory).appendingPathComponent("\(code).json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `{0}`, `{12}` — but not `{}` or `{name}`, which are not placeholders and are allowed to
    /// differ (they are just braces in the text).
    private func placeholders(in text: String) -> Set<String> {
        var found: Set<String> = []
        var digits = ""
        var inside = false
        for character in text {
            if character == "{" { inside = true; digits = ""; continue }
            if inside {
                if character.isNumber {
                    digits.append(character)
                } else {
                    if character == "}", !digits.isEmpty { found.insert(digits) }
                    inside = false
                    digits = ""
                }
            }
        }
        return found
    }
}
