import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The network seam. The app uses `URLSessionTransport`; tests use a stub that serves fixtures.
public protocol HTTPTransport: Sendable {
    /// Performs a request and returns the body. Redirects are followed.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Downloads a (possibly very large) body to a temporary file that the caller owns.
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    /// Guide downloads: a big guide from a slow panel can take far longer than an API call. A
    /// stalled one still fails after the request's own timeout without data.
    private let downloads: URLSession

    public init(session: URLSession = URLSessionTransport.makeSession(),
                downloads: URLSession = URLSessionTransport.makeSession(resourceTimeout: 3600)) {
        self.session = session
        self.downloads = downloads
    }

    /// A session with no shared cookie or URL cache (API responses are cached in our own database).
    public static func makeSession(requestTimeout: TimeInterval = 30, resourceTimeout: TimeInterval = 600) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.httpMaximumConnectionsPerHost = 4
        #if canImport(Darwin)
        // Fail at once when offline (swift-corelibs-foundation never waits and can't set this).
        config.waitsForConnectivity = false
        #endif
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XtreamError.invalidResponse("not an HTTP response") }
        return (data, http)
    }

    public func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        let (tempURL, response) = try await downloads.download(for: request)
        guard let http = response as? HTTPURLResponse else { throw XtreamError.invalidResponse("not an HTTP response") }
        // URLSession deletes its temp file when this call returns; move it somewhere we control.
        let owned = FileManager.default.temporaryDirectory
            .appendingPathComponent("iptv-\(UUID().uuidString)")
            .appendingPathExtension(request.url?.pathExtension.isEmpty == false ? request.url!.pathExtension : "download")
        try FileManager.default.moveItem(at: tempURL, to: owned)
        return (owned, http)
    }
}
