import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@_exported import LumioUpdate

// Update checking. Foundation only, so it can be shared with future iOS/tvOS apps.
//
// The app never checks unless a release feed is configured (see `UpdateFeed`), so a build without
// one only talks to the user's own providers. Installing is done by the app's installer service
// (LumioUpdate), and only for archives signed with the release key.

/// A published release that's newer than the running app.
public struct AvailableUpdate: Hashable, Sendable {
    public var version: SemanticVersion
    public var title: String
    public var notes: String
    /// Page to send the user to (the release page).
    public var pageURL: URL
    /// The app download itself (.dmg or .zip), when the release has one.
    public var downloadURL: URL?
    public var publishedAt: Date?
    /// The signed .zip the app installs itself from, and its signature (the "<zip>.sig" asset).
    /// Both nil when the release wasn't signed; then the user downloads it by hand.
    public var archiveURL: URL?
    public var signatureURL: URL?

    public var canInstall: Bool { archiveURL != nil && signatureURL != nil }

    public init(version: SemanticVersion, title: String, notes: String, pageURL: URL, downloadURL: URL? = nil,
                publishedAt: Date? = nil, archiveURL: URL? = nil, signatureURL: URL? = nil) {
        self.version = version
        self.title = title
        self.notes = notes
        self.pageURL = pageURL
        self.downloadURL = downloadURL
        self.publishedAt = publishedAt
        self.archiveURL = archiveURL
        self.signatureURL = signatureURL
    }
}

public enum UpdateCheckResult: Hashable, Sendable {
    case upToDate(latest: SemanticVersion)
    case available(AvailableUpdate)
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case notConfigured
    case noReleases
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Update checking isn't set up for this build."
        case .noReleases: "No releases have been published yet."
        case .badResponse(let detail): "The update server sent an unexpected response (\(detail))."
        }
    }
}

/// Which app is asking. Every release carries both builds; each app takes its own.
public enum UpdatePlatform: String, Sendable, CaseIterable {
    /// The .dmg / signed .zip.
    case mac
    /// `Lumio-AndroidTV.apk` and its `.sig`. The name never changes, so
    /// `releases/latest/download/Lumio-AndroidTV.apk` is always the newest build (Downloader uses it).
    case android

    public static let androidAsset = "Lumio-AndroidTV.apk"
}

/// Where releases are published. Only GitHub Releases for now.
public enum UpdateFeed: Hashable, Sendable {
    /// "owner/repo" on GitHub.
    case gitHub(owner: String, repository: String)

    /// Reads "owner/repo" (as stored in Info.plist). Empty or malformed means not configured.
    public init?(gitHubRepository: String?) {
        let parts = (gitHubRepository ?? "").trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        // GitHub owner and repository names: letters, digits, "-", "_" and ".".
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) })
        else { return nil }
        self = .gitHub(owner: String(parts[0]), repository: String(parts[1]))
    }

    var latestReleaseURL: URL {
        switch self {
        case let .gitHub(owner, repository):
            URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
        }
    }
}

/// Compares the latest published release with the running version.
///
/// A release's notes may carry a hidden marker of the version in which each platform's build last
/// changed, written by Tools/Release/publish.sh: `<!-- lumio-changed: mac=0.2.1 android=0.2.0 -->`.
/// An app is only offered the release when its own platform changed after the version it runs, so
/// a Mac-only fix doesn't ask every TV to update (and an Android user who skipped a release still
/// gets it). Releases without the marker are offered to every platform that has a build in them.
public struct UpdateChecker: Sendable {
    private let feed: UpdateFeed
    private let currentVersion: SemanticVersion
    private let platform: UpdatePlatform
    private let transport: any HTTPTransport

    public init(feed: UpdateFeed, currentVersion: SemanticVersion, platform: UpdatePlatform = .mac,
                transport: any HTTPTransport = URLSessionTransport()) {
        self.feed = feed
        self.currentVersion = currentVersion
        self.platform = platform
        self.transport = transport
    }

