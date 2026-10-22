import Foundation
import zlib
@testable import IPTVCore

enum Fixture {
    static func url(_ path: String) -> URL {
        guard let url = Bundle.module.url(forResource: "Fixtures/\(path)", withExtension: nil) else {
            fatalError("Missing fixture \(path)")
        }
        return url
    }

    static func data(_ path: String) -> Data {
        try! Data(contentsOf: url(path))
    }

    /// Writes a gzip copy of a fixture to a temp file.
    static func gzipped(_ path: String) -> URL {
        let source = data(path)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).xml.gz")
        let gz = gzopen(output.path, "wb")!
        _ = source.withUnsafeBytes { gzwrite(gz, $0.baseAddress, UInt32(source.count)) }
        gzclose(gz)
        return output
    }

    /// Copies a fixture to a temp file the caller may delete (downloads are deleted after import).
    static func temporaryCopy(_ path: String) -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).xml")
        try! data(path).write(to: output)
        return output
    }
}

/// Serves canned responses keyed by `action` (or "auth" for no action, "xmltv" for the guide).
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var body: Data
    }

    private let lock = NSLock()
    private var responses: [String: Response] = [:]
    private var errors: [String: Error] = [:]
    private(set) var requests: [URLRequest] = []
    private var _delay: Duration?
    /// Makes every answer slow (a provider under load). Cancellation ends the wait.
    var delay: Duration? {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    init(_ routes: [String: String] = [:]) {
        for (key, fixture) in routes { set(key, fixture: fixture) }
    }

    func set(_ key: String, fixture: String, status: Int = 200) {
        lock.withLock { responses[key] = Response(status: status, body: Fixture.data(fixture)) }
    }

    func set(_ key: String, body: String, status: Int = 200) {
        lock.withLock { responses[key] = Response(status: status, body: Data(body.utf8)) }
    }

    func fail(_ key: String, with error: Error) {
        lock.withLock { errors[key] = error }
    }

    var requestedActions: [String] {
        lock.withLock { requests.map(Self.key(for:)) }
    }

    static func key(for request: URLRequest) -> String {
        let url = request.url!
        if url.lastPathComponent == "xmltv.php" { return "xmltv" }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.first { $0.name == "action" }?.value ?? "auth"
    }

    private func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let key = Self.key(for: request)
        let (response, error) = lock.withLock { () -> (Response?, Error?) in
            requests.append(request)
            return (responses[key], errors[key])
        }
        if let error { throw error }
        let found = response ?? Response(status: 404, body: Data())
        let http = HTTPURLResponse(url: request.url!, statusCode: found.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (found.body, http)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // The answer reflects the moment the request was made, like a real server.
        let answer = Result { try respond(request) }
        if let delay { try await Task.sleep(for: delay) }
        return try answer.get()
    }

    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (data, http) = try respond(request)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stub-\(UUID().uuidString)")
        try data.write(to: file)
        return (file, http)
    }
}

/// A clock that only moves when told to, and whose sleeps return immediately after advancing.
final class ManualClock: AppClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private(set) var sleeps: [Duration] = []

    init(_ now: Date) { current = now }

    func now() -> Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current.addTimeInterval(seconds) }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        lock.withLock {
            sleeps.append(duration)
            current.addTimeInterval(Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
        }
        await Task.yield()
    }
}

extension Date {
    /// 2026-10-17 20:00:00 UTC, the "now" the fixtures are written around.
    static let fixtureNow = XMLTVDate.parse("20261017200000 +0000")!
}

/// Factory that returns Xtream sources over stub transports, one per provider.
struct StubSourceFactory: SourceFactory {
    let transports: [ProviderID: StubTransport]

    func source(for provider: Provider) throws -> any SourceProvider {
        guard let transport = transports[provider.id] else { throw SourceFactoryError.missingCredentials }
        return XtreamSourceProvider(provider: provider, credentials: ProviderCredentials(username: "user", password: "pass"),
                                    transport: transport)
    }
}

extension StubTransport {
    /// A full, healthy provider.
    static func healthyProvider(guide: String = "xmltv/guide.xml") -> StubTransport {
        StubTransport([
            "auth": "xtream/auth_ok.json",
            "get_live_categories": "xtream/live_categories.json",
            "get_live_streams": "xtream/live_streams.json",
            "get_vod_categories": "xtream/live_categories.json",
            "get_vod_streams": "xtream/vod_streams.json",
            "get_series_categories": "xtream/live_categories.json",
            "get_series": "xtream/series.json",
            "xmltv": guide,
        ])
    }
}
