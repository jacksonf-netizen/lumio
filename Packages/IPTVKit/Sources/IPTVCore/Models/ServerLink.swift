import Foundation

/// One of a provider's server addresses. Sellers hand out several for the same account because
/// they go down; the provider's `serverURL` is the one in use, and `ServerFailover` moves it down
/// this list when it stops answering.
public struct ServerLink: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    /// The user's order: 0 is preferred.
    public var position: Int
    /// Base URL like `http://host:8080`. Never contains credentials.
    public var url: URL
    public var lastCheckedAt: Date?
    /// Set when a check found the server unreachable; cleared when it answers again. Kept while it
    /// stays down, so it's when the link went down.
    public var downSince: Date?
    /// Why the last check failed, for Settings.
    public var lastFailure: String?

    public init(providerID: ProviderID, position: Int, url: URL, lastCheckedAt: Date? = nil,
                downSince: Date? = nil, lastFailure: String? = nil) {
        self.providerID = providerID
        self.position = position
        self.url = url
        self.lastCheckedAt = lastCheckedAt
        self.downSince = downSince
        self.lastFailure = lastFailure
    }

    public var isDown: Bool { downSince != nil }

    /// Still down a day after it first failed (two checks at least a day apart). Automatic checks
    /// skip a dead link unless none of the provider's other links work; see `ServerFailover`.
    public var isDead: Bool {
        guard let downSince, let lastCheckedAt else { return false }
        return lastCheckedAt.timeIntervalSince(downSince) >= Self.deadAfter
    }

    public static let deadAfter: TimeInterval = 24 * 3600
}

extension Array where Element == ServerLink {
    /// True when there's at least one link and every one of them failed its last check.
    public var allDown: Bool { !isEmpty && allSatisfy(\.isDown) }
}

/// Maps a provider's dead links to the one in use, so logos and posters it serves from its own
/// (now dead) address still load from the working one. An address some provider uses is never
/// mapped, so two accounts from the same seller don't send each other's images elsewhere.
public final class ServerAliases: @unchecked Sendable {
    public static let shared = ServerAliases()

    private let lock = NSLock()
    /// "http://dead:8080" → "http://working:8080"
    private var map: [String: String] = [:]

    public func update(_ links: [ServerLink], active: [ProviderID: URL]) {
        let inUse = Set(active.values.compactMap(Self.origin))
        var map: [String: String] = [:]
        for link in links where link.isDown {
            guard let current = active[link.providerID], let from = Self.origin(link.url), !inUse.contains(from),
                  let to = Self.origin(current) else { continue }
            map[from] = to
        }
        lock.withLock { self.map = map }
    }

    public func rewrite(_ url: URL) -> URL {
        guard let origin = Self.origin(url), let target = lock.withLock({ map[origin] }) else { return url }
        return URL(string: target + url.absoluteString.dropFirst(origin.count)) ?? url
    }

    /// "scheme://host:port", exactly as it starts the URL's string.
    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host(percentEncoded: true) else { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = url.port { origin += ":\(port)" }
        return url.absoluteString.lowercased().hasPrefix(origin.lowercased()) ? String(url.absoluteString.prefix(origin.count)) : nil
    }
}
