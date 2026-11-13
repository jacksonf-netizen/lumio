import Foundation
import GRDB
import Testing
@testable import IPTVCore

/// Storing a big provider: the search index is rebuilt once instead of row by row, with the same
/// result; and the year is read from titles without a Regex.
@Suite("Storing big lists")
struct BulkStoreTests {
    let database: AppDatabase
    let provider: Provider

    init() throws {
        database = try AppDatabase.inMemory()
        provider = try ProviderRepository(database: database).insert(TestData.provider("A"))
    }

    private func movies(_ count: Int, from start: Int = 0) -> [Movie] {
        (start..<(start + count)).map {
            Movie(providerID: provider.id, streamID: $0, name: "Bulk Movie \($0)", categoryID: "1", sortIndex: $0)
        }
    }

    private func trigger(_ name: String) throws -> Bool {
        try database.reader.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND name = ?)",
                              arguments: [name]) ?? false
        }
    }

    @Test func aBigFirstLoadIsSearchableAndKeepsTheTrigger() async throws {
        let count = CatalogRepository.bulkInserts + 500
        let stats = try CatalogRepository(database: database).replaceMovies(movies(count), providerID: provider.id)
        #expect(stats.inserted == count)
        #expect(try trigger("__movieFTS_ai"))

        let found = try await SearchRepository(database: database).search("Bulk Movie 1234")
        #expect(found.movies.contains { $0.name == "Bulk Movie 1234" })

        // Later single inserts are indexed through the trigger again.
        try CatalogRepository(database: database).replaceMovies(movies(count) + movies(1, from: 90_000), providerID: provider.id)
        let later = try await SearchRepository(database: database).search("Bulk Movie 90000")
        #expect(later.movies.map(\.name) == ["Bulk Movie 90000"])
    }

    @Test func removedMoviesLeaveTheIndex() async throws {
        let count = CatalogRepository.bulkInserts + 10
        try CatalogRepository(database: database).replaceMovies(movies(count), providerID: provider.id)
        try CatalogRepository(database: database).replaceMovies(movies(10), providerID: provider.id)
        let gone = try await SearchRepository(database: database).search("Bulk Movie 1005")
        #expect(gone.movies.isEmpty)
        let ftsRows = try await database.reader.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM movieFTS") }
        #expect(ftsRows == 10)
    }

    @Test(arguments: [
        ("The Odyssey (2026)", 2026), ("NL - THE ODYSSEY (2026).", 2026), ("Old (1999) (2020)", 1999),
        ("Blade Runner 2049", nil), ("Film (1899)", nil), ("Film (2O20)", nil), ("(2001)", 2001), ("", nil),
        ("Ça (2017)", 2017), ("(20)", nil),
    ] as [(String, Int?)])
    func yearsInTitles(title: String, year: Int?) {
        #expect(XtreamSourceProvider.year(fromTitle: title) == year)
    }
}
