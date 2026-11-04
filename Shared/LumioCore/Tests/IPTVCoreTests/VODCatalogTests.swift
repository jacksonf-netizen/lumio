import Foundation
import GRDB
import Testing
@testable import IPTVCore

@Suite("Movies and series")
struct VODCatalogTests {
    let database: AppDatabase
    let provider: Provider
    let vod: VODCatalog
    let library: LibraryRepository

    init() throws {
        database = try AppDatabase.inMemory()
        provider = try ProviderRepository(database: database).insert(TestData.provider())
        vod = VODCatalog(database: database)
        library = LibraryRepository(database: database)
        let catalog = CatalogRepository(database: database)
        try catalog.replaceCategories([Category(providerID: provider.id, kind: .movie, categoryID: "m1", name: "Action")],
                                      providerID: provider.id, kind: .movie)
        try catalog.replaceCategories([Category(providerID: provider.id, kind: .series, categoryID: "s1", name: "Drama")],
                                      providerID: provider.id, kind: .series)
        try catalog.replaceMovies([
            Movie(providerID: provider.id, streamID: 1, name: "Old Film (1999)", categoryID: "m1", year: 1999,
                  containerExtension: "mkv", addedAt: Date(timeIntervalSince1970: 1_000), sortIndex: 0),
            Movie(providerID: provider.id, streamID: 2, name: "New Film", categoryID: "m1",
                  addedAt: Date(timeIntervalSince1970: 2_000), sortIndex: 1),
        ], providerID: provider.id)
        try catalog.replaceSeries([Series(providerID: provider.id, seriesID: 10, name: "Show", categoryID: "s1")], providerID: provider.id)
        try catalog.replaceSeriesDetails(SeriesDetails(plot: "Plot", seasons: [
            Season(providerID: provider.id, seriesID: 10, seasonNumber: 1),
        ], episodes: (1...3).map {
            Episode(providerID: provider.id, episodeID: "e\($0)", seriesID: 10, seasonNumber: 1, episodeNumber: $0, title: "Ep \($0)")
        }), providerID: provider.id, seriesID: 10)
    }

    @Test func listsCategoriesItemsAndRecentlyAdded() async throws {
        #expect(try await vod.categories(.movie).map(\.name) == ["Action"])
        let movies = try await vod.items(.movie)
        #expect(movies.map(\.displayName) == ["Old Film", "New Film"])
        #expect(movies.first?.year == 1999)
        #expect(try await vod.items(.movie, recent: true).map(\.itemID) == [2, 1])
        #expect(try await vod.items(.movie, search: "new").map(\.itemID) == [2])
        #expect(try await vod.items(.series).map(\.name) == ["Show"])
    }

    @Test func progressDrivesContinueWatchingAndWatchedState() async throws {
        try await library.saveProgress(kind: .movie, providerID: provider.id, itemID: "1", position: 600, duration: 6000)
        try await library.saveProgress(kind: .episode, providerID: provider.id, itemID: "e2", position: 120, duration: 2400,
                                       now: Date().addingTimeInterval(10))
        let continuing = try await vod.continueWatching()
        #expect(continuing.map(\.itemID) == ["e2", "1"])
        #expect(continuing[0].title == "Show")
        #expect(continuing[0].subtitle == "S1 E2 · Ep 2")
        #expect(continuing[1].progress == 0.1)
        #expect(try await vod.items(.movie).first { $0.itemID == 1 }?.progress == 0.1)

        // Nearly finished counts as watched and leaves Continue Watching.
        try await library.saveProgress(kind: .movie, providerID: provider.id, itemID: "1", position: 5900, duration: 6000)
        #expect(try await vod.progress(kind: .movie, providerID: provider.id, itemID: "1")?.isWatched == true)
        #expect(try await vod.continueWatching().map(\.itemID) == ["e2"])
    }

