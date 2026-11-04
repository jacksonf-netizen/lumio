import Foundation
import GRDB

/// A movie or series as shown on a poster.
public struct VODItem: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case movie, series }

    public var id: String { "\(kind.rawValue):\(providerID.rawValue):\(itemID)" }
    public var kind: Kind
    public var providerID: ProviderID
    /// Stream id (movie) or series id.
    public var itemID: Int
    public var name: String
    public var posterURL: URL?
    public var rating: Double?
    public var year: Int?
    public var addedAt: Date?
    public var categoryID: String?
    /// 0...1 for movies in progress.
    public var progress: Double?
    public var isFavorite: Bool

    /// Title without a trailing "(2019)" (the year is shown separately).
    public var displayName: String {
        name.replacing(/\s*\((19|20)\d{2}\)\s*$/, with: "")
    }
}

/// An entry in Continue Watching: a movie or an episode with saved progress.
public struct ContinueItem: Hashable, Sendable, Identifiable {
    public var id: String { "\(kind.rawValue):\(providerID.rawValue):\(itemID)" }
    public var kind: LibraryItemKind
    public var providerID: ProviderID
    /// Movie stream id, or episode id.
    public var itemID: String
    public var title: String
    public var subtitle: String?
    public var imageURL: URL?
    public var position: Double
    public var duration: Double?
    public var updatedAt: Date
    /// For episodes: the series they belong to.
    public var seriesID: Int?
    /// Finished (or marked as watched).
    public var isWatched = false

    /// Title without a trailing "(2019)", like `VODItem.displayName`.
    public var displayTitle: String {
        title.replacing(/\s*\((19|20)\d{2}\)\s*$/, with: "")
    }

    /// Started and not finished: playing it should resume.
    public var canResume: Bool {
        !isWatched && position >= 30 && (duration.map { position < $0 * 0.95 } ?? true)
    }

    public var progress: Double? {
        guard let duration, duration > 0 else { return nil }
        return min(1, position / duration)
    }
}

