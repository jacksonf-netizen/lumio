import Foundation
import GRDB
import Testing
@testable import IPTVCore

@Suite("Multi-provider catalog sync")
struct CatalogSyncTests {
    let database: AppDatabase
    let providerA: Provider
    let providerB: Provider
    let transportA = StubTransport.healthyProvider()
    let transportB = StubTransport.healthyProvider()
    let connections = ConnectionManager()
    let clock = ManualClock(.fixtureNow)
    let service: CatalogSyncService

    init() throws {
        database = try AppDatabase.inMemory()
        let repo = ProviderRepository(database: database)
        providerA = try repo.insert(TestData.provider("A"))
        providerB = try repo.insert(TestData.provider("B"))
        service = CatalogSyncService(
            database: database,
            sources: StubSourceFactory(transports: [providerA.id: transportA, providerB.id: transportB]),
            connections: connections, clock: clock)
    }

    @Test func fullRefreshStoresEverythingAndUpdatesAccountStatus() async throws {
        let report = await service.refresh(providerA.id)
        #expect(report.error == nil)
        #expect(report.partErrors.isEmpty)
        #expect(report.live?.inserted == 5)

        let counts = try CatalogRepository(database: database).counts(providerID: providerA.id)
        #expect(counts == CatalogCounts(channels: 5, movies: 3, series: 2, programmes: 3))

        let stored = try #require(try ProviderRepository(database: database).provider(id: providerA.id))
        #expect(stored.maxConnections == 2)
        #expect(stored.accountStatus == "Active")
        #expect(stored.allowedOutputFormats == ["m3u8", "ts", "rtmp"])
        #expect(stored.lastRefreshAt == Date.fixtureNow)
        #expect(stored.lastError == nil)
        #expect(await connections.limit(for: providerA.id) == 2)
    }

    @Test func twoProvidersMergeIntoLogicalChannels() async throws {
        await service.refresh(providerA.id, parts: .catalog)
        await service.refresh(providerB.id, parts: .catalog)
        let store = LogicalChannelStore(database: database)
        let id = try #require(try store.logicalChannelID(providerID: providerA.id, streamID: 101))
        let sources = try store.sources(of: id)
        #expect(Set(sources.map(\.providerID)) == [providerA.id, providerB.id])
        // Preferred provider first.
        #expect(sources.first?.providerID == providerA.id)
    }

    @Test func secondRefreshWithNoChangesTouchesNothing() async throws {
        await service.refresh(providerA.id, parts: .catalog)
        clock.advance(3600)
        let report = await service.refresh(providerA.id, parts: .catalog)
        #expect(report.live?.changed == false)
        #expect(report.live?.unchanged == 5)
    }

