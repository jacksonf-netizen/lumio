import Foundation
import GRDB
import Testing
@testable import IPTVCore

/// A provider moving to a different panel numbers everything afresh; the library should follow.
@Suite("Catalog relinking")
struct CatalogRelinkTests {
    /// Twelve channels as one panel lists them.
    static let oldLineup: [(Int, String, String?)] = [
        (1, "UK: BBC One HD", "bbc1.uk"), (2, "UK: BBC Two HD", "bbc2.uk"), (3, "UK: Sky Sports Main Event", "skyme.uk"),
        (4, "UK: ITV 1", "itv1.uk"), (5, "US: ESPN", "espn.us"), (6, "US: CNN", "cnn.us"), (7, "UK: Channel 4", nil),
        (8, "US: HBO", "hbo.us"), (9, "UK: Dave", nil), (10, "US: Fox News", "foxnews.us"), (11, "UK: Film4", nil),
        (12, "US: ESPN 2", "espn2.us"),
    ]

    /// The same channels on another panel: new numbers, other spelling, and old numbers reused.
    static let newLineup: [(Int, String, String?)] = [
        (5, "UK| BBC ONE FHD", "bbc1.uk"), (3, "UK| BBC TWO FHD", "bbc2.uk"), (101, "UK| SKY SPORTS MAIN EVENT HD", "skyme.uk"),
        (102, "UK| ITV 1 HD", "itv1.uk"), (1, "US| ESPN HD", "espn.us"), (104, "US| CNN", "cnn.us"),
        (105, "UK| CHANNEL 4 HD", nil), (106, "US| HBO", "hbo.us"), (107, "UK| DAVE", nil), (108, "US| FOX NEWS", "foxnews.us"),
        (7, "UK| BBC NEWS", "bbcnews.uk"), (110, "US| ESPN 2 HD", "espn2.us"),
    ]

    private func channels(_ lineup: [(Int, String, String?)], _ provider: ProviderID) -> [Channel] {
        lineup.map { Channel(providerID: provider, streamID: $0.0, name: $0.1, epgChannelID: $0.2) }
    }

    private func ids(_ db: AppDatabase, _ sql: String) throws -> [String] {
        try db.reader.read { try String.fetchAll($0, sql: sql) }
    }

    @Test func channelLibraryFollowsAMoveToAnotherPanel() async throws {
        let database = try AppDatabase.inMemory()
        let provider = try ProviderRepository(database: database).insert(TestData.provider())
        let catalog = CatalogRepository(database: database)
        let library = LibraryRepository(database: database)
        try catalog.replaceChannels(channels(Self.oldLineup, provider.id), providerID: provider.id)

        // Favorites: BBC One (1), Sky Sports (3), ESPN (5). Recent: Channel 4 (7). Renamed and in a
        // custom group: Sky Sports. Hidden: Dave (9).
        for id in ["1", "3", "5"] { try await library.setFavorite(true, kind: .channel, providerID: provider.id, itemID: id) }
        try await library.recordPlayed(providerID: provider.id, kind: .channel, itemID: "7")
        try await database.writer.write { db in
            try ChannelOverride(providerID: provider.id, streamID: 3, customName: "Sky Main").insert(db)
            try ChannelOverride(providerID: provider.id, streamID: 9, isHidden: true).insert(db)
            try CustomGroup(id: "g", name: "Sport").insert(db)
            try db.execute(sql: "INSERT INTO customGroupMember (groupID, providerID, streamID) VALUES ('g', ?, 3)", arguments: [provider.id.rawValue])
        }

        let stats = try catalog.replaceChannels(channels(Self.newLineup, provider.id), providerID: provider.id)
        #expect(stats.relinked == 5)
        #expect(stats.unlinked == 0)
        // BBC One is now 5, Sky Sports 101, ESPN 1; the swapped 1 ↔ 5 didn't collide.
        #expect(try ids(database, "SELECT itemID FROM favorite WHERE itemKind = 'channel' ORDER BY sortIndex") == ["5", "101", "1"])
        #expect(try ids(database, "SELECT itemID FROM recentItem") == ["105"])
        #expect(try ids(database, "SELECT CAST(streamID AS TEXT) FROM channelOverride WHERE customName = 'Sky Main'") == ["101"])
        #expect(try ids(database, "SELECT CAST(streamID AS TEXT) FROM channelOverride WHERE isHidden") == ["107"])
        #expect(try ids(database, "SELECT CAST(streamID AS TEXT) FROM customGroupMember") == ["101"])

        // And the app shows them as favorites under the new numbers.
        try LogicalChannelStore(database: database).rebuild()
        let favorites = try await LiveCatalog(database: database)
            .channels(in: ChannelGroup(id: "favorites", name: "Favorites", kind: .favorites))
        #expect(favorites.map(\.streamID).sorted() == [1, 5, 101])
        #expect(Set(favorites.map(\.name)) == ["BBC ONE FHD", "Sky Main", "ESPN HD"])
    }

