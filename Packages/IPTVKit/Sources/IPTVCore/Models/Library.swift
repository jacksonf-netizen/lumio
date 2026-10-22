import Foundation

/// What a favorite, recent or progress record points at. Ids are stored as strings so one table
/// can hold channels (stream id), movies (stream id) and episodes (episode id).
public enum LibraryItemKind: String, Sendable, Codable, CaseIterable {
    case channel
    case movie
    case series
    case episode
}

/// Favorites always point at a concrete provider item. In the unified view a logical channel is a
/// favorite when any of its sources is.
public struct Favorite: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    public var itemKind: LibraryItemKind
    public var itemID: String
    public var addedAt: Date
    public var sortIndex: Int

    public init(providerID: ProviderID, itemKind: LibraryItemKind, itemID: String,
                addedAt: Date = Date(), sortIndex: Int = 0) {
        self.providerID = providerID
        self.itemKind = itemKind
        self.itemID = itemID
        self.addedAt = addedAt
        self.sortIndex = sortIndex
    }
}

public struct WatchProgress: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    public var itemKind: LibraryItemKind
    public var itemID: String
    public var positionSeconds: Double
    public var durationSeconds: Double?
    public var isWatched: Bool
    public var updatedAt: Date

    public init(providerID: ProviderID, itemKind: LibraryItemKind, itemID: String,
                positionSeconds: Double, durationSeconds: Double? = nil, isWatched: Bool = false,
                updatedAt: Date = Date()) {
        self.providerID = providerID
        self.itemKind = itemKind
        self.itemID = itemID
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.isWatched = isWatched
        self.updatedAt = updatedAt
    }
}

public struct RecentItem: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    public var itemKind: LibraryItemKind
    public var itemID: String
    public var lastPlayedAt: Date

    public init(providerID: ProviderID, itemKind: LibraryItemKind, itemID: String, lastPlayedAt: Date = Date()) {
        self.providerID = providerID
        self.itemKind = itemKind
        self.itemID = itemID
        self.lastPlayedAt = lastPlayedAt
    }
}

/// Which playback engine to use.
public enum EngineKind: String, Sendable, Codable, CaseIterable {
    case mpv
    case avPlayer
}

/// Stream container requested from an Xtream server.
public enum StreamFormat: String, Sendable, Codable, CaseIterable {
    case ts
    case m3u8
}

/// User customisation of a single channel.
public struct ChannelOverride: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    public var streamID: Int
    public var isHidden: Bool
    public var customName: String?
    /// User sort order; nil keeps the provider's order.
    public var sortIndex: Int?
    public var engine: EngineKind?
    public var preferredFormat: StreamFormat?

    public init(providerID: ProviderID, streamID: Int, isHidden: Bool = false, customName: String? = nil,
                sortIndex: Int? = nil, engine: EngineKind? = nil, preferredFormat: StreamFormat? = nil) {
        self.providerID = providerID
        self.streamID = streamID
        self.isHidden = isHidden
        self.customName = customName
        self.sortIndex = sortIndex
        self.engine = engine
        self.preferredFormat = preferredFormat
    }
}

/// User customisation of a category (group).
public struct CategoryOverride: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    public var kind: ContentKind
    public var categoryID: String
    public var isHidden: Bool
    /// Shown even though its region is switched off (Settings → Regions), for when a group was
    /// filed under the wrong region.
    public var isShown: Bool
    public var customName: String?
    public var sortIndex: Int?

    public init(providerID: ProviderID, kind: ContentKind, categoryID: String, isHidden: Bool = false,
                isShown: Bool = false, customName: String? = nil, sortIndex: Int? = nil) {
        self.providerID = providerID
        self.kind = kind
        self.categoryID = categoryID
        self.isHidden = isHidden
        self.isShown = isShown
        self.customName = customName
        self.sortIndex = sortIndex
    }

    // Backups made before `isShown` existed don't have it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decode(ProviderID.self, forKey: .providerID)
        kind = try container.decode(ContentKind.self, forKey: .kind)
        categoryID = try container.decode(String.self, forKey: .categoryID)
        isHidden = try container.decode(Bool.self, forKey: .isHidden)
        isShown = try container.decodeIfPresent(Bool.self, forKey: .isShown) ?? false
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        sortIndex = try container.decodeIfPresent(Int.self, forKey: .sortIndex)
    }
}

/// A user-defined channel group. Groups span providers; their members are provider-keyed.
public struct CustomGroup: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var sortIndex: Int

    public init(id: String = UUID().uuidString.lowercased(), name: String, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
    }
}

public struct CustomGroupMember: Hashable, Sendable, Codable {
    public var groupID: String
    public var providerID: ProviderID
    public var streamID: Int
    public var sortIndex: Int

    public init(groupID: String, providerID: ProviderID, streamID: Int, sortIndex: Int = 0) {
        self.groupID = groupID
        self.providerID = providerID
        self.streamID = streamID
        self.sortIndex = sortIndex
    }
}

/// What has worked (or not) for a given source. Feeds source selection and the fallback ladder.
public struct PlaybackHistory: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    public var streamID: Int
    public var successCount: Int
    public var failureCount: Int
    /// Exponentially weighted success rate in 0...1.
    public var reliabilityScore: Double
    public var lastWorkingFormat: StreamFormat?
    public var lastWorkingEngine: EngineKind?
    public var lastSuccessAt: Date?
    public var lastFailureAt: Date?
    public var lastError: String?

    public init(providerID: ProviderID, streamID: Int, successCount: Int = 0, failureCount: Int = 0,
                reliabilityScore: Double = 0.5, lastWorkingFormat: StreamFormat? = nil,
                lastWorkingEngine: EngineKind? = nil, lastSuccessAt: Date? = nil,
                lastFailureAt: Date? = nil, lastError: String? = nil) {
        self.providerID = providerID
        self.streamID = streamID
        self.successCount = successCount
        self.failureCount = failureCount
        self.reliabilityScore = reliabilityScore
        self.lastWorkingFormat = lastWorkingFormat
        self.lastWorkingEngine = lastWorkingEngine
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.lastError = lastError
    }
}

/// Where a setting applies.
public enum SettingScope: Hashable, Sendable {
    case global
    case provider(ProviderID)
    case channel(ProviderID, streamID: Int)

    /// Stable string form used as part of the primary key.
    public var key: String {
        switch self {
        case .global: "global"
        case .provider(let id): "provider:\(id.rawValue)"
        case .channel(let id, let streamID): "channel:\(id.rawValue):\(streamID)"
        }
    }

    public var providerID: ProviderID? {
        switch self {
        case .global: nil
        case .provider(let id), .channel(let id, _): id
        }
    }
}

/// One stored setting. `value` is JSON so any Codable value can be stored.
public struct SettingRecord: Hashable, Sendable, Codable {
    public var scopeKey: String
    /// Set for provider- and channel-scoped settings so they cascade-delete with the provider.
    public var providerID: ProviderID?
    public var key: String
    public var value: String

    public init(scope: SettingScope, key: String, value: String) {
        self.scopeKey = scope.key
        self.providerID = scope.providerID
        self.key = key
        self.value = value
    }
}
