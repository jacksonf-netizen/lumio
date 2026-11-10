import Testing
@testable import IPTVCore

@Suite("Refresh problems")
struct RefreshProblemsTests {
    @Test func nothingWrong() {
        for text in [nil, "", "  \n"] {
            let problems = RefreshProblems(lastError: text)
            #expect(problems.serious == nil)
            #expect(problems.guide == nil)
            #expect(problems.failedParts.isEmpty)
            #expect(!problems.failedOutright)
        }
    }

    @Test func onlyTheGuide() {
        let problems = RefreshProblems(lastError: "guide: The provider has no guide download at this address (\"not found\").")
        #expect(problems.serious == nil)
        #expect(problems.guide == "The provider has no guide download at this address (\"not found\").")
        #expect(problems.failedParts == ["guide"])
        #expect(!problems.failedOutright)
    }

    @Test func aRefusedLogin() {
        let problems = RefreshProblems(lastError: "The username or password was refused.")
        #expect(problems.serious == "The username or password was refused.")
        #expect(problems.guide == nil)
        #expect(problems.failedParts.isEmpty)
        #expect(problems.failedOutright)
    }

    @Test func partsAndALongMessage() {
        let problems = RefreshProblems(lastError: "guide: timed out\nlive: the list\nwas cut off\nmovies: empty")
        #expect(problems.guide == "timed out")
        #expect(problems.serious == "the list\nwas cut off\nempty")
        #expect(problems.failedParts == ["guide", "live", "movies"])
        #expect(!problems.failedOutright)
    }

    /// The text the sync service writes is what this reads.
    @Test func readsWhatTheSyncServiceWrites() async throws {
        let database = try AppDatabase.inMemory()
        let provider = try ProviderRepository(database: database).insert(TestData.provider("A"))
        let transport = StubTransport.healthyProvider()
        transport.set("xmltv", body: "<html>404 Not Found</html>", status: 404)
        let service = CatalogSyncService(database: database,
                                         sources: StubSourceFactory(transports: [provider.id: transport]),
                                         connections: ConnectionManager(), clock: ManualClock(.fixtureNow))
        await service.refresh(provider.id)
        let saved = try ProviderRepository(database: database).provider(id: provider.id)
        let problems = RefreshProblems(lastError: saved?.lastError)
        #expect(problems.serious == nil)
        #expect(problems.guide?.contains("no guide download") == true)
        #expect(problems.failedParts == ["guide"])
    }
}