    @Test func aFavoriteWhoseNumberNowMeansAnotherChannelIsRemoved() async throws {
        let database = try AppDatabase.inMemory()
        let provider = try ProviderRepository(database: database).insert(TestData.provider())
        let catalog = CatalogRepository(database: database)
        let library = LibraryRepository(database: database)
        // A favorite that has no counterpart on the new panel, while its number now means BBC News.
        var old = Self.oldLineup
        old[6] = (7, "UK: Gold", nil)
        try catalog.replaceChannels(channels(old, provider.id), providerID: provider.id)
        try await library.setFavorite(true, kind: .channel, providerID: provider.id, itemID: "7")
        let stats = try catalog.replaceChannels(channels(Self.newLineup, provider.id), providerID: provider.id)
        #expect(stats.unlinked == 1)
        #expect(try ids(database, "SELECT itemID FROM favorite").isEmpty)
    }

    @Test func samePanelChangesLeaveTheLibraryAlone() async throws {
        let database = try AppDatabase.inMemory()
        let provider = try ProviderRepository(database: database).insert(TestData.provider())
        let catalog = CatalogRepository(database: database)
        let library = LibraryRepository(database: database)
        try catalog.replaceChannels(channels(Self.oldLineup, provider.id), providerID: provider.id)
        for id in ["3", "6"] { try await library.setFavorite(true, kind: .channel, providerID: provider.id, itemID: id) }

        // The provider renames one channel (same number) and drops another for now.
        var renamed = Self.oldLineup.filter { $0.0 != 6 }
        renamed[2] = (3, "UK: Sky Sports Premier League", "skypl.uk")
        let stats = try catalog.replaceChannels(channels(renamed, provider.id), providerID: provider.id)
        #expect(stats.relinked == 0 && stats.unlinked == 0)
        // Both kept: the rename on its number, the missing one in case it comes back.
        #expect(Set(try ids(database, "SELECT itemID FROM favorite")) == ["3", "6"])
    }

