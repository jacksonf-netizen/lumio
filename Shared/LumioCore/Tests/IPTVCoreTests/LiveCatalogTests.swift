import Foundation
import GRDB
import Testing
@testable import IPTVCore

@Suite("Live catalog, guide and library")
struct LiveCatalogTests {
    let database: AppDatabase
    let a: Provider
    let b: Provider
    let catalog: LiveCatalog
    let library: LibraryRepository
    let guide: GuideRepository

    init() throws {
        database = try AppDatabase.inMemory()
        let repo = ProviderRepository(database: database)
        a = try repo.insert(TestData.provider("A"))
        var bProvider = try repo.insert(TestData.provider("B"))
        bProvider.epgTimeOffsetMinutes = 60
        try repo.update(bProvider)
        b = bProvider
        catalog = LiveCatalog(database: database)
        library = LibraryRepository(database: database, clock: ManualClock(.fixtureNow))
        guide = GuideRepository(database: database)

        let catalogRepo = CatalogRepository(database: database)
        try catalogRepo.replaceCategories([
            Category(providerID: a.id, kind: .live, categoryID: "1", name: "UK News", sortIndex: 0),
            Category(providerID: a.id, kind: .live, categoryID: "2", name: "Sport", sortIndex: 1),
        ], providerID: a.id, kind: .live)
        try catalogRepo.replaceCategories([
            Category(providerID: b.id, kind: .live, categoryID: "10", name: "uk news", sortIndex: 0),
        ], providerID: b.id, kind: .live)
        try catalogRepo.replaceChannels([
            Channel(providerID: a.id, streamID: 1, number: 101, name: "UK: BBC One HD", epgChannelID: "bbcone.uk", categoryID: "1", sortIndex: 0),
            Channel(providerID: a.id, streamID: 2, number: 102, name: "UK: Sky News", epgChannelID: "skynews.uk", categoryID: "1", sortIndex: 1),
            Channel(providerID: a.id, streamID: 3, number: 201, name: "Sky Sports", epgChannelID: "skysports.uk", categoryID: "2", sortIndex: 2),
        ], providerID: a.id)
        try catalogRepo.replaceChannels([
            Channel(providerID: b.id, streamID: 50, number: 1, name: "BBC One", epgChannelID: "bbcone.uk", categoryID: "10", sortIndex: 0),
            Channel(providerID: b.id, streamID: 51, number: 2, name: "Local Only", categoryID: "10", sortIndex: 1),
        ], providerID: b.id)
        try LogicalChannelStore(database: database).rebuild()
    }

    @Test func mergedViewCombinesSameNamedCategoriesAndChannels() async throws {
        let groups = try await catalog.groups()
        #expect(groups.map(\.name) == ["Favorites", "Recently Watched", "All Channels", "UK News", "Sport"])
        let news = try #require(groups.first { $0.name == "UK News" })
        #expect(news.categories.count == 2)
        let channels = try await catalog.channels(in: news)
        #expect(channels.map(\.name) == ["BBC One HD", "Sky News", "Local Only"])
        #expect(channels[0].sourceProviders == [a.id, b.id])
        #expect(channels[0].epg == EPGRef(epgID: "bbcone.uk", providers: [a.id, b.id]))
    }

    @Test func perProviderFilterShowsOnlyThatProvider() async throws {
        let groups = try await catalog.groups(filter: .only(b.id))
        #expect(groups.filter { $0.kind == .category }.map(\.name) == ["uk news"])
        let all = try await catalog.allChannels(filter: .only(b.id))
        #expect(all.map(\.name) == ["BBC One HD", "Local Only"])
        #expect(all.first?.providerID == b.id)
    }

    @Test func hidingRenamingAndReordering() async throws {
        let news = try #require(try await catalog.groups().first { $0.name == "UK News" })
        var channels = try await catalog.channels(in: news)
        try await library.setHidden(true, channel: channels[1])
        try await library.rename(channels[0], to: "BBC 1")
        channels = try await catalog.channels(in: news)
        #expect(channels.map(\.name) == ["BBC 1", "Local Only"])
        #expect(try await catalog.channels(in: news, includeHidden: true).count == 3)

        try await library.reorder(channels.reversed(), in: news)
        #expect(try await catalog.channels(in: news).map(\.name) == ["Local Only", "BBC 1"])

        try await library.setHidden(true, group: news)
        #expect(!(try await catalog.groups().contains { $0.name == "UK News" }))
        #expect(!(try await catalog.allChannels().contains { $0.name == "Local Only" }))
    }

