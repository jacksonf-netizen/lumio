import Foundation
import GRDB

/// A programme found by search, with a channel that shows it.
public struct ProgrammeHit: Hashable, Sendable, Identifiable {
    public var id: Int64 { programme.id ?? 0 }
    public var programme: Programme
    public var channel: ChannelListItem?
}

public struct SearchResults: Sendable {
    public var channels: [ChannelListItem] = []
    public var programmes: [ProgrammeHit] = []
    public var movies: [VODItem] = []
    public var series: [VODItem] = []

    public var isEmpty: Bool { channels.isEmpty && programmes.isEmpty && movies.isEmpty && series.isEmpty }
    public var count: Int { channels.count + programmes.count + movies.count + series.count }

    public init() {}

    /// Splits the results by provider, in `providerOrder` (priority order); providers not listed
    /// come last. A channel carried by several providers goes under its preferred source; a
    /// programme under its channel's provider (or the guide's, when it has no channel).
    public func grouped(by providerOrder: [ProviderID]) -> [(provider: ProviderID, results: SearchResults)] {
        var groups: [ProviderID: SearchResults] = [:]
        for channel in channels { groups[channel.providerID, default: SearchResults()].channels.append(channel) }
        for hit in programmes { groups[hit.channel?.providerID ?? hit.programme.providerID, default: SearchResults()].programmes.append(hit) }
        for movie in movies { groups[movie.providerID, default: SearchResults()].movies.append(movie) }
        for show in series { groups[show.providerID, default: SearchResults()].series.append(show) }
        let rank = Dictionary(providerOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return groups
            .sorted { (rank[$0.key] ?? .max, $0.key.rawValue) < (rank[$1.key] ?? .max, $1.key.rawValue) }
            .map { (provider: $0.key, results: $0.value) }
    }
}

/// Global search over channels, guide programmes, movies and series using the FTS5 indexes.
/// Matches word prefixes ("sky spo" finds "Sky Sports"), ignoring case and accents.
public struct SearchRepository: Sendable {
    private let database: AppDatabase
    private let live: LiveCatalog
    private let vod: VODCatalog

    public init(database: AppDatabase) {
        self.database = database
        live = LiveCatalog(database: database)
        vod = VODCatalog(database: database)
    }

    public func search(_ text: String, limit: Int = 40, now: Date = Date()) async throws -> SearchResults {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return SearchResults() }
        var results = SearchResults()

        // Channels: match provider names and the user's custom names.
        let channelKeys = try await database.reader.read { db -> [(ProviderID, Int)] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.providerID, c.streamID FROM channel c
                JOIN channelFTS ON channelFTS.rowid = c.rowid
                JOIN provider p ON p.id = c.providerID AND p.isEnabled
                WHERE channelFTS MATCH ? AND NOT \(RegionPrefix.channelHiddenSQL("c"))
                ORDER BY bm25(channelFTS), p.priority
                LIMIT ?
                """, arguments: [pattern, limit * 3])
            let renamed = try Row.fetchAll(db, sql: """
                SELECT providerID, streamID FROM channelOverride WHERE customName LIKE ? LIMIT ?
                """, arguments: ["%\(text.trimmingCharacters(in: .whitespaces))%", limit])
            return (renamed + rows).map { (ProviderID($0["providerID"] as String), $0["streamID"] as Int) }
        }
        var seen = Set<String>()
        for (providerID, streamID) in channelKeys {
            guard let logicalID = try LogicalChannelStore(database: database).logicalChannelID(providerID: providerID, streamID: streamID)
                    ?? Optional("solo:\(providerID.rawValue):\(streamID)"),
                  seen.insert(logicalID).inserted,
                  let item = try await live.item(logicalID: logicalID), !item.isHidden
            else { continue }
            results.channels.append(item)
            if results.channels.count >= limit { break }
        }

        // Programmes on now or later, soonest first.
        let programmes = try await database.reader.read { db in
            try Programme.fetchAll(db, sql: """
                SELECT programme.* FROM programme
                JOIN programmeFTS ON programmeFTS.rowid = programme.id
                WHERE programmeFTS MATCH ? AND programme.stop > ?
                ORDER BY programme.start
                LIMIT ?
                """, arguments: [pattern, now.timeIntervalSince1970, limit * 3])
        }
        var channelForEPG: [String: ChannelListItem?] = [:]
        var seenProgrammes = Set<String>()
        for programme in programmes {
            // The same airing often appears in several providers' guides.
            guard seenProgrammes.insert("\(programme.epgID)|\(programme.start.timeIntervalSince1970)").inserted else { continue }
            if channelForEPG[programme.epgID] == nil {
                channelForEPG[programme.epgID] = try await channel(forEPG: programme.epgID)
            }
            // Skip programmes whose channels are all in hidden regions.
            if channelForEPG[programme.epgID] == .some(nil), try await hasChannel(forEPG: programme.epgID) { continue }
            results.programmes.append(ProgrammeHit(programme: programme, channel: channelForEPG[programme.epgID] ?? nil))
            if results.programmes.count >= limit { break }
        }

        results.movies = try await vodHits(.movie, pattern: pattern, limit: limit)
        results.series = try await vodHits(.series, pattern: pattern, limit: limit)
        return results
    }

    private func channel(forEPG epgID: String) async throws -> ChannelListItem? {
        let key = try await database.reader.read { db -> (ProviderID, Int)? in
            try Row.fetchOne(db, sql: """
                SELECT c.providerID, c.streamID FROM channel c JOIN provider p ON p.id = c.providerID AND p.isEnabled
                WHERE c.epgChannelID = ? AND NOT \(RegionPrefix.channelHiddenSQL("c")) ORDER BY p.priority LIMIT 1
                """, arguments: [epgID]).map { (ProviderID($0["providerID"] as String), $0["streamID"] as Int) }
        }
        guard let key else { return nil }
        let logicalID = try LogicalChannelStore(database: database).logicalChannelID(providerID: key.0, streamID: key.1)
            ?? "solo:\(key.0.rawValue):\(key.1)"
        return try await live.item(logicalID: logicalID)
    }

    private func hasChannel(forEPG epgID: String) async throws -> Bool {
        try await database.reader.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM channel WHERE epgChannelID = ?)", arguments: [epgID]) ?? false
        }
    }

    private func vodHits(_ kind: VODItem.Kind, pattern: FTS5Pattern, limit: Int) async throws -> [VODItem] {
        let table = kind == .movie ? "movie" : "series"
        let idColumn = kind == .movie ? "streamID" : "seriesID"
        let keys = try await database.reader.read { db -> [(ProviderID, Int)] in
            try Row.fetchAll(db, sql: """
                SELECT m.providerID, m.\(idColumn) AS itemID FROM \(table) m
                JOIN \(table)FTS ON \(table)FTS.rowid = m.rowid
                JOIN provider p ON p.id = m.providerID AND p.isEnabled
                WHERE \(table)FTS MATCH ? ORDER BY bm25(\(table)FTS) LIMIT ?
                """, arguments: [pattern, limit]).map { (ProviderID($0["providerID"] as String), $0["itemID"] as Int) }
        }
        // Fetch only the matches, then restore search ranking.
        let found = try await vod.items(kind, keys: keys)
        let byKey = Dictionary(found.map { ("\($0.providerID.rawValue)|\($0.itemID)", $0) }, uniquingKeysWith: { a, _ in a })
        return keys.compactMap { byKey["\($0.0.rawValue)|\($0.1)"] }
    }
}
