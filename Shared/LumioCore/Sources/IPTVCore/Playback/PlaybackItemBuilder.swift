import Foundation
import GRDB

/// Builds `PlaybackItem`s from the database: every enabled provider's copy of a channel, with its
/// allowed formats, per-channel overrides and playback history.
public struct PlaybackItemBuilder: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// The logical channel containing this provider channel, with all its sources.
    public func liveItem(providerID: ProviderID, streamID: Int) throws -> PlaybackItem? {
        try database.reader.read { db in
            let logicalID = try String.fetchOne(db, sql: """
                SELECT logicalChannelID FROM logicalChannelMember WHERE providerID = ? AND streamID = ?
                """, arguments: [providerID, streamID])
            if let logicalID {
                return try Self.liveItem(logicalID: logicalID, preferring: providerID, db: db)
            }
            // Not matched yet (e.g. right after a sync): play it on its own.
            guard let channel = try Channel.fetchOne(db, key: ["providerID": providerID.rawValue, "streamID": streamID]),
                  let provider = try Provider.fetchOne(db, key: providerID), provider.isEnabled
            else { return nil }
            let source = try Self.source(channel: channel, provider: provider, db: db)
            return PlaybackItem(id: "solo:\(providerID.rawValue):\(streamID)", title: channel.name, content: .live,
                                sources: [source], logoURL: channel.logoURL)
        }
    }

    public func liveItem(logicalChannelID: String) throws -> PlaybackItem? {
        try database.reader.read { db in try Self.liveItem(logicalID: logicalChannelID, preferring: nil, db: db) }
    }

    public func movieItem(providerID: ProviderID, streamID: Int, startPosition: Double? = nil) throws -> PlaybackItem? {
        try database.reader.read { db in
            guard let movie = try Movie.fetchOne(db, key: ["providerID": providerID.rawValue, "streamID": streamID]),
                  let provider = try Provider.fetchOne(db, key: providerID)
            else { return nil }
            let source = PlaybackSource(providerID: providerID, itemID: String(streamID), providerName: provider.name,
                                        providerPriority: provider.priority, containerExtension: movie.containerExtension)
            return PlaybackItem(id: "movie:\(providerID.rawValue):\(streamID)", title: movie.name, content: .movie,
                                sources: [source], startPosition: startPosition, logoURL: movie.posterURL)
        }
    }

    public func episodeItem(providerID: ProviderID, episodeID: String, startPosition: Double? = nil) throws -> PlaybackItem? {
        try database.reader.read { db in
            guard let episode = try Episode.fetchOne(db, key: ["providerID": providerID.rawValue, "episodeID": episodeID]),
                  let provider = try Provider.fetchOne(db, key: providerID)
            else { return nil }
            let series = try Series.fetchOne(db, key: ["providerID": providerID.rawValue, "seriesID": episode.seriesID])
            let source = PlaybackSource(providerID: providerID, itemID: episodeID, providerName: provider.name,
                                        providerPriority: provider.priority, containerExtension: episode.containerExtension)
            let title = [series?.name, "S\(episode.seasonNumber) E\(episode.episodeNumber)", episode.title]
                .compactMap { $0 }.joined(separator: " · ")
            return PlaybackItem(id: "episode:\(providerID.rawValue):\(episodeID)", title: title, content: .episode,
                                sources: [source], startPosition: startPosition, logoURL: episode.imageURL ?? series?.coverURL)
        }
    }

    // MARK: Helpers

    private static func liveItem(logicalID: String, preferring preferred: ProviderID?, db: Database) throws -> PlaybackItem? {
        guard let logical = try LogicalChannel.fetchOne(db, key: logicalID) else { return nil }
        let rows = try Row.fetchAll(db, sql: """
            SELECT channel.*, provider.id AS pid FROM logicalChannelMember m
            JOIN channel ON channel.providerID = m.providerID AND channel.streamID = m.streamID
            JOIN provider ON provider.id = m.providerID
            WHERE m.logicalChannelID = ? AND provider.isEnabled
            ORDER BY provider.priority
            """, arguments: [logicalID])
        let providers = Dictionary(uniqueKeysWithValues: try Provider.fetchAll(db).map { ($0.id, $0) })
        var sources: [PlaybackSource] = []
        for row in rows {
            let channel = try Channel(row: row)
            guard let provider = providers[channel.providerID] else { continue }
            var source = try source(channel: channel, provider: provider, db: db)
            // The channel the user actually picked goes first among equals.
            if channel.providerID == preferred { source.providerPriority = min(source.providerPriority, -1) }
            sources.append(source)
        }
        guard !sources.isEmpty else { return nil }
        let name = try String.fetchOne(db, sql: """
            SELECT customName FROM channelOverride WHERE providerID = ? AND streamID = ? AND customName IS NOT NULL
            """, arguments: [sources[0].providerID, sources[0].streamID ?? 0]) ?? logical.name
        return PlaybackItem(id: logicalID, title: name, content: .live, sources: sources, logoURL: logical.logoURL)
    }

    private static func source(channel: Channel, provider: Provider, db: Database) throws -> PlaybackSource {
        let override = try ChannelOverride.fetchOne(db, key: ["providerID": provider.id.rawValue, "streamID": channel.streamID])
        let history = try PlaybackHistory.fetchOne(db, key: ["providerID": provider.id.rawValue, "streamID": channel.streamID])
        let formats = provider.allowedOutputFormats.compactMap(StreamFormat.init(rawValue:))
        return PlaybackSource(
            providerID: provider.id, itemID: String(channel.streamID), providerName: provider.name,
            providerPriority: provider.priority, allowedFormats: formats,
            preferredFormat: override?.preferredFormat, engineOverride: override?.engine,
            lastWorkingFormat: history?.lastWorkingFormat, lastWorkingEngine: history?.lastWorkingEngine,
            reliability: history?.reliabilityScore ?? 0.5)
    }
}