/// Read model for Movies and Series.
public struct VODCatalog: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func categories(_ kind: VODItem.Kind, filter: ProviderFilter = .all) async throws -> [Category] {
        let contentKind: ContentKind = kind == .movie ? .movie : .series
        return try await database.reader.read { db in
            try Category.fetchAll(db, sql: """
                SELECT c.* FROM category c
                JOIN provider p ON p.id = c.providerID AND p.isEnabled
                LEFT JOIN categoryOverride o ON o.providerID = c.providerID AND o.kind = c.kind AND o.categoryID = c.categoryID
                WHERE c.kind = ? AND COALESCE(o.isHidden, 0) = 0
                  \(filter.sqlCondition(column: "c.providerID"))
                  AND EXISTS (SELECT 1 FROM \(kind == .movie ? "movie" : "series") m WHERE m.providerID = c.providerID AND m.categoryID = c.categoryID)
                ORDER BY COALESCE(o.sortIndex, 1000000), p.priority, c.sortIndex
                """, arguments: [contentKind.rawValue] + filter.sqlArguments)
        }
    }

    /// Items in a category (or all), optionally filtered by name; newest first when `recent`.
    /// Outside a specific category, items in hidden categories are left out unless `includeHidden`
    /// (favorites and recently watched always show). Region switches only apply to Live TV.
    public func items(_ kind: VODItem.Kind, category: Category? = nil, filter: ProviderFilter = .all,
                      search: String? = nil, recent: Bool = false, limit: Int? = nil,
                      keys: [(ProviderID, Int)]? = nil, includeHidden: Bool = false) async throws -> [VODItem] {
        try await database.reader.read { db in
            var conditions = ["p.isEnabled"]
            if category == nil, !includeHidden {
                let contentKind: ContentKind = kind == .movie ? .movie : .series
                conditions.append("""
                    NOT EXISTS (SELECT 1 FROM categoryOverride ho WHERE ho.providerID = m.providerID AND ho.kind = '\(contentKind.rawValue)'
                                AND ho.categoryID = m.categoryID AND ho.isHidden)
                    """)
            }
            var arguments: StatementArguments = []
            if let keys {
                guard !keys.isEmpty else { return [] }
                let idColumn = kind == .movie ? "streamID" : "seriesID"
                conditions.append("(" + keys.map { _ in "(m.providerID = ? AND m.\(idColumn) = ?)" }.joined(separator: " OR ") + ")")
                for (providerID, id) in keys { arguments += [providerID.rawValue, id] }
            }
            if let category {
                conditions.append("m.providerID = ? AND m.categoryID = ?")
                arguments += [category.providerID.rawValue, category.categoryID]
            }
            if case .only(let id) = filter {
                conditions.append("m.providerID = ?")
                arguments += [id.rawValue]
            }
            if let search = search?.trimmingCharacters(in: .whitespaces), !search.isEmpty {
                conditions.append("m.name LIKE ?")
                arguments += ["%\(search)%"]
            }
            let isMovie = kind == .movie
            let order = recent
                ? (isMovie ? "m.addedAt IS NULL, m.addedAt DESC" : "m.lastModified IS NULL, m.lastModified DESC")
                : "p.priority, m.sortIndex"
            let sql = """
                SELECT m.providerID, m.\(isMovie ? "streamID" : "seriesID") AS itemID, m.name,
                       m.\(isMovie ? "posterURL" : "coverURL") AS poster, m.rating,
                       \(isMovie ? "m.year" : "CAST(substr(m.releaseDate, 1, 4) AS INTEGER)") AS year,
                       m.\(isMovie ? "addedAt" : "lastModified") AS added, m.categoryID,
                       \(isMovie ? "w.positionSeconds, w.durationSeconds, w.isWatched" : "NULL AS positionSeconds, NULL AS durationSeconds, NULL AS isWatched"),
                       EXISTS (SELECT 1 FROM favorite f WHERE f.providerID = m.providerID AND f.itemKind = '\(isMovie ? "movie" : "series")'
                               AND f.itemID = CAST(m.\(isMovie ? "streamID" : "seriesID") AS TEXT)) AS fav
                FROM \(isMovie ? "movie" : "series") m
                JOIN provider p ON p.id = m.providerID
                \(isMovie ? "LEFT JOIN watchProgress w ON w.providerID = m.providerID AND w.itemKind = 'movie' AND w.itemID = CAST(m.streamID AS TEXT)" : "")
                WHERE \(conditions.joined(separator: " AND "))
                ORDER BY \(order)
                \(limit.map { "LIMIT \($0)" } ?? "")
                """
            return try Row.fetchAll(db, sql: sql, arguments: arguments).map { row in
                let position: Double? = row["positionSeconds"]
                let duration: Double? = row["durationSeconds"]
                let watched: Bool = row["isWatched"] ?? false
                let progress: Double? = watched ? 1 : position.flatMap { p in duration.map { $0 > 0 ? p / $0 : 0 } }
                let year: Int? = row["year"]
                return VODItem(
                    kind: kind, providerID: ProviderID(row["providerID"] as String), itemID: row["itemID"], name: row["name"],
                    posterURL: (row["poster"] as String?).flatMap(URL.init(string:)), rating: row["rating"],
                    year: (year ?? 0) > 1800 ? year : nil,
                    addedAt: (row["added"] as Double?).map { Date(timeIntervalSince1970: $0) }, categoryID: row["categoryID"],
                    progress: progress, isFavorite: row["fav"])
            }
        }
    }

    public func favorites(_ kind: VODItem.Kind) async throws -> [VODItem] {
        let all = try await items(kind, includeHidden: true)
        return all.filter(\.isFavorite)
    }

    /// Movies and episodes started but not finished, most recent first.
    public func continueWatching(limit: Int = 30) async throws -> [ContinueItem] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT w.*, m.name AS movieName, m.posterURL AS moviePoster,
                       e.title AS episodeTitle, e.seasonNumber, e.episodeNumber, e.seriesID, e.imageURL AS episodeImage,
                       s.name AS seriesName, s.coverURL AS seriesCover
                FROM watchProgress w
                JOIN provider p ON p.id = w.providerID AND p.isEnabled
                LEFT JOIN movie m ON w.itemKind = 'movie' AND m.providerID = w.providerID AND CAST(m.streamID AS TEXT) = w.itemID
                LEFT JOIN episode e ON w.itemKind = 'episode' AND e.providerID = w.providerID AND e.episodeID = w.itemID
                LEFT JOIN series s ON s.providerID = e.providerID AND s.seriesID = e.seriesID
                WHERE NOT w.isWatched AND w.positionSeconds >= 30
                  AND (w.durationSeconds IS NULL OR w.positionSeconds < w.durationSeconds * 0.95)
                  AND (m.streamID IS NOT NULL OR e.episodeID IS NOT NULL)
                ORDER BY w.updatedAt DESC
                LIMIT ?
                """, arguments: [limit])
            return rows.map { row in
                let kind = LibraryItemKind(rawValue: row["itemKind"]) ?? .movie
                let isEpisode = kind == .episode
                let season: Int? = row["seasonNumber"]
                let episode: Int? = row["episodeNumber"]
                return ContinueItem(
                    kind: kind, providerID: ProviderID(row["providerID"] as String), itemID: row["itemID"],
                    title: isEpisode ? (row["seriesName"] ?? "Episode") : (row["movieName"] ?? "Movie"),
                    subtitle: isEpisode ? "S\(season ?? 0) E\(episode ?? 0) · \(row["episodeTitle"] as String? ?? "")" : nil,
                    imageURL: ((isEpisode ? (row["seriesCover"] as String?) ?? (row["episodeImage"] as String?) : row["moviePoster"]) as String?)
                        .flatMap(URL.init(string:)),
                    position: row["positionSeconds"], duration: row["durationSeconds"],
                    updatedAt: Date(timeIntervalSince1970: row["updatedAt"]), seriesID: row["seriesID"])
            }
        }
    }

    /// Recently played movies (`.movie`) or series (`.series`, one entry per series showing the
    /// last episode played), most recent first, with their progress.
    public func recentlyWatched(_ kind: VODItem.Kind, limit: Int = 20) async throws -> [ContinueItem] {
        try await database.reader.read { db in
            if kind == .movie {
                return try Row.fetchAll(db, sql: """
                    SELECT r.providerID, r.itemID, r.lastPlayedAt, m.name, m.posterURL,
                           w.positionSeconds, w.durationSeconds, w.isWatched
                    FROM recentItem r
                    JOIN provider p ON p.id = r.providerID AND p.isEnabled
                    JOIN movie m ON m.providerID = r.providerID AND CAST(m.streamID AS TEXT) = r.itemID
                    LEFT JOIN watchProgress w ON w.providerID = r.providerID AND w.itemKind = 'movie' AND w.itemID = r.itemID
                    WHERE r.itemKind = 'movie'
                    ORDER BY r.lastPlayedAt DESC
                    LIMIT ?
                    """, arguments: [limit]).map { row in
                    ContinueItem(
                        kind: .movie, providerID: ProviderID(row["providerID"] as String), itemID: row["itemID"],
                        title: row["name"], subtitle: nil, imageURL: (row["posterURL"] as String?).flatMap(URL.init(string:)),
                        position: row["positionSeconds"] ?? 0, duration: row["durationSeconds"],
                        updatedAt: Date(timeIntervalSince1970: row["lastPlayedAt"]), seriesID: nil,
                        isWatched: row["isWatched"] ?? false)
                }
            }
            // SQLite takes the other columns from the row holding MAX(), i.e. the latest episode.
            return try Row.fetchAll(db, sql: """
                SELECT r.providerID, r.itemID, MAX(r.lastPlayedAt) AS lastPlayedAt,
                       e.title AS episodeTitle, e.seasonNumber, e.episodeNumber, e.seriesID, e.imageURL AS episodeImage,
                       s.name AS seriesName, s.coverURL AS seriesCover,
                       w.positionSeconds, w.durationSeconds, w.isWatched
                FROM recentItem r
                JOIN provider p ON p.id = r.providerID AND p.isEnabled
                JOIN episode e ON e.providerID = r.providerID AND e.episodeID = r.itemID
                JOIN series s ON s.providerID = e.providerID AND s.seriesID = e.seriesID
                LEFT JOIN watchProgress w ON w.providerID = r.providerID AND w.itemKind = 'episode' AND w.itemID = r.itemID
                WHERE r.itemKind = 'episode'
                GROUP BY e.providerID, e.seriesID
                ORDER BY lastPlayedAt DESC
                LIMIT ?
                """, arguments: [limit]).map { row in
                let season: Int = row["seasonNumber"] ?? 0
                let episode: Int = row["episodeNumber"] ?? 0
                let episodeTitle: String = row["episodeTitle"] ?? ""
                return ContinueItem(
                    kind: .episode, providerID: ProviderID(row["providerID"] as String), itemID: row["itemID"],
                    title: row["seriesName"], subtitle: "S\(season) E\(episode)\(episodeTitle.isEmpty ? "" : " · \(episodeTitle)")",
                    imageURL: ((row["seriesCover"] as String?) ?? (row["episodeImage"] as String?)).flatMap(URL.init(string:)),
                    position: row["positionSeconds"] ?? 0, duration: row["durationSeconds"],
                    updatedAt: Date(timeIntervalSince1970: row["lastPlayedAt"]), seriesID: row["seriesID"],
                    isWatched: row["isWatched"] ?? false)
            }
        }
    }

    public func movie(providerID: ProviderID, streamID: Int) async throws -> Movie? {
        try await database.reader.read { db in try Movie.fetchOne(db, key: ["providerID": providerID.rawValue, "streamID": streamID]) }
    }

    public func series(providerID: ProviderID, seriesID: Int) async throws -> Series? {
        try await database.reader.read { db in try Series.fetchOne(db, key: ["providerID": providerID.rawValue, "seriesID": seriesID]) }
    }

    public func seasons(providerID: ProviderID, seriesID: Int) async throws -> [Season] {
        try await database.reader.read { db in
            try Season.filter(Column("providerID") == providerID.rawValue && Column("seriesID") == seriesID)
                .order(Column("seasonNumber")).fetchAll(db)
        }
    }

    public func episodes(providerID: ProviderID, seriesID: Int) async throws -> [Episode] {
        try await database.reader.read { db in
            try Episode.filter(Column("providerID") == providerID.rawValue && Column("seriesID") == seriesID)
                .order(Column("seasonNumber"), Column("episodeNumber")).fetchAll(db)
        }
    }

    public func progress(kind: LibraryItemKind, providerID: ProviderID, itemID: String) async throws -> WatchProgress? {
        try await database.reader.read { db in
            try WatchProgress.fetchOne(db, key: ["providerID": providerID.rawValue, "itemKind": kind.rawValue, "itemID": itemID])
        }
    }

    /// Progress for every episode of a series, keyed by episode id.
    public func episodeProgress(providerID: ProviderID, seriesID: Int) async throws -> [String: WatchProgress] {
        try await database.reader.read { db in
            let rows = try WatchProgress.fetchAll(db, sql: """
                SELECT w.* FROM watchProgress w JOIN episode e ON e.providerID = w.providerID AND e.episodeID = w.itemID
                WHERE w.itemKind = 'episode' AND e.providerID = ? AND e.seriesID = ?
                """, arguments: [providerID, seriesID])
            return Dictionary(rows.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// The episode to offer with "Play": the one in progress, else the first unwatched after the last
    /// watched one, else the first.
    public func nextEpisode(providerID: ProviderID, seriesID: Int) async throws -> (Episode, WatchProgress?)? {
        let episodes = try await self.episodes(providerID: providerID, seriesID: seriesID)
        let progress = try await episodeProgress(providerID: providerID, seriesID: seriesID)
        if let inProgress = progress.values.filter({ !$0.isWatched && $0.positionSeconds >= 30 }).max(by: { $0.updatedAt < $1.updatedAt }),
           let episode = episodes.first(where: { $0.episodeID == inProgress.itemID }) {
            return (episode, inProgress)
        }
        if let lastWatched = episodes.lastIndex(where: { progress[$0.episodeID]?.isWatched == true }),
           lastWatched + 1 < episodes.count {
            return (episodes[lastWatched + 1], nil)
        }
        return episodes.first.map { ($0, progress[$0.episodeID]) }
    }
}

// MARK: - Progress writes

extension LibraryRepository {
    /// Saves a playback position. Marks the item watched in its last 5%, or in the last 3 minutes of
    /// anything 20 minutes or longer (end credits).
    public func saveProgress(kind: LibraryItemKind, providerID: ProviderID, itemID: String,
                             position: Double, duration: Double?, now: Date = Date()) async throws {
        guard position.isFinite, position >= 0 else { return }
        let finished = duration.map { $0 > 0 && (position >= $0 * 0.95 || ($0 >= 1200 && $0 - position < 180)) } ?? false
        try await database.writer.write { db in
            var progress = try WatchProgress.fetchOne(db, key: ["providerID": providerID.rawValue, "itemKind": kind.rawValue, "itemID": itemID])
                ?? WatchProgress(providerID: providerID, itemKind: kind, itemID: itemID, positionSeconds: 0)
            progress.positionSeconds = position
            if let duration, duration > 0 { progress.durationSeconds = duration }
            if finished { progress.isWatched = true }
            progress.updatedAt = now
            try progress.upsert(db)
        }
        await sync.localDataDidChange(.watchProgress)
    }

    public func setWatched(_ watched: Bool, kind: LibraryItemKind, providerID: ProviderID, itemID: String, now: Date = Date()) async throws {
        try await database.writer.write { db in
            var progress = try WatchProgress.fetchOne(db, key: ["providerID": providerID.rawValue, "itemKind": kind.rawValue, "itemID": itemID])
                ?? WatchProgress(providerID: providerID, itemKind: kind, itemID: itemID, positionSeconds: 0)
            progress.isWatched = watched
            if !watched { progress.positionSeconds = 0 }
            progress.updatedAt = now
            try progress.upsert(db)
        }
        await sync.localDataDidChange(.watchProgress)
    }
}
