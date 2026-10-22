import Foundation
import Testing
@testable import IPTVCore

@Suite("Update checking")
struct UpdateCheckerTests {
    /// Answers every request with one canned response and remembers what was asked.
    final class ReleaseStub: HTTPTransport, @unchecked Sendable {
        let status: Int
        let body: String
        private(set) var requested: [URL] = []

        init(status: Int = 200, body: String) {
            self.status = status
            self.body = body
        }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requested.append(request.url!)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
            throw URLError(.unsupportedURL)
        }
    }

    static func release(tag: String, draft: Bool = false, page: String? = nil, signed: Bool = false,
                        downloads: String = "https://github.com/owner/repo/releases/download") -> String {
        let signature = signed ? #", {"name": "Lumio.zip.sig", "browser_download_url": "\#(downloads)/\#(tag)/Lumio.zip.sig"}"# : ""
        return """
        {"tag_name": "\(tag)", "name": "Lumio \(tag)", "body": "Fixes and polish.", "draft": \(draft),
         "html_url": "\(page ?? "https://github.com/owner/repo/releases/tag/\(tag)")", "published_at": "2026-10-01T12:00:00Z",
         "assets": [{"name": "Lumio.zip", "browser_download_url": "\(downloads)/\(tag)/a.zip"},
                    {"name": "Lumio.dmg", "browser_download_url": "\(downloads)/\(tag)/a.dmg"}\(signature)]}
        """
    }

    @Test(arguments: [
        ("1.2.3", "1.2.4", true), ("1.2.3", "1.10.0", true), ("v2.0", "1.9.9", false), ("1.0.0-beta.2", "1.0.0", true),
        ("1.0.0-beta.2", "1.0.0-beta.10", true), ("1.0.0", "1.0.0-rc.1", false), ("1.0", "1.0.0", false), ("0.1.0", "0.1.0+build.7", false),
    ])
    func versionsCompare(lower: String, higher: String, isLess: Bool) throws {
        let a = try #require(SemanticVersion(lower))
        let b = try #require(SemanticVersion(higher))
        #expect((a < b) == isLess)
    }

    @Test func rejectsNonVersions() {
        #expect(SemanticVersion("latest") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("v1.4")?.description == "1.4.0")
    }

    @Test func feedNeedsOwnerAndRepository() {
        #expect(UpdateFeed(gitHubRepository: "owner/repo") == .gitHub(owner: "owner", repository: "repo"))
        #expect(UpdateFeed(gitHubRepository: "") == nil)
        #expect(UpdateFeed(gitHubRepository: nil) == nil)
        #expect(UpdateFeed(gitHubRepository: "just-a-name") == nil)
        #expect(UpdateFeed(gitHubRepository: "a/b/c") == nil)
        // Only GitHub name characters, so nothing can be smuggled into the API URL.
        #expect(UpdateFeed(gitHubRepository: "owner/repo?x=1") == nil)
        #expect(UpdateFeed(gitHubRepository: "../repo") == nil)
        #expect(UpdateFeed(gitHubRepository: "owner/") == nil)
        #expect(UpdateFeed(gitHubRepository: "my-org/IPTV_Streamer.app") == .gitHub(owner: "my-org", repository: "IPTV_Streamer.app"))
    }

    /// The app opens these links in the browser, so only GitHub pages are accepted.
    @Test func onlyGitHubLinksAreOffered() async throws {
        let feed = UpdateFeed.gitHub(owner: "owner", repository: "repo")
        let offsite = ReleaseStub(body: Self.release(tag: "v0.2.0", page: "https://evil.example/download"))
        await #expect(throws: UpdateError.self) {
            try await UpdateChecker(feed: feed, currentVersion: SemanticVersion("0.1.0")!, transport: offsite).check()
        }
        let plainHTTP = ReleaseStub(body: Self.release(tag: "v0.2.0", page: "http://github.com/owner/repo"))
        await #expect(throws: UpdateError.self) {
            try await UpdateChecker(feed: feed, currentVersion: SemanticVersion("0.1.0")!, transport: plainHTTP).check()
        }
        let offsiteAssets = ReleaseStub(body: Self.release(tag: "v0.2.0", downloads: "https://evil.example"))
        guard case .available(let update) = try await UpdateChecker(feed: feed, currentVersion: SemanticVersion("0.1.0")!, transport: offsiteAssets).check()
        else {
            Issue.record("expected an update")
            return
        }
        #expect(update.downloadURL == nil)
        let offsiteSigned = ReleaseStub(body: Self.release(tag: "v0.2.0", signed: true, downloads: "https://evil.example"))
        guard case .available(let signed) = try await UpdateChecker(feed: feed, currentVersion: SemanticVersion("0.1.0")!, transport: offsiteSigned).check()
        else {
            Issue.record("expected an update")
            return
        }
        #expect(!signed.canInstall)
    }

    /// Only a zip with a matching ".sig" can be installed in place; otherwise the user downloads it.
    @Test func signedReleasesCanBeInstalled() async throws {
        let feed = UpdateFeed.gitHub(owner: "owner", repository: "repo")
        let version = SemanticVersion("0.1.0")!
        guard case .available(let signed) = try await UpdateChecker(feed: feed, currentVersion: version,
                                                                     transport: ReleaseStub(body: Self.release(tag: "v0.2.0", signed: true))).check(),
              case .available(let unsigned) = try await UpdateChecker(feed: feed, currentVersion: version,
                                                                       transport: ReleaseStub(body: Self.release(tag: "v0.2.0"))).check()
        else {
            Issue.record("expected updates")
            return
        }
        #expect(signed.canInstall)
        #expect(signed.archiveURL?.absoluteString == "https://github.com/owner/repo/releases/download/v0.2.0/a.zip")
        #expect(signed.signatureURL?.absoluteString == "https://github.com/owner/repo/releases/download/v0.2.0/Lumio.zip.sig")
        #expect(!unsigned.canInstall)
        #expect(unsigned.archiveURL == nil && unsigned.signatureURL == nil)
    }

    @Test func findsANewerReleaseAndPrefersTheDiskImage() async throws {
        let stub = ReleaseStub(body: Self.release(tag: "v0.2.0"))
        let checker = UpdateChecker(feed: .gitHub(owner: "owner", repository: "repo"), currentVersion: SemanticVersion("0.1.0")!, transport: stub)
        guard case .available(let update) = try await checker.check() else {
            Issue.record("expected an update")
            return
        }
        #expect(update.version == SemanticVersion("0.2.0"))
        #expect(update.downloadURL?.absoluteString == "https://github.com/owner/repo/releases/download/v0.2.0/a.dmg")
        #expect(update.pageURL.absoluteString == "https://github.com/owner/repo/releases/tag/v0.2.0")
        #expect(update.notes == "Fixes and polish.")
        #expect(stub.requested.map(\.absoluteString) == ["https://api.github.com/repos/owner/repo/releases/latest"])
    }

    @Test func sameOrOlderReleaseIsUpToDate() async throws {
        let feed = UpdateFeed.gitHub(owner: "owner", repository: "repo")
        let same = UpdateChecker(feed: feed, currentVersion: SemanticVersion("0.2.0")!, transport: ReleaseStub(body: Self.release(tag: "0.2.0")))
        #expect(try await same.check() == .upToDate(latest: SemanticVersion("0.2.0")!))
        let newerDraft = UpdateChecker(feed: feed, currentVersion: SemanticVersion("0.2.0")!,
                                       transport: ReleaseStub(body: Self.release(tag: "0.3.0", draft: true)))
        #expect(try await newerDraft.check() == .upToDate(latest: SemanticVersion("0.3.0")!))
    }

    @Test func reportsMissingReleasesAndBadResponses() async throws {
        let feed = UpdateFeed.gitHub(owner: "owner", repository: "repo")
        let version = SemanticVersion("0.1.0")!
        await #expect(throws: UpdateError.noReleases) {
            try await UpdateChecker(feed: feed, currentVersion: version, transport: ReleaseStub(status: 404, body: "{}")).check()
        }
        await #expect(throws: UpdateError.badResponse("HTTP 500")) {
            try await UpdateChecker(feed: feed, currentVersion: version, transport: ReleaseStub(status: 500, body: "")).check()
        }
        await #expect(throws: UpdateError.badResponse("tag “nightly” isn't a version")) {
            try await UpdateChecker(feed: feed, currentVersion: version, transport: ReleaseStub(body: Self.release(tag: "nightly"))).check()
        }
    }
}
