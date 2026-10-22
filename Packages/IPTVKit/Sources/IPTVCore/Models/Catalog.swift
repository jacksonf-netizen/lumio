import Foundation

/// What a category or library item belongs to.
public enum ContentKind: String, Sendable, Codable, CaseIterable {
    case live
    case movie
    case series
}

public struct Category: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    public var kind: ContentKind
    /// Provider's category id (Xtream returns these as strings or numbers; normalised to String).
    public var categoryID: String
    public var name: String
    public var parentID: String?
    /// Order as returned by the provider.
    public var sortIndex: Int
    /// Region the name's prefix belongs to ("US" for "NA | Sports"), used to hide whole regions.
    public var region: String?
    /// The provider's own spelling of that prefix ("NA"), so merges can be shown and undone.
    public var regionPrefix: String?

    public init(providerID: ProviderID, kind: ContentKind, categoryID: String, name: String,
                parentID: String? = nil, sortIndex: Int = 0) {
        self.providerID = providerID
        self.kind = kind
        self.categoryID = categoryID
        self.name = name
        self.parentID = parentID
        self.sortIndex = sortIndex
        regionPrefix = RegionPrefix.detectPrefix(name)
        region = regionPrefix.map { RegionPrefix.key(forPrefix: $0) }
    }
}

/// A single live stream from one provider.
public struct Channel: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    public var streamID: Int
    /// Provider's channel number, if any.
    public var number: Int?
    public var name: String
    public var logoURL: URL?
    /// XMLTV channel id used for EPG matching. Empty strings are normalised to nil.
    public var epgChannelID: String?
    public var categoryID: String?
    /// Catch-up support (kept for future archive playback; unused in v1).
    public var tvArchive: Bool
    public var tvArchiveDuration: Int
    public var addedAt: Date?
    public var isAdult: Bool
    /// Some providers give a direct upstream URL; kept for completeness.
    public var directSource: String?
    /// Order as returned by the provider.
    public var sortIndex: Int

    public init(providerID: ProviderID, streamID: Int, number: Int? = nil, name: String,
                logoURL: URL? = nil, epgChannelID: String? = nil, categoryID: String? = nil,
                tvArchive: Bool = false, tvArchiveDuration: Int = 0, addedAt: Date? = nil,
                isAdult: Bool = false, directSource: String? = nil, sortIndex: Int = 0) {
        self.providerID = providerID
        self.streamID = streamID
        self.number = number
        self.name = name
        self.logoURL = logoURL
        self.epgChannelID = epgChannelID
        self.categoryID = categoryID
        self.tvArchive = tvArchive
        self.tvArchiveDuration = tvArchiveDuration
        self.addedAt = addedAt
        self.isAdult = isAdult
        self.directSource = directSource
        self.sortIndex = sortIndex
    }
}

/// "The same channel" across providers. Derived by `ChannelMatcher`, rebuildable at any time.
/// `id` is the stable match key (e.g. `epg:bbcone.uk` or `name:bbc one`), so overrides keyed by it
/// survive a rebuild.
public struct LogicalChannel: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var logoURL: URL?

    public init(id: String, name: String, logoURL: URL? = nil) {
        self.id = id
        self.name = name
        self.logoURL = logoURL
    }
}

/// Membership of one provider's channel in a logical channel.
public struct LogicalChannelMember: Hashable, Sendable, Codable {
    public var logicalChannelID: String
    public var providerID: ProviderID
    public var streamID: Int

    public init(logicalChannelID: String, providerID: ProviderID, streamID: Int) {
        self.logicalChannelID = logicalChannelID
        self.providerID = providerID
        self.streamID = streamID
    }
}

/// Manual override of automatic channel matching.
public struct ChannelLinkOverride: Hashable, Sendable, Codable {
    public enum Action: String, Sendable, Codable {
        /// Force this channel into `targetLogicalChannelID`.
        case link
        /// Force this channel to stand alone.
        case unlink
    }

