import Foundation
import Testing
@testable import IPTVCore

@Suite("Server URL normalisation")
struct ServerURLTests {
    @Test(arguments: [
        ("example.com:8080", "http://example.com:8080"),
        ("  http://Example.com:8080/  ", "http://example.com:8080"),
        ("https://example.com", "https://example.com"),
        ("http://example.com:8080/player_api.php?username=", "http://example.com:8080"),
        ("http://example.com/panel/get.php", "http://example.com/panel"),
        ("http://example.com:80/xmltv.php", "http://example.com:80"),
    ])
    func normalises(input: String, expected: String) throws {
        #expect(try ServerURL.normalize(input).absoluteString == expected)
    }

    @Test func rejectsEmptyInput() {
        #expect(throws: ServerURLError.empty) { try ServerURL.normalize("   ") }
    }

    @Test func rejectsOtherSchemes() {
        #expect(throws: ServerURLError.unsupportedScheme("ftp")) { try ServerURL.normalize("ftp://example.com") }
    }

    @Test(arguments: [
        "http://alice:pw@example.com",
        "http://example.com/player_api.php?username=alice&password=pw",
    ])
    func rejectsEmbeddedCredentials(input: String) {
        #expect(throws: ServerURLError.containsCredentials) { try ServerURL.normalize(input) }
    }
}
