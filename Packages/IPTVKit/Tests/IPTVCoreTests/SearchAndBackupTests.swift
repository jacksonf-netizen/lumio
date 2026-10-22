import Foundation
import GRDB
import Testing
@testable import IPTVCore

@Suite("Search and backup")
struct SearchAndBackupTests {
    let database: AppDatabase
    let provider: Provider

    init() throws {
        database = try AppDatabase.inMemory()
        provider = try ProviderRepository(database: database).insert(TestData.provider("Main"))
        let catalog = CatalogRepository(database: database)
        try catalog.replaceChannels([
            Channel(providerID: provider.id, streamID: 1, name: "Sky Sports Main Event", epgChannelID: "sky.main"),
            Channel(providerID: provider.id, streamID: 2, name: "Télé Café"),
        ], providerID: provider.id)
        try catalog.replaceMovies([Movie(providerID: provider.id, streamID: 10, name: "Skyfall (2012)")], providerID: provider.id)
        try catalog.replaceSeries([Series(providerID: provider.id, seriesID: 20, name: "Sky High Show")], providerID: provider.id)
        try LogicalChannelStore(database: database).rebuild()
        try database.writer.write { [provider] db in
            var later = Programme(providerID: provider.id, epgID: "sky.main", start: Date().addingTimeInterval(3600),
                                  stop: Date().addingTimeInterval(7200), title: "Premier League Live")
            var past = Programme(providerID: provider.id, epgID: "sky.main", start: Date().addingTimeInterval(-7200),
                                 stop: Date().addingTimeInterval(-3600), title: "Premier League Review")
            try later.insert(db)
            try past.insert(db)
        }
    }

    @Test func searchesEverythingByWordPrefix() async throws {
        let search = SearchRepository(database: database)
        let sky = try await search.search("sky")
        #expect(sky.channels.map(\.name) == ["Sky Sports Main Event"])
        #expect(sky.movies.map(\.itemID) == [10])
        #expect(sky.series.map(\.itemID) == [20])

        let league = try await search.search("premier lea")
        #expect(league.programmes.map(\.programme.title) == ["Premier League Live"]) // past airings excluded
        #expect(league.programmes.first?.channel?.name == "Sky Sports Main Event")

        #expect(try await search.search("tele cafe").channels.map(\.name) == ["Télé Café"])
        #expect(try await search.search("   ").isEmpty)
    }

    @Test func resultsGroupByProviderInPriorityOrder() async throws {
        let backup = try ProviderRepository(database: database).insert(TestData.provider("Backup"))
        let catalog = CatalogRepository(database: database)
        try catalog.replaceChannels([Channel(providerID: backup.id, streamID: 5, name: "Sky News")], providerID: backup.id)
        try catalog.replaceMovies([Movie(providerID: backup.id, streamID: 11, name: "Sky Captain")], providerID: backup.id)
        try LogicalChannelStore(database: database).rebuild()

        let results = try await SearchRepository(database: database).search("sky")
        let groups = results.grouped(by: [provider.id, backup.id])
        #expect(groups.map(\.provider) == [provider.id, backup.id])
        #expect(groups[0].results.channels.map(\.name) == ["Sky Sports Main Event"])
        #expect(groups[0].results.movies.map(\.itemID) == [10])
        #expect(groups[0].results.series.map(\.itemID) == [20])
        #expect(groups[1].results.channels.map(\.name) == ["Sky News"])
        #expect(groups[1].results.movies.map(\.itemID) == [11])
        #expect(results.grouped(by: [backup.id, provider.id]).map(\.provider) == [backup.id, provider.id])
    }

    @Test func renamedChannelsAreFoundByTheirNewName() async throws {
        let library = LibraryRepository(database: database)
        let channel = try #require(try await LiveCatalog(database: database).allChannels().first { $0.streamID == 2 })
        try await library.rename(channel, to: "My Coffee Channel")
        #expect(try await SearchRepository(database: database).search("coffee").channels.map(\.name) == ["My Coffee Channel"])
    }

    @Test func backupRoundTripsOntoAFreshInstallWithoutCredentials() async throws {
        let library = LibraryRepository(database: database)
        let channel = try #require(try await LiveCatalog(database: database).allChannels().first)
        try await library.toggleFavorite(channel)
        try await library.rename(channel, to: "Sky 1")
        let group = try await library.createGroup(named: "Sport")
        try await library.add(channel, toGroup: group.id)
        try await library.saveProgress(kind: .movie, providerID: provider.id, itemID: "10", position: 300, duration: 6000)
        try SettingsRepository(database: database).set(BufferPreset.large, for: .bufferPreset)
        try SettingsRepository(database: database).set(EngineKind.avPlayer, for: .engine, scope: .provider(provider.id))

        let data = try await BackupService(database: database).export()
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("password"))
        #expect(!text.contains("username"))

        // A new install with the same provider (different id) gets everything back.
        let fresh = try AppDatabase.inMemory()
        let newProvider = try ProviderRepository(database: fresh).insert(TestData.provider("Main"))
        try CatalogRepository(database: fresh).replaceChannels([
            Channel(providerID: newProvider.id, streamID: 1, name: "Sky Sports Main Event", epgChannelID: "sky.main"),
        ], providerID: newProvider.id)
        try LogicalChannelStore(database: fresh).rebuild()
        let summary = try await BackupService(database: fresh).importBackup(data)
        #expect(summary.matchedProviders == ["Main"])
        #expect(summary.skipped == 0)

        let restored = try #require(try await LiveCatalog(database: fresh).allChannels().first)
        #expect(restored.name == "Sky 1")
        #expect(restored.isFavorite)
        let groups = try await LiveCatalog(database: fresh).groups()
        #expect(groups.contains { $0.kind == .custom && $0.name == "Sport" })
        #expect(try SettingsRepository(database: fresh).value(BufferPreset.self, for: .bufferPreset) == .large)
        #expect(try SettingsRepository(database: fresh).value(EngineKind.self, for: .engine, scope: .provider(newProvider.id)) == .avPlayer)
        #expect(try await VODCatalog(database: fresh).progress(kind: .movie, providerID: newProvider.id, itemID: "10")?.positionSeconds == 300)
    }

    @Test func rejectsFilesThatArentBackups() async {
        await #expect(throws: BackupService.BackupError.self) {
            try await BackupService(database: database).importBackup(Data("{\"hello\": 1}".utf8))
        }
    }
}
