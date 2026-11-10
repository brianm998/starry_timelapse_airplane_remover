import XCTest
@testable import StarCore

/// `newerRelease(than:in:)` is the rule `newRelease()` applies to GitHub's list: drafts are not releases yet, the highest version
/// wins whatever order the list is in, and an empty list is simply "nothing newer" (it used to index `[0]` and trap).
final class ReleaseManagerTests: XCTestCase {

    private func release(_ tag: String, id: Int, draft: Bool = false) throws -> GitHubRelease {
        let json = """
        {"id": \(id), "tag_name": "\(tag)", "name": null, "body": null, "draft": \(draft), "prerelease": false,
         "created_at": "2026-01-01T00:00:00Z", "published_at": null,
         "html_url": "https://example.com/releases/\(id)", "assets": []}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: Data(json.utf8))
    }

    func testEmptyListGivesNoRelease() {
        XCTAssertNil(newerRelease(than: "0.11.4", in: []))
    }

    func testDraftIsIgnored() throws {
        let draft = try release("v0.12.0", id: 1, draft: true)
        let published = try release("v0.11.5", id: 2)
        XCTAssertEqual(newerRelease(than: "0.11.4", in: [draft, published])?.id, 2)
        XCTAssertNil(newerRelease(than: "0.11.4", in: [draft]))
    }

    func testHighestVersionWinsInAnyOrder() throws {
        let a = try release("0.11.5", id: 1)
        let b = try release("0.12.0", id: 2)
        let c = try release("0.9.30", id: 3)
        let old = try release("0.11.4", id: 4)
        for list in [[a, b, c, old], [b, a, c, old], [old, c, a, b], [c, old, b, a]] {
            XCTAssertEqual(newerRelease(than: "0.11.4", in: list)?.id, 2)
        }
        XCTAssertNil(newerRelease(than: "0.12.0", in: [a, b, c, old]))
    }
}