    public var providerID: ProviderID
    public var streamID: Int
    public var action: Action
    public var targetLogicalChannelID: String?

    public init(providerID: ProviderID, streamID: Int, action: Action, targetLogicalChannelID: String? = nil) {
        self.providerID = providerID
        self.streamID = streamID
        self.action = action
        self.targetLogicalChannelID = targetLogicalChannelID
    }
}

public struct Movie: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    public var streamID: Int
    public var name: String
    public var categoryID: String?
    public var posterURL: URL?
    public var rating: Double?
    public var year: Int?
    public var plot: String?
    public var tmdbID: String?
    public var containerExtension: String?
    public var durationSeconds: Int?
    public var addedAt: Date?
    public var sortIndex: Int

    public init(providerID: ProviderID, streamID: Int, name: String, categoryID: String? = nil,
                posterURL: URL? = nil, rating: Double? = nil, year: Int? = nil, plot: String? = nil,
                tmdbID: String? = nil, containerExtension: String? = nil, durationSeconds: Int? = nil,
                addedAt: Date? = nil, sortIndex: Int = 0) {
        self.providerID = providerID
        self.streamID = streamID
        self.name = name
        self.categoryID = categoryID
        self.posterURL = posterURL
        self.rating = rating
        self.year = year
        self.plot = plot
        self.tmdbID = tmdbID
        self.containerExtension = containerExtension
        self.durationSeconds = durationSeconds
        self.addedAt = addedAt
        self.sortIndex = sortIndex
    }
}

public struct Series: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    public var seriesID: Int
    public var name: String
    public var categoryID: String?
    public var coverURL: URL?
    public var plot: String?
    public var rating: Double?
    public var releaseDate: String?
    public var lastModified: Date?
    public var sortIndex: Int

    public init(providerID: ProviderID, seriesID: Int, name: String, categoryID: String? = nil,
                coverURL: URL? = nil, plot: String? = nil, rating: Double? = nil,
                releaseDate: String? = nil, lastModified: Date? = nil, sortIndex: Int = 0) {
        self.providerID = providerID
        self.seriesID = seriesID
        self.name = name
        self.categoryID = categoryID
        self.coverURL = coverURL
        self.plot = plot
        self.rating = rating
        self.releaseDate = releaseDate
        self.lastModified = lastModified
        self.sortIndex = sortIndex
    }
}

public struct Season: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    public var seriesID: Int
    public var seasonNumber: Int
    public var name: String?
    public var coverURL: URL?
    public var airDate: String?

    public init(providerID: ProviderID, seriesID: Int, seasonNumber: Int, name: String? = nil,
                coverURL: URL? = nil, airDate: String? = nil) {
        self.providerID = providerID
        self.seriesID = seriesID
        self.seasonNumber = seasonNumber
        self.name = name
        self.coverURL = coverURL
        self.airDate = airDate
    }
}

public struct Episode: Hashable, Sendable, Codable {
    public var providerID: ProviderID
    /// Xtream episode ids are strings in some panels and numbers in others; normalised to String.
    public var episodeID: String
    public var seriesID: Int
    public var seasonNumber: Int
    public var episodeNumber: Int
    public var title: String
    public var containerExtension: String?
    public var durationSeconds: Int?
    public var plot: String?
    public var imageURL: URL?
    public var airDate: String?

    public init(providerID: ProviderID, episodeID: String, seriesID: Int, seasonNumber: Int,
                episodeNumber: Int, title: String, containerExtension: String? = nil,
                durationSeconds: Int? = nil, plot: String? = nil, imageURL: URL? = nil,
                airDate: String? = nil) {
        self.providerID = providerID
        self.episodeID = episodeID
        self.seriesID = seriesID
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.title = title
        self.containerExtension = containerExtension
        self.durationSeconds = durationSeconds
        self.plot = plot
        self.imageURL = imageURL
        self.airDate = airDate
    }
}
