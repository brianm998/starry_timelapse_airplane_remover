import Foundation

public struct GitHubRelease: Codable {
    public struct Asset: Codable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let id: Int
    public let tagName: String
    public let name: String?
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let createdAt: Date
    public let publishedAt: Date?
    public let htmlURL: URL
    public let assets: [Asset]

    public var version: ReleaseVersion? {
        if let versionString = tagName.components(separatedBy: "/").last {
            return ReleaseVersion(versionString)
        } else {
            return nil
        }
    }

    public enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case body
        case draft
        case prerelease
        case createdAt = "created_at"
        case publishedAt = "published_at"
        case htmlURL = "html_url"
        case assets
    }

    public func packageURL(for releaseType: ReleaseType) -> URL? {
        // go through assets and return the browserDownloadURL
        for asset in self.assets {
            switch releaseType {
            case .gui:
                if asset.name.starts(with: "star_app_") {
                    // we found a new release
                    return asset.browserDownloadURL
                }

            case .cli:
                if asset.name.starts(with: "star_cli_") {
                    // we found a new release
                    return asset.browserDownloadURL
                }
            }
        }
        return nil
    }
}

