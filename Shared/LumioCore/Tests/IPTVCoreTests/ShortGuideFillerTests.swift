import Foundation
import Testing
@testable import IPTVCore

@Suite("Short guide for providers without a guide file")
struct ShortGuideFillerTests {
    /// Before the fixture's programmes (18:00–19:00 UTC on 17 October 2026).
    let clock = ManualClock(Date(timeIntervalSince1970: 1_792_250_000))
    let database: AppDatabase
    let provider: Provider
    let transport = StubTransport.healthyProvider()
    let filler: ShortGuideFiller

    init() async throws {
        database = try AppDatabase.inMemory()
        provider = try ProviderRepository(database: database).insert(TestData.provider("A"))
        transport.set("get_short_epg", fixture: "xtream/short_epg.json")
        let sources = StubSourceFactory(transports: [provider.id: transport])
        let sync = CatalogSyncService(database: database, sources: sources, connections: ConnectionManager(), clock: clock)
        await sync.refresh(provider.id, parts: .catalog)
        filler = ShortGuideFiller(database: database, sources: sources, clock: clock)
    }

    private var bbcOne: EPGRef { EPGRef(epgID: "BBCOne.uk", providers: [provider.id]) }

    private func shortRequests() -> Int { transport.requestedActions.filter { $0 == "get_short_epg" }.count }

    private func markGuideMissing() throws {
        var failed = try #require(try ProviderRepository(database: database).provider(id: provider.id))
        failed.lastError = "guide: The provider has no guide download at this address (\"not found\")."
        try ProviderRepository(database: database).updateStatus(failed)
    }

    @Test func asksForTheChannelsOnScreenAndStoresWhatsOn() async throws {
        try markGuideMissing()
        #expect(await filler.fill([bbcOne]))
        #expect(shortRequests() == 1)
        let window = DateInterval(start: clock.now(), duration: 6 * 3600)
        let found = try await GuideRepository(database: database).programmes(for: [bbcOne], in: window)
        #expect(found[bbcOne]?.map(\.title) == ["News at Six", "Plain Title"])

        // Not asked again while it has programmes to come, or within half an hour.
        #expect(await filler.fill([bbcOne]) == false)
        clock.advance(ShortGuideFiller.retryAfter + 60)
        #expect(await filler.fill([bbcOne]) == false)
        #expect(shortRequests() == 1)
    }

    @Test func channelsWithoutAGuideIDOrAStreamAreSkipped() async throws {
        try markGuideMissing()
        #expect(await filler.fill([EPGRef(epgID: "nobody.uk", providers: [provider.id])]) == false)
        #expect(shortRequests() == 0)
    }

    @Test func aProviderWithAWorkingGuideFileIsNeverAsked() async throws {
        // Programmes from a guide file (importedAt > 0) and no guide problem.
        try await database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO programme (providerID, epgID, start, stop, title, importedAt) VALUES (?, 'other.uk', 0, 1, 'Old', 5)
                """, arguments: [provider.id])
        }
        #expect(await filler.fill([bbcOne]) == false)
        #expect(shortRequests() == 0)
    }

    @Test func theNextGuideFileReplacesWhatItStored() async throws {
        try markGuideMissing()
        await filler.fill([bbcOne])
        let summary = try await EPGImporter(database: database, clock: clock).importGuide(
            file: try #require(Bundle.module.url(forResource: "Fixtures/xmltv/guide.xml", withExtension: nil)),
            providerID: provider.id)
        #expect(summary.programmesStored > 0)
        let leftover = try await database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM programme WHERE importedAt = 0") ?? -1
        }
        #expect(leftover == 0)
    }
}
