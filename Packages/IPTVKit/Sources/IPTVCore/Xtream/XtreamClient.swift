import Foundation

/// Typed async client for one Xtream Codes account (`player_api.php` and `xmltv.php`).
public struct XtreamClient: Sendable {
    public let serverURL: URL
    private let credentials: ProviderCredentials
    private let transport: any HTTPTransport
    public let userAgent: String

    static let maxGuideDownloadBytes = 2 << 30
    public static let defaultUserAgent = "Lumio/0.1 (Macintosh; Apple silicon)"

    public init(serverURL: URL, credentials: ProviderCredentials, transport: any HTTPTransport,
                userAgent: String = XtreamClient.defaultUserAgent) {
        self.serverURL = serverURL
        self.credentials = credentials
        self.transport = transport
        self.userAgent = HTTPHeader.sanitized(userAgent, fallback: XtreamClient.defaultUserAgent)
    }

    // MARK: Account

    /// `player_api.php` with no action: account and server info. Throws on bad credentials or an
    /// inactive / expired account.
    func authenticate() async throws -> XtreamAuthResponse {
        let response: XtreamAuthResponse = try await get(action: nil)
        guard let user = response.userInfo, user.auth else { throw XtreamError.unauthorized }
        if let status = user.status, status.lowercased() != "active" {
            if status.lowercased() == "expired" { throw XtreamError.accountExpired(user.expiresAt) }
            throw XtreamError.accountNotActive(status: status)
        }
        if let expiry = user.expiresAt, expiry < Date() { throw XtreamError.accountExpired(expiry) }
        return response
    }

    // MARK: Catalog

    func liveCategories() async throws -> [XtreamCategory] {
        try await getArray(action: "get_live_categories")
    }

    func vodCategories() async throws -> [XtreamCategory] {
        try await getArray(action: "get_vod_categories")
    }

    func seriesCategories() async throws -> [XtreamCategory] {
        try await getArray(action: "get_series_categories")
    }

    func liveStreams() async throws -> [XtreamLiveStream] {
        try await getArray(action: "get_live_streams")
    }

    func vodStreams() async throws -> [XtreamVODStream] {
        try await getArray(action: "get_vod_streams")
    }

    func series() async throws -> [XtreamSeries] {
        try await getArray(action: "get_series")
    }

    func vodInfo(streamID: Int) async throws -> XtreamVODInfo {
        try await get(action: "get_vod_info", extra: [URLQueryItem(name: "vod_id", value: String(streamID))])
    }

    func seriesInfo(seriesID: Int) async throws -> XtreamSeriesInfo {
        try await get(action: "get_series_info", extra: [URLQueryItem(name: "series_id", value: String(seriesID))])
    }

    func shortEPG(streamID: Int, limit: Int = 4) async throws -> XtreamShortEPG {
        try await get(action: "get_short_epg", extra: [
            URLQueryItem(name: "stream_id", value: String(streamID)),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    /// Downloads the full XMLTV guide to a temporary file (caller deletes it). It may be gzipped.
    func downloadXMLTV() async throws -> URL {
        let request = makeRequest(url: endpoint("xmltv.php", query: []), timeout: 300)
        do {
            let (file, response) = try await transport.download(for: request)
            if let error = XtreamError.from(statusCode: response.statusCode) {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            // Real guides are tens to a few hundred megabytes; refuse anything absurd.
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > Self.maxGuideDownloadBytes {
                try? FileManager.default.removeItem(at: file)
                throw XtreamError.invalidResponse("the guide file is \(size >> 20) MB, over the \(Self.maxGuideDownloadBytes >> 20) MB limit")
            }
            return file
        } catch {
            throw XtreamError.from(error)
        }
    }

    // MARK: Stream URLs

    public func liveURL(streamID: Int, format: StreamFormat) -> URL {
        streamURL(kind: "live", id: String(streamID), ext: format.rawValue)
    }

    public func movieURL(streamID: Int, containerExtension: String?) -> URL {
        streamURL(kind: "movie", id: String(streamID), ext: containerExtension ?? "mp4")
    }

    public func episodeURL(episodeID: String, containerExtension: String?) -> URL {
        streamURL(kind: "series", id: episodeID, ext: containerExtension ?? "mp4")
    }

    /// `{server}/{kind}/{user}/{pass}/{id}.{ext}` with path-safe escaping of the credentials.
    private func streamURL(kind: String, id: String, ext: String) -> URL {
        var url = serverURL
        url.append(component: kind)
        // `component` escapes "/" too, so a password containing a slash stays one path segment.
        url.append(component: credentials.username)
        url.append(component: credentials.password)
        url.append(component: "\(id).\(ext)")
        return url
    }

    // MARK: Requests

    private func endpoint(_ file: String, query: [URLQueryItem]) -> URL {
        var url = serverURL
        url.append(path: file)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password),
        ] + query
        // `+` in a password must be escaped or PHP decodes it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }

    private func makeRequest(url: URL, timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, */*", forHTTPHeaderField: "Accept")
        return request
    }

    private func fetch(action: String?, extra: [URLQueryItem]) async throws -> Data {
        var query = extra
        if let action { query.insert(URLQueryItem(name: "action", value: action), at: 0) }
        let request = makeRequest(url: endpoint("player_api.php", query: query))
        let started = ContinuousClock.now
        do {
            let (data, response) = try await transport.data(for: request)
            let elapsed = ContinuousClock.now - started
            Log.network.debug("""
                \(action ?? "auth", privacy: .public) → \(response.statusCode) \
                \(data.count) bytes in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)
                """)
            if let error = XtreamError.from(statusCode: response.statusCode) { throw error }
            return data
        } catch {
            let mapped = XtreamError.from(error)
            Log.network.error("\(action ?? "auth", privacy: .public) failed: \(mapped.description, privacy: .public)")
            throw mapped
        }
    }

    private func get<T: Decodable>(action: String?, extra: [URLQueryItem] = []) async throws -> T {
        let data = try await fetch(action: action, extra: extra)
        guard !Self.isBlank(data) else { throw XtreamError.invalidResponse("empty body") }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Self.decodingError(error, data: data)
        }
    }

    /// Lists come back as arrays, but panels also send `{}`, `null`, `""` or an error object when
    /// there is nothing. Those decode as an empty list; malformed elements are skipped.
    private func getArray<T: Decodable>(action: String, extra: [URLQueryItem] = []) async throws -> [T] {
        let data = try await fetch(action: action, extra: extra)
        if Self.isBlank(data) { return [] }
        if let items = try? JSONDecoder().decode([FailableDecodable<T>].self, from: data) {
            return items.compactMap(\.value)
        }
        // Some panels return {"0": {...}, "1": {...}} instead of an array.
        if let dict = try? JSONDecoder().decode([String: FailableDecodable<T>].self, from: data) {
            return dict.sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.compactMap(\.value.value)
        }
        if (try? JSONDecoder().decode(AnyDecodable.self, from: data)) != nil { return [] }
        throw Self.decodingError(nil, data: data)
    }

    private static func isBlank(_ data: Data) -> Bool {
        let text = String(decoding: data.prefix(16), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == "null" || text == "\"\"" || (data.count <= 4 && (text == "{}" || text == "[]"))
    }

    private static func decodingError(_ error: Error?, data: Data) -> XtreamError {
        let head = String(decoding: data.prefix(64), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("<") { return .invalidResponse("got HTML instead of JSON") }
        if let error { return XtreamError.from(error) }
        return .decoding("unrecognised JSON")
    }
}
