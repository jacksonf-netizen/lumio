import Foundation
import GRDB

/// Counts from one replace operation.
public struct ReplaceStats: Sendable, Equatable {
    public var inserted = 0
    public var updated = 0
    public var deleted = 0
    public var unchanged = 0
    /// Library entries moved to new IDs, and removed because their ID now means something else.
    public var relinked = 0
    public var unlinked = 0

    public var changed: Bool { inserted + updated + deleted > 0 }

    mutating func note(_ plan: CatalogRelinker.Plan) {
        relinked = plan.moves.count
        unlinked = plan.drops.count
    }
}

/// Reads and writes the provider catalog (categories, channels, movies, series, seasons, episodes).
public struct CatalogRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: Writes (used by sync)

    /// Makes the stored categories of one kind match `categories` exactly, in one transaction.
    @discardableResult
    public func replaceCategories(_ categories: [Category], providerID: ProviderID, kind: ContentKind) throws -> ReplaceStats {
        try database.writer.write { db in
            let existing = try Category
                .filter(Column("providerID") == providerID.rawValue && Column("kind") == kind.rawValue)
                .fetchAll(db)
            // Read the region codes the way this provider uses them, with the user's merges
            // (Settings → Regions) applied.
            let regions = RegionPrefix.resolve(categories.map(\.name), aliases: try RegionPrefix.userAliases(db))
            let resolved = zip(categories, regions).map { category, region -> Category in
                var category = category
                category.regionPrefix = region.prefix
                category.region = region.region
                return category
            }
            // Hidden, renamed or reordered categories follow a provider that renumbered them.
            let targets = CatalogRelinker.categoryTargets(kind)
            let plan = CatalogRelinker.plan(old: existing.map(Self.item), new: resolved.map(Self.item),
                                            referenced: try CatalogRelinker.referenced(targets, providerID: providerID, in: db))
            try CatalogRelinker.apply(plan, to: targets, providerID: providerID, in: db)
            var stats = try Self.replace(existing: existing, with: resolved, key: \.categoryID, in: db)
            stats.note(plan)
            return stats
        }
    }

    @discardableResult
    public func replaceChannels(_ channels: [Channel], providerID: ProviderID) throws -> ReplaceStats {
        try database.writer.write { db in
            let existing = try Channel.filter(Column("providerID") == providerID.rawValue).fetchAll(db)
            // Favorites, recents, renames, custom groups and the like follow channels to new IDs.
            let groups = try Self.categoryNames(providerID: providerID, kind: .live, in: db)
            let item = { (channel: Channel) in
                CatalogRelinker.Item(id: String(channel.streamID), name: channel.name, epgID: channel.epgChannelID,
                                     group: channel.categoryID.flatMap { groups[$0] })
            }
            let targets = CatalogRelinker.channelTargets
            let plan = CatalogRelinker.plan(old: existing.map(item), new: channels.map(item),
                                            referenced: try CatalogRelinker.referenced(targets, providerID: providerID, in: db))
            try CatalogRelinker.apply(plan, to: targets, providerID: providerID, in: db)
            try CatalogRelinker.applyToLogicalIDs(plan, providerID: providerID, in: db)
            var stats = try Self.replace(existing: existing, with: channels, key: \.streamID, in: db)
            stats.note(plan)
            return stats
        }
    }

    @discardableResult
    public func replaceMovies(_ movies: [Movie], providerID: ProviderID) throws -> ReplaceStats {
        try database.writer.write { db in
            let existing = try Movie.filter(Column("providerID") == providerID.rawValue).fetchAll(db)
            // Keep details fetched on demand (plot, duration) that the list endpoint doesn't return.
            let groups = try Self.categoryNames(providerID: providerID, kind: .movie, in: db)
            let item = { (movie: Movie) in
                CatalogRelinker.Item(id: String(movie.streamID), name: movie.name, group: movie.categoryID.flatMap { groups[$0] },
                                     year: movie.year, tmdbID: movie.tmdbID)
            }
            let targets = CatalogRelinker.libraryTargets(.movie)
            let plan = CatalogRelinker.plan(old: existing.map(item), new: movies.map(item),
                                            referenced: try CatalogRelinker.referenced(targets, providerID: providerID, in: db))
            try CatalogRelinker.apply(plan, to: targets, providerID: providerID, in: db)
            let byID = Dictionary(existing.map { ($0.streamID, $0) }, uniquingKeysWith: { a, _ in a })
            let merged = movies.map { movie -> Movie in
                // Only the same movie keeps details fetched on demand.
                guard let old = byID[movie.streamID], !plan.reused.contains(String(movie.streamID)) else { return movie }
                var movie = movie
                movie.plot = movie.plot ?? old.plot
                movie.durationSeconds = movie.durationSeconds ?? old.durationSeconds
                return movie
            }
            var stats = try Self.replace(existing: existing, with: merged, key: \.streamID, in: db)
            stats.note(plan)
            return stats
        }
    }

    @discardableResult
    public func replaceSeries(_ series: [Series], providerID: ProviderID) throws -> ReplaceStats {
        try database.writer.write { db in
            let existing = try Series.filter(Column("providerID") == providerID.rawValue).fetchAll(db)
            let groups = try Self.categoryNames(providerID: providerID, kind: .series, in: db)
            let item = { (show: Series) in
                CatalogRelinker.Item(id: String(show.seriesID), name: show.name, group: show.categoryID.flatMap { groups[$0] },
                                     year: show.releaseDate.flatMap { Int($0.prefix(4)) })
            }
            // Series in the library, and series whose episodes are.
            let targets = CatalogRelinker.libraryTargets(.series)
            var referenced = try CatalogRelinker.referenced(targets, providerID: providerID, in: db)
            let episodeIDs = try CatalogRelinker.referenced(CatalogRelinker.libraryTargets(.episode), providerID: providerID, in: db)
            let episodes = try Episode.filter(Column("providerID") == providerID.rawValue && episodeIDs.contains(Column("episodeID"))).fetchAll(db)
            referenced.formUnion(episodes.map { String($0.seriesID) })
            let plan = CatalogRelinker.plan(old: existing.map(item), new: series.map(item), referenced: referenced)
            try CatalogRelinker.apply(plan, to: targets, providerID: providerID, in: db)
            // Episodes get new IDs too, known once the series' episode list is fetched: remember
            // which season and episode each one was, and match them then.
            for episode in episodes {
                let seriesID = String(episode.seriesID)
                if let moved = plan.moves[seriesID].flatMap(Int.init) {
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO episodeRelink (providerID, episodeID, seriesID, seasonNumber, episodeNumber)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: [providerID.rawValue, episode.episodeID, moved, episode.seasonNumber, episode.episodeNumber])
                } else if plan.drops.contains(seriesID) {
                    try CatalogRelinker.apply(.init(drops: [episode.episodeID]), to: CatalogRelinker.libraryTargets(.episode),
                                              providerID: providerID, in: db)
                }
            }
            // Seasons and episodes cached under an ID that now means another series are stale.
            for id in plan.reused.compactMap(Int.init) {
                try Season.filter(Column("providerID") == providerID.rawValue && Column("seriesID") == id).deleteAll(db)
                try Episode.filter(Column("providerID") == providerID.rawValue && Column("seriesID") == id).deleteAll(db)
            }
            var stats = try Self.replace(existing: existing, with: series, key: \.seriesID, in: db)
            stats.note(plan)
            return stats
        }
    }

    /// Stores seasons and episodes fetched for a series detail page.
    public func replaceSeriesDetails(_ details: SeriesDetails, providerID: ProviderID, seriesID: Int) throws {
        try database.writer.write { db in
            let seasonFilter = Column("providerID") == providerID.rawValue && Column("seriesID") == seriesID
            let existingSeasons = try Season.filter(seasonFilter).fetchAll(db)
            try Self.replace(existing: existingSeasons, with: details.seasons, key: \.seasonNumber, in: db)
            let existingEpisodes = try Episode.filter(seasonFilter).fetchAll(db)
            try Self.relinkEpisodes(old: existingEpisodes, new: details.episodes, providerID: providerID, seriesID: seriesID, in: db)
            try Self.replace(existing: existingEpisodes, with: details.episodes, key: \.episodeID, in: db)
            if var series = try Series.fetchOne(db, key: ["providerID": providerID.rawValue, "seriesID": seriesID]),
               let plot = details.plot, series.plot != plot {
                series.plot = plot
                try series.update(db)
            }
        }
    }

    /// Saves plot and duration fetched for a movie detail page.
    public func updateMovieDetails(_ details: MovieDetails, providerID: ProviderID, streamID: Int) throws {
        try database.writer.write { db in
            guard var movie = try Movie.fetchOne(db, key: ["providerID": providerID.rawValue, "streamID": streamID])
            else { return }
            movie.plot = details.plot ?? movie.plot
            movie.durationSeconds = details.durationSeconds ?? movie.durationSeconds
            movie.containerExtension = details.containerExtension ?? movie.containerExtension
            try movie.update(db)
        }
    }

    // MARK: Reads

    public func categories(providerID: ProviderID, kind: ContentKind) throws -> [Category] {
        try database.reader.read { db in
            try Category
                .filter(Column("providerID") == providerID.rawValue && Column("kind") == kind.rawValue)
                .order(Column("sortIndex"))
                .fetchAll(db)
        }
    }

    public func channels(providerID: ProviderID) throws -> [Channel] {
        try database.reader.read { db in
            try Channel.filter(Column("providerID") == providerID.rawValue).order(Column("sortIndex")).fetchAll(db)
        }
    }

    public func channel(providerID: ProviderID, streamID: Int) throws -> Channel? {
        try database.reader.read { db in
            try Channel.fetchOne(db, key: ["providerID": providerID.rawValue, "streamID": streamID])
        }
    }

    public func counts(providerID: ProviderID) throws -> CatalogCounts {
        try database.reader.read { db in
            let id = providerID.rawValue
            return CatalogCounts(
                channels: try Channel.filter(Column("providerID") == id).fetchCount(db),
                movies: try Movie.filter(Column("providerID") == id).fetchCount(db),
                series: try Series.filter(Column("providerID") == id).fetchCount(db),
                programmes: try Programme.filter(Column("providerID") == id).fetchCount(db))
        }
    }

    // MARK: Relinking

    private static func item(_ category: Category) -> CatalogRelinker.Item {
        CatalogRelinker.Item(id: category.categoryID, name: category.name)
    }

    /// Category ID → name, for one provider and kind.
    private static func categoryNames(providerID: ProviderID, kind: ContentKind, in db: Database) throws -> [String: String] {
        let rows = try Row.fetchAll(db, sql: "SELECT categoryID, name FROM category WHERE providerID = ? AND kind = ?",
                                    arguments: [providerID.rawValue, kind.rawValue])
        return Dictionary(rows.map { ($0["categoryID"] as String, $0["name"] as String) }, uniquingKeysWith: { a, _ in a })
    }

    /// Moves the library's episode entries to new episode IDs, by season and episode number: for
    /// episodes waiting since their series was renumbered, and for any the library uses that
    /// disappeared from this series' list.
    private static func relinkEpisodes(old: [Episode], new: [Episode], providerID: ProviderID, seriesID: Int, in db: Database) throws {
        struct Slot: Hashable { var season: Int; var episode: Int }
        var waiting: [String: Slot] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT episodeID, seasonNumber, episodeNumber FROM episodeRelink WHERE providerID = ? AND seriesID = ?",
                                    arguments: [providerID.rawValue, seriesID]) {
            waiting[row["episodeID"]] = Slot(season: row["seasonNumber"], episode: row["episodeNumber"])
        }
        let targets = CatalogRelinker.libraryTargets(.episode)
        let newIDs = Set(new.map(\.episodeID))
        let used = try CatalogRelinker.referenced(targets, providerID: providerID, in: db)
        for episode in old where used.contains(episode.episodeID) && !newIDs.contains(episode.episodeID) {
            waiting[episode.episodeID] = Slot(season: episode.seasonNumber, episode: episode.episodeNumber)
        }
        guard !waiting.isEmpty else { return }
        let bySlot = Dictionary(new.map { (Slot(season: $0.seasonNumber, episode: $0.episodeNumber), $0.episodeID) },
                                uniquingKeysWith: { a, _ in a })
        var plan = CatalogRelinker.Plan()
        for (episodeID, slot) in waiting {
            if let match = bySlot[slot], match != episodeID { plan.moves[episodeID] = match }
        }
        try CatalogRelinker.apply(plan, to: targets, providerID: providerID, in: db)
        try db.execute(sql: "DELETE FROM episodeRelink WHERE providerID = ? AND seriesID = ?", arguments: [providerID.rawValue, seriesID])
    }

    /// Series with episodes waiting to be matched after a renumbering (their episode lists should
    /// be fetched soon, so Recently Watched and progress carry over).
    public func seriesAwaitingRelink(providerID: ProviderID) throws -> [Int] {
        try database.reader.read { db in
            try Int.fetchAll(db, sql: "SELECT DISTINCT seriesID FROM episodeRelink WHERE providerID = ?", arguments: [providerID.rawValue])
        }
    }

    // MARK: Diff

    /// Inserts new rows, updates changed rows, deletes rows that disappeared. Unchanged rows are not
    /// touched, so search-index triggers and database observers only fire for real changes.
    @discardableResult
    static func replace<R: PersistableRecord & Hashable, K: Hashable>(
        existing: [R], with incoming: [R], key: KeyPath<R, K>, in db: Database
    ) throws -> ReplaceStats {
        var stats = ReplaceStats()
        var old = Dictionary(existing.map { ($0[keyPath: key], $0) }, uniquingKeysWith: { a, _ in a })
        for row in incoming {
            let id = row[keyPath: key]
            if let previous = old.removeValue(forKey: id) {
                if previous == row {
                    stats.unchanged += 1
                } else {
                    try row.update(db)
                    stats.updated += 1
                }
            } else {
                try row.insert(db)
                stats.inserted += 1
            }
        }
        for row in old.values {
            try row.delete(db)
            stats.deleted += 1
        }
        return stats
    }
}

public struct CatalogCounts: Sendable, Equatable {
    public var channels: Int
    public var movies: Int
    public var series: Int
    public var programmes: Int

    public init(channels: Int = 0, movies: Int = 0, series: Int = 0, programmes: Int = 0) {
        self.channels = channels
        self.movies = movies
        self.series = series
        self.programmes = programmes
    }
}