    public func check() async throws -> UpdateCheckResult {
        var request = URLRequest(url: feed.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Lumio/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        switch response.statusCode {
        case 200: break
        case 404: throw UpdateError.noReleases
        default: throw UpdateError.badResponse("HTTP \(response.statusCode)")
        }
        let release: GitHubRelease
        do {
            release = try Self.decoder.decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateError.badResponse("unreadable release")
        }
        guard let latest = SemanticVersion(release.tagName) else {
            throw UpdateError.badResponse("tag “\(release.tagName)” isn't a version")
        }
        guard latest > currentVersion, release.draft != true else { return .upToDate(latest: latest) }
        let body = release.body ?? ""
        if let changed = Self.changedVersions(in: body) {
            // Nothing new for this platform since the version it runs.
            guard let since = changed[platform], currentVersion < since else { return .upToDate(latest: latest) }
        }
        let assets = release.assets ?? []
        // The app opens and downloads these links, so only GitHub's own https pages count.
        guard Self.isGitHubPage(release.htmlURL) else { throw UpdateError.badResponse("unexpected release page") }
        func onGitHub(_ url: URL?) -> URL? { url.flatMap { Self.isGitHubPage($0) ? $0 : nil } }
        let download: URL?, archive: Asset?
        switch platform {
        case .mac:
            // Prefer a disk image, then a zip, for the direct download.
            download = (assets.first { $0.name.lowercased().hasSuffix(".dmg") } ?? assets.first { $0.name.lowercased().hasSuffix(".zip") })?
                .browserDownloadURL
            // A zip with a matching "<name>.sig" can be installed in place.
            archive = assets.first { asset in
                asset.name.lowercased().hasSuffix(".zip") && assets.contains { $0.name == asset.name + ".sig" }
            }
        case .android:
            // A release without an Android build (from before there was one) isn't an update.
            guard let apk = assets.first(where: { $0.name == UpdatePlatform.androidAsset }) else { return .upToDate(latest: latest) }
            download = apk.browserDownloadURL
            archive = apk
        }
        let signature = archive.flatMap { archive in assets.first { $0.name == archive.name + ".sig" } }
        let archiveURL = onGitHub(archive?.browserDownloadURL), signatureURL = onGitHub(signature?.browserDownloadURL)
        return .available(AvailableUpdate(
            version: latest, title: release.name?.isEmpty == false ? release.name! : "Version \(latest)",
            notes: Self.removingMarker(body), pageURL: release.htmlURL, downloadURL: onGitHub(download),
            publishedAt: release.publishedAt,
            archiveURL: signatureURL == nil ? nil : archiveURL, signatureURL: archiveURL == nil ? nil : signatureURL))
    }

    private typealias Asset = GitHubRelease.Asset

    private static let markerPattern = #"<!--\s*lumio-changed:([^>]*)-->"#

    /// The marker's versions by platform, or nil when the notes have none.
    static func changedVersions(in notes: String) -> [UpdatePlatform: SemanticVersion]? {
        guard let range = notes.range(of: markerPattern, options: .regularExpression) else { return nil }
        let inside = notes[range].dropFirst(4).dropLast(3).replacingOccurrences(of: "lumio-changed:", with: "")
        var versions: [UpdatePlatform: SemanticVersion] = [:]
        for pair in inside.split(whereSeparator: \.isWhitespace) {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let platform = UpdatePlatform(rawValue: String(parts[0])),
                  let version = SemanticVersion(String(parts[1])) else { continue }
            versions[platform] = version
        }
        return versions
    }

    static func removingMarker(_ notes: String) -> String {
        notes.replacingOccurrences(of: markerPattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isGitHubPage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com")
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// The fields we use from GitHub's "latest release" response.
private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let draft: Bool?
    let publishedAt: Date?
    let assets: [Asset]?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body, draft, assets
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }
}