    @Test func moviesSeriesAndEpisodesFollow() async throws {
        let database = try AppDatabase.inMemory()
        let provider = try ProviderRepository(database: database).insert(TestData.provider())
        let id = provider.id
        let catalog = CatalogRepository(database: database)
        let library = LibraryRepository(database: database)

        // Movies: matched by TMDB ID, else by name and year (two films share a title).
        try catalog.replaceMovies([
            Movie(providerID: id, streamID: 1, name: "EN - Dune", year: 2021, tmdbID: "438631"),
            Movie(providerID: id, streamID: 2, name: "EN - Dune", year: 1984),
            Movie(providerID: id, streamID: 3, name: "EN - Heat", year: 1995),
        ], providerID: id)
        try await library.setFavorite(true, kind: .movie, providerID: id, itemID: "2")
        try await library.saveProgress(kind: .movie, providerID: id, itemID: "1", position: 600, duration: 9000)
        try catalog.replaceMovies([
            Movie(providerID: id, streamID: 50, name: "Dune (1984)", year: 1984),
            Movie(providerID: id, streamID: 51, name: "Dune: Part One 4K", year: 2021, tmdbID: "438631"),
            Movie(providerID: id, streamID: 52, name: "Heat", year: 1995),
        ], providerID: id)
        #expect(try ids(database, "SELECT itemID FROM favorite WHERE itemKind = 'movie'") == ["50"])
        #expect(try ids(database, "SELECT itemID FROM watchProgress WHERE itemKind = 'movie'") == ["51"])

        // Series and an episode in progress: the episode follows once the new episode list arrives.
        try catalog.replaceSeries([Series(providerID: id, seriesID: 10, name: "EN - The Office"),
                                   Series(providerID: id, seriesID: 11, name: "EN - Lost")], providerID: id)
        try catalog.replaceSeriesDetails(SeriesDetails(seasons: [Season(providerID: id, seriesID: 10, seasonNumber: 2)], episodes: [
            Episode(providerID: id, episodeID: "900", seriesID: 10, seasonNumber: 2, episodeNumber: 3, title: "The Dundies"),
        ]), providerID: id, seriesID: 10)
        try await library.setFavorite(true, kind: .series, providerID: id, itemID: "10")
        try await library.saveProgress(kind: .episode, providerID: id, itemID: "900", position: 300, duration: 1300)
        try await library.recordPlayed(providerID: id, kind: .episode, itemID: "900")

        try catalog.replaceSeries([Series(providerID: id, seriesID: 70, name: "THE OFFICE (US)"),
                                   Series(providerID: id, seriesID: 71, name: "LOST")], providerID: id)
        #expect(try ids(database, "SELECT itemID FROM favorite WHERE itemKind = 'series'") == ["70"])
        #expect(try catalog.seriesAwaitingRelink(providerID: id) == [70])
        try catalog.replaceSeriesDetails(SeriesDetails(seasons: [Season(providerID: id, seriesID: 70, seasonNumber: 2)], episodes: [
            Episode(providerID: id, episodeID: "4411", seriesID: 70, seasonNumber: 2, episodeNumber: 3, title: "The Dundies"),
        ]), providerID: id, seriesID: 70)
        #expect(try ids(database, "SELECT itemID FROM watchProgress WHERE itemKind = 'episode'") == ["4411"])
        #expect(try ids(database, "SELECT itemID FROM recentItem WHERE itemKind = 'episode'") == ["4411"])
        #expect(try catalog.seriesAwaitingRelink(providerID: id).isEmpty)
        let recents = try await VODCatalog(database: database).recentlyWatched(.series)
        #expect(recents.map(\.itemID) == ["4411"])
    }

    @Test func hiddenAndRenamedCategoriesFollow() async throws {
        let database = try AppDatabase.inMemory()
        let provider = try ProviderRepository(database: database).insert(TestData.provider())
        let catalog = CatalogRepository(database: database)
        let names = ["UK | Sports", "UK | News", "US | Sports", "Kids", "Movies", "Music", "Docs", "Comedy", "Drama", "Radio"]
        try catalog.replaceCategories(names.enumerated().map {
            Category(providerID: provider.id, kind: .live, categoryID: String($0.offset + 1), name: $0.element)
        }, providerID: provider.id, kind: .live)
        try await LibraryRepository(database: database).setCategoryHidden(true, providerID: provider.id, kind: .live, categoryID: "3")
        // New panel: every category has a new ID.
        try catalog.replaceCategories(names.reversed().enumerated().map {
            Category(providerID: provider.id, kind: .live, categoryID: "c\($0.offset)", name: $0.element)
        }, providerID: provider.id, kind: .live)
        #expect(try ids(database, "SELECT categoryID FROM categoryOverride WHERE isHidden") == ["c7"])
    }

    @Test func ambiguousMatchesAreNotGuessed() {
        let old = [CatalogRelinker.Item(id: "1", name: "UK: Sports Extra")]
        let new = [CatalogRelinker.Item(id: "8", name: "UK| SPORTS EXTRA 1", group: "UK | Sports"),
                   CatalogRelinker.Item(id: "9", name: "UK| SPORTS EXTRA 2", group: "UK | Sports")]
        #expect(CatalogRelinker.plan(old: old, new: new, referenced: ["1"]).isEmpty)
        // The same channel listed twice (a backup feed) is fine to pick.
        let twice = [CatalogRelinker.Item(id: "8", name: "UK| SPORTS EXTRA"), CatalogRelinker.Item(id: "9", name: "UK| SPORTS EXTRA HD")]
        #expect(CatalogRelinker.plan(old: old, new: twice, referenced: ["1"]).moves == ["1": "8"])
        // A different region isn't the same channel.
        let us = [CatalogRelinker.Item(id: "8", name: "US| SPORTS EXTRA")]
        #expect(CatalogRelinker.plan(old: old, new: us, referenced: ["1"]).isEmpty)
    }
}