    @Test func favoritesRecentsAndCustomGroups() async throws {
        let all = try await catalog.allChannels()
        let bbc = try #require(all.first { $0.name == "BBC One HD" })
        let sport = try #require(all.first { $0.name == "Sky Sports" })

        #expect(try await library.toggleFavorite(sport))
        #expect(try await library.toggleFavorite(bbc))
        let favorites = try #require(try await catalog.groups().first { $0.kind == .favorites })
        #expect(try await catalog.channels(in: favorites).map(\.name) == ["Sky Sports", "BBC One HD"])
        #expect(try await library.toggleFavorite(bbc) == false)
        #expect(try await catalog.channels(in: favorites).map(\.name) == ["Sky Sports"])

        try await library.recordPlayed(providerID: b.id, kind: .channel, itemID: "50")
        let recents = try #require(try await catalog.groups().first { $0.kind == .recents })
        #expect(try await catalog.channels(in: recents).map(\.name) == ["BBC One HD"])
        // Removing a merged channel clears it whichever provider it was played from.
        try await library.removeRecent(try #require(try await catalog.channels(in: recents).first))
        #expect(try await catalog.channels(in: recents).isEmpty)

        let group = try await library.createGroup(named: "Evening")
        try await library.add(sport, toGroup: group.id)
        try await library.add(bbc, toGroup: group.id)
        let custom = try #require(try await catalog.groups().first { $0.kind == .custom })
        #expect(custom.name == "Evening")
        #expect(try await catalog.channels(in: custom).map(\.name) == ["Sky Sports", "BBC One HD"])
    }

    @Test func guideUsesPreferredProviderAndAppliesItsOffset() async throws {
        try await database.writer.write { [a, b] db in
            var fromA = Programme(providerID: a.id, epgID: "bbcone.uk", start: .fixtureNow, stop: .fixtureNow.addingTimeInterval(3600), title: "From A")
            var fromB = Programme(providerID: b.id, epgID: "bbcone.uk", start: .fixtureNow, stop: .fixtureNow.addingTimeInterval(3600), title: "From B")
            var onlyB = Programme(providerID: b.id, epgID: "skynews.uk", start: .fixtureNow, stop: .fixtureNow.addingTimeInterval(3600), title: "News via B")
            try fromA.insert(db)
            try fromB.insert(db)
            try onlyB.insert(db)
        }
        let window = DateInterval(start: Date.fixtureNow.addingTimeInterval(-3600), duration: 6 * 3600)
        let bbc = EPGRef(epgID: "bbcone.uk", providers: [a.id, b.id])
        let news = EPGRef(epgID: "skynews.uk", providers: [a.id])
        let result = try await guide.programmes(for: [bbc, news], in: window)
        #expect(result[bbc]?.map(\.title) == ["From A"])
        // A has no data for Sky News, so B's guide is used, shifted by B's +60 min offset.
        #expect(result[news]?.first?.title == "News via B")
        #expect(result[news]?.first?.start == Date.fixtureNow.addingTimeInterval(3600))

        let nowNext = try await guide.nowNext(for: [bbc], at: Date.fixtureNow.addingTimeInterval(60))
        #expect(nowNext[bbc]?.now?.title == "From A")
        #expect(nowNext[bbc]?.progress(at: Date.fixtureNow.addingTimeInterval(1800)) == 0.5)
    }

    @Test func manualEPGMatchOverridesAutomaticChoice() async throws {
        try await database.writer.write { [b] db in
            try EPGChannel(providerID: b.id, epgID: "local.tv", displayName: "Local TV").insert(db)
        }
        let local = try #require(try await catalog.allChannels().first { $0.name == "Local Only" })
        #expect(local.epg == nil)
        let found = try await library.searchGuideChannels("local")
        #expect(found.map(\.epgID) == ["local.tv"])
        try await library.setEPG(found[0], for: local)
        let updated = try #require(try await catalog.allChannels().first { $0.name == "Local Only" })
        #expect(updated.epg == EPGRef(epgID: "local.tv", providers: [b.id]))
        try await library.setEPG(nil, for: updated)
        #expect(try await catalog.allChannels().first { $0.name == "Local Only" }?.epg == nil)
    }

    @Test func playbackItemsIncludeEverySource() throws {
        let builder = PlaybackItemBuilder(database: database)
        let item = try #require(try builder.liveItem(providerID: b.id, streamID: 50))
        #expect(item.sources.map(\.providerID) == [a.id, b.id] || item.sources.map(\.providerID) == [b.id, a.id])
        // The source the user picked is preferred.
        #expect(item.sources.min { $0.providerPriority < $1.providerPriority }?.providerID == b.id)
    }
}
