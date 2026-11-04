import Foundation

/// A `<channel>` entry from a provider's XMLTV guide.
public struct EPGChannel: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    /// XMLTV channel id (matches `Channel.epgChannelID`).
    public var epgID: String
    public var displayName: String?
    public var iconURL: URL?

    public init(providerID: ProviderID, epgID: String, displayName: String? = nil, iconURL: URL? = nil) {
        self.providerID = providerID
        self.epgID = epgID
        self.displayName = displayName
        self.iconURL = iconURL
    }
}

/// A `<programme>` entry. Times are stored exactly as published (UTC); the per-provider
/// `epgTimeOffsetMinutes` is applied when reading, so changing the offset needs no re-import.
public struct Programme: Hashable, Sendable, Codable {
    public var id: Int64?
    public var providerID: ProviderID
    public var epgID: String
    public var start: Date
    public var stop: Date
    public var title: String
    public var subtitle: String?
    public var summary: String?
    public var category: String?
    public var episodeNumber: String?
    public var iconURL: URL?
    /// When the row was last written by a guide import (nil for rows from other sources).
    public var importedAt: Date?

    public init(id: Int64? = nil, providerID: ProviderID, epgID: String, start: Date, stop: Date,
                title: String, subtitle: String? = nil, summary: String? = nil, category: String? = nil,
                episodeNumber: String? = nil, iconURL: URL? = nil, importedAt: Date? = nil) {
        self.id = id
        self.providerID = providerID
        self.epgID = epgID
        self.start = start
        self.stop = stop
        self.title = title
        self.subtitle = subtitle
        self.summary = summary
        self.category = category
        self.episodeNumber = episodeNumber
        self.iconURL = iconURL
        self.importedAt = importedAt
    }
}

/// Manual EPG match for one provider's channel: use `epgID` from `epgProviderID`'s guide.
public struct EPGMappingOverride: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    public var streamID: Int
    public var epgProviderID: ProviderID
    public var epgID: String

    public init(providerID: ProviderID, streamID: Int, epgProviderID: ProviderID, epgID: String) {
        self.providerID = providerID
        self.streamID = streamID
        self.epgProviderID = epgProviderID
        self.epgID = epgID
    }
}

/// For a logical channel, use this provider's EPG data instead of the automatic choice.
public struct LogicalEPGOverride: Hashable, Sendable, Codable {
    public var logicalChannelID: String
    public var epgProviderID: ProviderID
    public var epgID: String

    public init(logicalChannelID: String, epgProviderID: ProviderID, epgID: String) {
        self.logicalChannelID = logicalChannelID
        self.epgProviderID = epgProviderID
        self.epgID = epgID
    }
}