    @Test func recentlyWatchedListsMoviesAndOneEntryPerSeries() async throws {
        try await database.writer.write { [provider] db in
            let plays: [(LibraryItemKind, String, Double)] = [(.movie, "1", 100), (.episode, "e1", 200), (.episode, "e2", 300), (.movie, "2", 400)]
            for (kind, id, time) in plays {
                try RecentItem(providerID: provider.id, itemKind: kind, itemID: id, lastPlayedAt: Date(timeIntervalSince1970: time)).upsert(db)
            }
        }
        try await library.saveProgress(kind: .movie, providerID: provider.id, itemID: "1", position: 600, duration: 6000)

        let movies = try await vod.recentlyWatched(.movie)
        #expect(movies.map(\.itemID) == ["2", "1"])
        #expect(movies[1].canResume)
        #expect(!movies[0].canResume) // played but no progress saved

        // One entry for the series, showing the episode played last.
        let shows = try await vod.recentlyWatched(.series)
        #expect(shows.map(\.itemID) == ["e2"])
        #expect(shows.first?.seriesID == 10)
        #expect(shows.first?.title == "Show")
        #expect(shows.first?.subtitle == "S1 E2 · Ep 2")

        // Removing takes the whole series out, and keeps progress for resuming from the detail page.
        try await library.removeRecent(kind: .series, providerID: provider.id, itemID: "10")
        #expect(try await vod.recentlyWatched(.series).isEmpty)
        try await library.removeRecent(kind: .movie, providerID: provider.id, itemID: "1")
        #expect(try await vod.recentlyWatched(.movie).map(\.itemID) == ["2"])
        #expect(try await vod.progress(kind: .movie, providerID: provider.id, itemID: "1")?.positionSeconds == 600)

        try await library.clearRecents([.movie])
        #expect(try await vod.recentlyWatched(.movie).isEmpty)
    }

    @Test func shortItemsArentMarkedWatchedHalfwayThrough() async throws {
        try await library.saveProgress(kind: .movie, providerID: provider.id, itemID: "2", position: 57, duration: 120)
        #expect(try await vod.progress(kind: .movie, providerID: provider.id, itemID: "2")?.isWatched == false)
        // Long content: the last 3 minutes (credits) count as watched.
        try await library.saveProgress(kind: .movie, providerID: provider.id, itemID: "1", position: 5300, duration: 5400)
        #expect(try await vod.progress(kind: .movie, providerID: provider.id, itemID: "1")?.isWatched == true)
    }

    @Test func hiddenVODCategoriesDisappearAndAreListed() async throws {
        try await library.setCategoryHidden(true, providerID: provider.id, kind: .movie, categoryID: "m1")
        #expect(try await vod.categories(.movie).isEmpty)
        #expect(try await library.hiddenCategories().map(\.name) == ["Action"])
        try await library.setCategoryHidden(false, providerID: provider.id, kind: .movie, categoryID: "m1")
        #expect(try await vod.categories(.movie).map(\.name) == ["Action"])
    }

    @Test func nextEpisodeLogic() async throws {
        #expect(try await vod.nextEpisode(providerID: provider.id, seriesID: 10)?.0.episodeID == "e1")
        try await library.setWatched(true, kind: .episode, providerID: provider.id, itemID: "e1")
        #expect(try await vod.nextEpisode(providerID: provider.id, seriesID: 10)?.0.episodeID == "e2")
        try await library.saveProgress(kind: .episode, providerID: provider.id, itemID: "e3", position: 300, duration: 2400)
        let next = try await vod.nextEpisode(providerID: provider.id, seriesID: 10)
        #expect(next?.0.episodeID == "e3")
        #expect(next?.1?.positionSeconds == 300)
    }

    @Test func favoritesAndPlaybackItems() async throws {
        try await library.setFavorite(true, kind: .movie, providerID: provider.id, itemID: "2")
        #expect(try await vod.favorites(.movie).map(\.itemID) == [2])
        let builder = PlaybackItemBuilder(database: database)
        let item = try #require(try builder.movieItem(providerID: provider.id, streamID: 1, startPosition: 42))
        #expect(item.content == .movie)
        #expect(item.startPosition == 42)
        #expect(item.sources.first?.containerExtension == "mkv")
        let episode = try #require(try builder.episodeItem(providerID: provider.id, episodeID: "e2"))
        #expect(episode.title == "Show · S1 E2 · Ep 2")
    }
}
