import Foundation
import Testing
@testable import IPTVCore

/// Untrusted provider data can't point the app at local files or inject HTTP headers, and huge
/// guide files can't fill the disk.
@Suite("Security hardening")
struct SecurityHardeningTests {
    @Test func providerLinksMustBeWebLinks() throws {
        let json = #"""
        [{"stream_id": 1, "name": "A", "stream_icon": "file:///etc/passwd"},
         {"stream_id": 2, "name": "B", "stream_icon": "javascript:alert(1)"},
         {"stream_id": 3, "name": "C", "stream_icon": "data:image/png;base64,AAAA"},
         {"stream_id": 4, "name": "D", "stream_icon": "http://logos.example/d.png"},
         {"stream_id": 5, "name": "E", "stream_icon": "https://logos.example/e logo.png"}]
        """#
        let streams = try JSONDecoder().decode([XtreamLiveStream].self, from: Data(json.utf8))
        #expect(streams.map(\.icon?.absoluteString) == [nil, nil, nil, "http://logos.example/d.png", "https://logos.example/e%20logo.png"])
    }

    @Test func guideIconsMustBeWebLinks() throws {
        let xml = """
        <tv><channel id="a"><display-name>A</display-name><icon src="file:///Users/me/secret.png"/></channel>
        <channel id="b"><display-name>B</display-name><icon src="https://img.example/b.png"/></channel></tv>
        """
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("icons-\(UUID().uuidString).xml")
        try Data(xml.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var channels: [XMLTVChannel] = []
        _ = XMLTVParser(onChannel: { channels.append($0) }, onProgramme: { _ in }).parse(fileAt: file)
        #expect(channels.map(\.iconURL?.absoluteString) == [nil, "https://img.example/b.png"])
    }

    @Test func headerValuesCantCarryLineBreaks() {
        #expect(HTTPHeader.sanitized("VLC/3.0\r\nX-Evil: 1", fallback: "x") == "VLC/3.0X-Evil: 1")
        #expect(HTTPHeader.sanitized("  \n ", fallback: "fallback") == "fallback")
        #expect(HTTPHeader.sanitized(String(repeating: "a", count: 2000), fallback: "x").count == 512)
        let request = EngineRequest(url: URL(string: "http://p.test/live/a/b/1.ts")!, isLive: true, userAgent: "UA\nInjected: yes")
        #expect(!request.userAgent.contains("\n"))
        let client = XtreamClient(serverURL: URL(string: "http://p.test")!, credentials: ProviderCredentials(username: "u", password: "p"),
                                  transport: StubTransport(), userAgent: "Agent\r\n")
        #expect(client.userAgent == "Agent")
    }

    @Test func oversizedGuidesAreCutOff() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).xml")
        try Data(String(repeating: "<tv>" + String(repeating: "x", count: 1000) + "</tv>", count: 200).utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let staged = try XMLTVStaging.stage(source, chunkSize: 4096, limit: 20_000)
        defer { try? FileManager.default.removeItem(at: staged) }
        let size = try staged.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        #expect(size >= 20_000 && size < 30_000)
    }
}
