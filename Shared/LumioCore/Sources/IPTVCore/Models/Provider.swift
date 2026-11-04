import Foundation

/// Stable identifier for a provider (one Xtream account). Every provider-owned record carries one.
public struct ProviderID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public static func make() -> ProviderID { ProviderID(UUID().uuidString.lowercased()) }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The kind of source behind a provider. Only Xtream exists in v1; M3U and Stalker are future
/// `SourceProvider` implementations.
public enum SourceKind: String, Sendable, Codable, CaseIterable {
    case xtream
}

/// A configured provider account. Credentials are NOT stored here; they live in the Keychain
/// (see `SecretStore`). Only non-secret configuration and last-known account status is persisted.
public struct Provider: Identifiable, Hashable, Sendable, Codable {
    public var id: ProviderID
    public var name: String
    public var kind: SourceKind
    /// Base server URL, e.g. `http://example.com:8080`. Never contains credentials.
    public var serverURL: URL
    /// Lower value = preferred when choosing a source for a logical channel.
    public var priority: Int
    public var isEnabled: Bool
    public var createdAt: Date

    // Last-known account status from `user_info`.
    public var accountStatus: String?
    public var expiresAt: Date?
    public var maxConnections: Int?
    public var activeConnections: Int?
    /// e.g. ["ts", "m3u8"]
    public var allowedOutputFormats: [String]

    // Refresh bookkeeping.
    public var lastRefreshAt: Date?
    public var lastError: String?

    /// Applied when reading EPG times from this provider (minutes, may be negative).
    public var epgTimeOffsetMinutes: Int
    /// Overrides the global user-agent for this provider when set.
    public var userAgentOverride: String?

    public init(
        id: ProviderID = .make(),
        name: String,
        kind: SourceKind = .xtream,
        serverURL: URL,
        priority: Int = 0,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        accountStatus: String? = nil,
        expiresAt: Date? = nil,
        maxConnections: Int? = nil,
        activeConnections: Int? = nil,
        allowedOutputFormats: [String] = [],
        lastRefreshAt: Date? = nil,
        lastError: String? = nil,
        epgTimeOffsetMinutes: Int = 0,
        userAgentOverride: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.serverURL = serverURL
        self.priority = priority
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.accountStatus = accountStatus
        self.expiresAt = expiresAt
        self.maxConnections = maxConnections
        self.activeConnections = activeConnections
        self.allowedOutputFormats = allowedOutputFormats
        self.lastRefreshAt = lastRefreshAt
        self.lastError = lastError
        self.epgTimeOffsetMinutes = epgTimeOffsetMinutes
        self.userAgentOverride = userAgentOverride
    }
}

/// Username and password for a provider. Only ever held in memory or in the Keychain.
public struct ProviderCredentials: Hashable, Sendable, Codable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

extension ProviderCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    // Keep credentials out of string interpolation, `print` and debugger summaries.
    public var description: String { "ProviderCredentials(username: ***, password: ***)" }
    public var debugDescription: String { description }
}
