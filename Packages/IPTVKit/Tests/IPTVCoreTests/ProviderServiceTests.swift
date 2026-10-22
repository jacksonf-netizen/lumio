import Foundation
import GRDB
import Testing
@testable import IPTVCore

@Suite("Provider service")
struct ProviderServiceTests {
    let database: AppDatabase
    let secrets: InMemorySecretStore
    let service: ProviderService

    init() throws {
        database = try AppDatabase.inMemory()
        secrets = InMemorySecretStore()
        service = ProviderService(database: database, secrets: secrets)
    }

    @Test func addStoresCredentialsOnlyInTheSecretStore() async throws {
        let password = "UniquePassword-\(UUID().uuidString)"
        let provider = try await service.addProvider(
            name: "Main", serverURL: "example.com:8080",
            credentials: ProviderCredentials(username: "alice-unique", password: password))

        #expect(provider.serverURL.absoluteString == "http://example.com:8080")
        #expect(try service.credentials(for: provider.id) == ProviderCredentials(username: "alice-unique", password: password))

        // No text column anywhere in the database may contain the username or password.
        try await database.reader.read { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                """)
            for table in tables {
                for column in try db.columns(in: table) {
                    let hits = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM "\(table)"
                        WHERE CAST("\(column.name)" AS TEXT) LIKE '%' || ? || '%'
                           OR CAST("\(column.name)" AS TEXT) LIKE '%alice-unique%'
                        """, arguments: [password]) ?? 0
                    #expect(hits == 0, "credentials found in \(table).\(column.name)")
                }
            }
        }
    }

    @Test func removeDeletesRowAndSecret() async throws {
        let provider = try await service.addProvider(
            name: "Main", serverURL: "http://example.com",
            credentials: ProviderCredentials(username: "u", password: "p"))
        try await service.removeProvider(id: provider.id)
        #expect(try service.repository.all().isEmpty)
        #expect(try service.credentials(for: provider.id) == nil)
        #expect(secrets.count == 0)
    }

    @Test func newProvidersGetIncreasingPriority() async throws {
        let creds = ProviderCredentials(username: "u", password: "p")
        let a = try await service.addProvider(name: "A", serverURL: "a.test", credentials: creds)
        let b = try await service.addProvider(name: "B", serverURL: "b.test", credentials: creds)
        #expect(a.priority == 0)
        #expect(b.priority == 1)
    }

    @Test func reorderRewritesPriorities() async throws {
        let creds = ProviderCredentials(username: "u", password: "p")
        let a = try await service.addProvider(name: "A", serverURL: "a.test", credentials: creds)
        let b = try await service.addProvider(name: "B", serverURL: "b.test", credentials: creds)
        let c = try await service.addProvider(name: "C", serverURL: "c.test", credentials: creds)
        try service.repository.reorder([c.id, a.id])
        #expect(try service.repository.all().map(\.name) == ["C", "A", "B"])
        #expect(try service.repository.all().map(\.priority) == [0, 1, 2])
        _ = b
    }

    @Test func validationRejectsMissingFields() async throws {
        await #expect(throws: ProviderService.ValidationError.missingUsername) {
            try await service.addProvider(name: "X", serverURL: "x.test",
                                          credentials: ProviderCredentials(username: "  ", password: "p"))
        }
        await #expect(throws: ProviderService.ValidationError.missingPassword) {
            try await service.addProvider(name: "X", serverURL: "x.test",
                                          credentials: ProviderCredentials(username: "u", password: ""))
        }
        await #expect(throws: ServerURLError.empty) {
            try await service.addProvider(name: "X", serverURL: "",
                                          credentials: ProviderCredentials(username: "u", password: "p"))
        }
        #expect(secrets.count == 0)
        #expect(try service.repository.all().isEmpty)
    }

    @Test func blankNameFallsBackToHost() async throws {
        let provider = try await service.addProvider(
            name: " ", serverURL: "http://tv.example.test:8080",
            credentials: ProviderCredentials(username: "u", password: "p"))
        #expect(provider.name == "tv.example.test")
    }

    @Test func playbackUsesAnEditedLoginStraightAway() async throws {
        let database = try AppDatabase.inMemory()
        let secrets = InMemorySecretStore()
        let service = ProviderService(database: database, secrets: secrets)
        let provider = try await service.addProvider(name: "P", serverURL: "http://old.test:8080",
                                                     credentials: ProviderCredentials(username: "olduser", password: "oldpass"))
        let resolver = ProviderStreamResolver(database: database, secrets: secrets)
        let source = PlaybackSource(providerID: provider.id, itemID: "7", providerName: "P")
        #expect(try resolver.url(for: source, content: .live, format: .ts).absoluteString == "http://old.test:8080/live/olduser/oldpass/7.ts")
        try await service.updateProvider(provider, serverURL: "http://new.test:8080",
                                          credentials: ProviderCredentials(username: "newuser", password: "newpass"))
        #expect(try resolver.url(for: source, content: .live, format: .ts).absoluteString == "http://new.test:8080/live/newuser/newpass/7.ts")
    }
}
