import Foundation
import Testing
@testable import IPTVCore

@Suite("Credential redaction")
struct CredentialRedactorTests {
    @Test(arguments: [
        ("http://h.test:8080/live/alice/s3cret/123.ts", "http://h.test:8080/live/***/***/123.ts"),
        ("http://h.test/movie/alice/s3cret/55.mkv", "http://h.test/movie/***/***/55.mkv"),
        ("http://h.test/series/alice/s3cret/9.mp4", "http://h.test/series/***/***/9.mp4"),
        ("http://h.test/timeshift/alice/s3cret/60/2026-10-17:20-00/1.ts",
         "http://h.test/timeshift/***/***/60/2026-10-17:20-00/1.ts"),
        ("http://h.test/player_api.php?username=alice&password=s3cret&action=get_live_streams",
         "http://h.test/player_api.php?username=***&password=***&action=get_live_streams"),
        ("http://h.test/xmltv.php?password=s3cret&username=alice", "http://h.test/xmltv.php?password=***&username=***"),
        ("http://alice:s3cret@h.test/stream", "http://***@h.test/stream"),
    ])
    func masksKnownURLShapes(input: String, expected: String) {
        #expect(CredentialRedactor.redact(input) == expected)
    }

    @Test func masksLiteralCredentialsAnywhere() {
        let credentials = ProviderCredentials(username: "alice", password: "p@ss word")
        let text = "Login failed for alice using p@ss word (encoded p%40ss%20word)"
        let redacted = CredentialRedactor.redact(text, credentials: [credentials])
        #expect(!redacted.contains("alice"))
        #expect(!redacted.contains("p@ss word"))
        #expect(!redacted.contains("p%40ss%20word"))
    }

    @Test func shortCredentialsDontMangleOrdinaryWords() {
        let credentials = ProviderCredentials(username: "user", password: "pass")
        let text = "The provider rejected the username or password for user (pass)."
        #expect(CredentialRedactor.redact(text, credentials: [credentials])
                == "The provider rejected the username or password for *** (***).")
    }

    @Test func leavesOrdinaryURLsAlone() {
        let url = "http://h.test:8080/images/logo.png"
        #expect(CredentialRedactor.redact(url) == url)
    }

    @Test func credentialsNeverAppearInDescriptions() {
        let credentials = ProviderCredentials(username: "alice", password: "s3cret")
        let described = "\(credentials) \(String(reflecting: credentials))"
        #expect(!described.contains("alice"))
        #expect(!described.contains("s3cret"))
    }
}
