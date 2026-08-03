import Foundation

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/// One language star ships translations for.
///
/// Loaded from `Resources/Localizations/languages.json` rather than hard-coded here, so that
/// adding a language is a data change: drop in `<code>.json`, add a row to the manifest, done.
/// `LocalizationTests` fails if the manifest and the tables on disk ever disagree.
public struct StarLanguage: Sendable, Hashable, Codable, Identifiable {

    /// BCP-47 tag, and also the basename of this language's table — `pt-BR` ⇒ `pt-BR.json`.
    public let code: String

    /// The language's name *in that language*, which is what a language picker has to show:
    /// someone who has landed in a language they cannot read needs to find their own by
    /// recognising it, and "Japanese" is no help when the UI is already Japanese.
    public let nativeName: String

    /// The language's name in English, for logs, `--list-languages`, and bug reports.
    public let englishName: String

    /// Whether the script runs right-to-left (Arabic, Urdu). Clients that can flip layout
    /// direction read this; the cli ignores it.
    public let rightToLeft: Bool

    public var id: String { code }

    /// The base language subtag — `pt` for `pt-BR`, `zh` for `zh-Hans`. Used when matching a
    /// system locale that names a region or script we have no specific table for.
    public var baseCode: String {
        String(code.split(separator: "-").first ?? "")
    }

    public init(code: String, nativeName: String, englishName: String, rightToLeft: Bool = false) {
        self.code = code
        self.nativeName = nativeName
        self.englishName = englishName
        self.rightToLeft = rightToLeft
    }
}

/// The shape of `languages.json`.
struct StarLanguageManifest: Codable {
    let sourceLanguage: String
    let languages: [StarLanguage]
}