    @Test func channelsRemovedByTheProviderAreRemovedLocally() async throws {
        await service.refresh(providerA.id, parts: .catalog)
        transportA.set("get_live_streams", body: #"[{"stream_id":101,"name":"Only one left"}]"#)
        let report = await service.refresh(providerA.id, parts: .catalog)
        #expect(report.live?.deleted == 4)
        #expect(report.live?.updated == 1)
        #expect(try CatalogRepository(database: database).channels(providerID: providerA.id).map(\.name) == ["Only one left"])
    }

    @Test func aStrayEmptyListKeepsTheCatalogUntilARefreshConfirmsIt() async throws {
        await service.refresh(providerA.id, parts: .catalog)
        let catalog = CatalogRepository(database: database)
        transportA.set("get_live_streams", body: "[]")
        // First empty answer: kept, and reported.
        var report = await service.refresh(providerA.id, parts: .catalog)
        #expect(try catalog.counts(providerID: providerA.id).channels == 5)
        #expect(report.partErrors[.live] != nil)
        #expect(try catalog.counts(providerID: providerA.id).movies == 3)
        // The provider recovers: the empty answer is forgotten.
        transportA.set("get_live_streams", fixture: "xtream/live_streams.json")
        report = await service.refresh(providerA.id, parts: .catalog)
        #expect(report.partErrors[.live] == nil)
        transportA.set("get_live_streams", body: "[]")
        await service.refresh(providerA.id, parts: .catalog)
        #expect(try catalog.counts(providerID: providerA.id).channels == 5)
        // Empty twice in a row: the provider really has no channels now.
        report = await service.refresh(providerA.id, parts: .catalog)
        #expect(report.partErrors[.live] == nil)
        #expect(try catalog.counts(providerID: providerA.id).channels == 0)
    }

    @Test func editedLoginRestartsARunningRefresh() async throws {
        // A refresh with the old, expired login is still waiting on a slow provider when the user
        // saves a new login.
        transportA.set("auth", fixture: "xtream/auth_failed.json")
        transportA.delay = .milliseconds(300)
        async let first = service.refresh(providerA.id)
        try await Task.sleep(for: .milliseconds(50))
        transportA.delay = nil
        transportA.set("auth", fixture: "xtream/auth_ok.json")
        let second = await service.refresh(providerA.id, restart: true)
        _ = await first
        #expect(second.error == nil)
        #expect((second.live?.inserted ?? 0) + (second.live?.unchanged ?? 0) == 5)
        // Afterwards, refreshes are shared again as before.
        async let a = service.refresh(providerA.id, parts: .catalog)
        async let b = service.refresh(providerA.id, parts: .catalog)
        _ = await (a, b)
    }

    @Test func aRefreshFinishingAfterAnEditKeepsTheEdit() async throws {
        // The user renames the provider and changes its address while a slow refresh is running.
        transportA.delay = .milliseconds(300)
        async let running = service.refresh(providerA.id, parts: .catalog)
        try await Task.sleep(for: .milliseconds(50))
        let providers = ProviderService(database: database, secrets: InMemorySecretStore())
        var edited = try #require(try providers.repository.provider(id: providerA.id))
        edited.name = "Renamed"
        try await providers.updateProvider(edited, serverURL: "http://new.example.com:8080")
        let report = await running
        #expect(report.error == nil)

        let stored = try #require(try providers.repository.provider(id: providerA.id))
        #expect(stored.name == "Renamed")
        #expect(stored.serverURL.absoluteString == "http://new.example.com:8080")
        // And the refresh's own results were still saved.
        #expect(stored.lastRefreshAt != nil)
        #expect(stored.maxConnections != nil)
    }

    @Test func badCredentialsStopTheRefreshAndAreRecorded() async throws {
        transportA.set("auth", fixture: "xtream/auth_failed.json")
        let report = await service.refresh(providerA.id)
        #expect(report.error == XtreamError.unauthorized.description, "got \(report.error ?? "nil")")
        #expect(!transportA.requestedActions.contains("get_live_streams"))
        let stored = try ProviderRepository(database: database).provider(id: providerA.id)
        #expect(stored?.lastError == XtreamError.unauthorized.description)
    }

    @Test func oneFailingPartDoesNotBlockTheOthers() async throws {
        transportA.set("get_vod_streams", body: "", status: 500)
        let report = await service.refresh(providerA.id, parts: .catalog)
        #expect(report.partErrors[.movies] != nil)
        #expect(report.live?.inserted == 5)
        #expect(report.series?.inserted == 2)
        let stored = try ProviderRepository(database: database).provider(id: providerA.id)
        #expect(stored?.lastError?.contains("movies") == true)
        #expect(stored?.lastRefreshAt == nil) // not marked fresh, so it retries soon
    }

    @Test func concurrentRefreshesOfOneProviderShareOneRun() async throws {
        async let first = service.refresh(providerA.id, parts: .catalog)
        async let second = service.refresh(providerA.id, parts: .catalog)
        _ = await (first, second)
        #expect(transportA.requestedActions.filter { $0 == "get_live_streams" }.count == 1)
    }

    @Test func staleCheckUsesIntervals() async throws {
        await service.refresh(providerA.id)
        let fresh = try #require(try ProviderRepository(database: database).provider(id: providerA.id))
        #expect(await service.stalePart(of: fresh).isEmpty)
        clock.advance(13 * 3600)
        #expect(await service.stalePart(of: fresh) == .all)
    }

    @Test func errorsNeverLeakCredentials() async throws {
        transportA.fail("auth", with: URLError(.cannotConnectToHost, userInfo: [
            NSURLErrorFailingURLErrorKey: URL(string: "http://example.test/player_api.php?username=user&password=pass")!,
        ]))
        let report = await service.refresh(providerA.id)
        let text = try #require(report.error)
        #expect(!text.contains("pass"))
    }

    @Test func eventsAreStreamedToSubscribers() async throws {
        let events = await service.events()
        let collector = Task { () -> [SyncEvent] in
            var seen: [SyncEvent] = []
            for await event in events {
                seen.append(event)
                if case .finished = event { break }
            }
            return seen
        }
        await service.refresh(providerA.id, parts: .catalog)
        let seen = await collector.value
        #expect(seen.first == .started(providerA.id))
        #expect(seen.contains(.step(providerA.id, .live)))
        #expect(seen.last == .finished(providerA.id, error: nil))
    }
}
