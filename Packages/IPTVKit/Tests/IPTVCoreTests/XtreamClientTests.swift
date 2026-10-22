import Foundation
import Testing
@testable import IPTVCore

@Suite("Xtream client: URLs and HTTP behaviour")
struct XtreamClientTests {
    func client(_ transport: StubTransport = StubTransport(),
                credentials: ProviderCredentials = ProviderCredentials(username: "alice", password: "p+ss/w&rd")) -> XtreamClient {
        XtreamClient(serverURL: URL(string: "http://example.test:8080")!, credentials: credentials, transport: transport,
                     userAgent: "TestAgent/1.0")
    }

    @Test func streamURLsFollowXtreamConventions() {
        let c = client(credentials: ProviderCredentials(username: "alice", password: "secret"))
        #expect(c.liveURL(streamID: 101, format: .ts).absoluteString == "http://example.test:8080/live/alice/secret/101.ts")
        #expect(c.liveURL(streamID: 101, format: .m3u8).absoluteString == "http://example.test:8080/live/alice/secret/101.m3u8")
        #expect(c.movieURL(streamID: 501, containerExtension: "mkv").absoluteString == "http://example.test:8080/movie/alice/secret/501.mkv")
        #expect(c.episodeURL(episodeID: "9001", containerExtension: nil).absoluteString == "http://example.test:8080/series/alice/secret/9001.mp4")
    }

    @Test func specialCharactersInCredentialsStayInOneSegment() {
        let url = client().liveURL(streamID: 1, format: .ts)
        #expect(url.pathComponents == ["/", "live", "alice", "p+ss/w&rd", "1.ts"])
        #expect(CredentialRedactor.redact(url).contains("/live/***/***/1.ts"))
    }

    @Test func apiRequestsEscapePlusAndSendUserAgent() async throws {
        let transport = StubTransport(["get_live_categories": "xtream/live_categories.json"])
        _ = try await client(transport).liveCategories()
        let request = try #require(transport.requests.first)
        let query = try #require(request.url?.query)
        #expect(query.contains("password=p%2Bss/w%26rd"))
        #expect(query.contains("action=get_live_categories"))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "TestAgent/1.0")
    }

    @Test(arguments: [
        (401, XtreamError.unauthorized), (403, .forbidden), (404, .notFound), (429, .rateLimited),
        (458, .maxConnectionsReached), (503, .server(statusCode: 503)), (418, .httpStatus(418)),
    ])
    func httpStatusesMapToSpecificErrors(status: Int, expected: XtreamError) async {
        let transport = StubTransport()
        transport.set("get_live_streams", body: "[]", status: status)
        await #expect(throws: expected) { try await client(transport).liveStreams() }
    }

    @Test(arguments: [
        (URLError(.timedOut), XtreamError.timeout),
        (URLError(.notConnectedToInternet), .offline),
        (URLError(.cancelled), .cancelled),
    ])
    func transportErrorsMap(error: URLError, expected: XtreamError) async {
        let transport = StubTransport()
        transport.fail("get_live_streams", with: error)
        await #expect(throws: expected) { try await client(transport).liveStreams() }
    }

    @Test func htmlInsteadOfJSONIsReportedClearly() async {
        let transport = StubTransport()
        transport.set("auth", body: "<html><body>Blocked</body></html>")
        await #expect(throws: XtreamError.invalidResponse("got HTML instead of JSON")) {
            try await client(transport).authenticate()
        }
    }

    @Test func emptyAuthBodyIsAnError() async {
        let transport = StubTransport()
        transport.set("auth", body: "")
        await #expect(throws: XtreamError.invalidResponse("empty body")) { try await client(transport).authenticate() }
    }

    @Test func errorMessagesNeverContainCredentials() {
        let all: [XtreamError] = [.unauthorized, .forbidden, .notFound, .maxConnectionsReached, .timeout, .offline,
                                  .cannotConnect(host: "example.test"), .server(statusCode: 500)]
        for error in all {
            #expect(!error.description.contains("alice"))
            #expect(!error.description.isEmpty)
        }
    }
}
