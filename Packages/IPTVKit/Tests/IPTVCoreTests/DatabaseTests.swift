import Foundation
import GRDB
import Testing
@testable import IPTVCore

@Suite("Database and migrations")
struct DatabaseTests {
    @Test func freshDatabaseAppliesAllMigrations() throws {
        let database = try AppDatabase.inMemory()
        #expect(try database.appliedMigrations() == ["v1", "v2-epg-import", "v3-guide-index", "v4-category-region", "v5-category-region-prefix", "v6-region-readings", "v7-category-shown", "v8-episode-relink"])
    }

    @Test func migratingTwiceIsANoOp() throws {
        let queue = try DatabaseQueue()
        _ = try AppDatabase(queue)
        try queue.write { db in try TestData.provider().insert(db) }
        // Opening the same connection again must not fail or touch existing data.
        let reopened = try AppDatabase(queue)
        #expect(try reopened.appliedMigrations() == ["v1", "v2-epg-import", "v3-guide-index", "v4-category-region", "v5-category-region-prefix", "v6-region-readings", "v7-category-shown", "v8-episode-relink"])
        #expect(try queue.read { db in try Provider.fetchCount(db) } == 1)
    }

    @Test func onDiskDatabaseUsesWALAndSurvivesReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iptv-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("iptv.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let provider = TestData.provider("Disk")
        do {
            let database = try AppDatabase.open(at: url)
            try database.writer.write { db in try provider.insert(db) }
            let mode = try database.reader.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
            #expect(mode == "wal")
        }
        let reopened = try AppDatabase.open(at: url)
        #expect(try ProviderRepository(database: reopened).provider(id: provider.id) == provider)
    }

    @Test func datesAreStoredAsUnixTimestamps() throws {
        let database = try AppDatabase.inMemory()
        let provider = TestData.provider()
        try database.writer.write { db in try provider.insert(db) }
        let storage = try database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT typeof(createdAt) FROM provider")
        }
        #expect(storage == "real")
    }

    @Test func modelsRoundTripThroughTheDatabase() throws {
        let database = try AppDatabase.inMemory()
        var provider = TestData.provider()
        provider.allowedOutputFormats = ["ts", "m3u8"]
        provider.expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
        provider.maxConnections = 2
        let channel = Channel(providerID: provider.id, streamID: 7, number: 101, name: "Sky Sports",
                              logoURL: URL(string: "http://logo.test/a.png"), epgChannelID: "sky.uk",
                              tvArchive: true, tvArchiveDuration: 7)
        try database.writer.write { db in
            try provider.insert(db)
            try channel.insert(db)
        }
        let (storedProvider, storedChannel) = try database.reader.read { db in
            (try Provider.fetchOne(db, key: provider.id),
             try Channel.fetchOne(db, key: ["providerID": provider.id.rawValue, "streamID": 7]))
        }
        #expect(storedProvider == provider)
        #expect(storedChannel == channel)
    }

    @Test func deletingAProviderCascadesToEveryProviderOwnedTable() throws {
        let database = try AppDatabase.inMemory()
        let doomed = TestData.provider("Doomed")
        let survivor = TestData.provider("Survivor")
        try database.writer.write { db in
            try doomed.insert(db)
            try survivor.insert(db)
            try TestData.seedEverything(for: doomed.id, in: db)
            try TestData.seedEverything(for: survivor.id, in: db)
        }

        let tables = try database.reader.read { db in try TestData.tables(withColumn: "providerID", in: db) }
        // Guard against the seed helper silently missing a table added in a later migration.
        try database.reader.read { db in
            for table in tables {
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE providerID = ?",
                                             arguments: [doomed.id]) ?? 0
                #expect(count > 0, "seedEverything should insert into \(table)")
            }
        }

        #expect(try ProviderRepository(database: database).delete(id: doomed.id))

        try database.reader.read { db in
            for table in tables {
                let doomedRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE providerID = ?",
                                                  arguments: [doomed.id]) ?? -1
                let survivorRows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE providerID = ?",
                                                    arguments: [survivor.id]) ?? -1
                #expect(doomedRows == 0, "\(table) still has rows for the deleted provider")
                #expect(survivorRows > 0, "\(table) lost rows for the other provider")
            }
            // Rows pointing at the deleted provider's EPG through epgProviderID are gone too.
            let epgRefs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM logicalEPGOverride WHERE epgProviderID = ?",
                                           arguments: [doomed.id])
            #expect(epgRefs == 0)
            // Full-text index entries follow their rows.
            let ftsTitles = try String.fetchAll(db, sql: "SELECT title FROM programmeFTS")
            #expect(ftsTitles == ["News at Six"])
        }
    }

    @Test func fullTextSearchStaysInSyncWithChannels() throws {
        let database = try AppDatabase.inMemory()
        let provider = TestData.provider()
        try database.writer.write { db in
            try provider.insert(db)
            try Channel(providerID: provider.id, streamID: 1, name: "Télé Café HD").insert(db)
            try Channel(providerID: provider.id, streamID: 2, name: "Sky Sports Main Event").insert(db)
        }
        try database.reader.read { db in
            // Diacritics are folded, and prefix queries work for search-as-you-type.
            let pattern = FTS5Pattern(matchingAllPrefixesIn: "tele caf")
            let names = try String.fetchAll(db, sql: """
                SELECT channel.name FROM channel
                JOIN channelFTS ON channelFTS.rowid = channel.rowid
                WHERE channelFTS MATCH ?
                """, arguments: [pattern])
            #expect(names == ["Télé Café HD"])
        }
        try database.writer.write { db in
            try db.execute(sql: "UPDATE channel SET name = 'Sky Sports F1' WHERE streamID = 2")
        }
        try database.reader.read { db in
            let names = try String.fetchAll(db, sql: "SELECT name FROM channelFTS WHERE channelFTS MATCH 'f1'")
            #expect(names == ["Sky Sports F1"])
        }
    }

    @Test func deletingASeriesRemovesItsSeasonsAndEpisodes() throws {
        let database = try AppDatabase.inMemory()
        let provider = TestData.provider()
        try database.writer.write { db in
            try provider.insert(db)
            try TestData.seedEverything(for: provider.id, in: db)
            _ = try Series.deleteAll(db)
        }
        let counts = try database.reader.read { db in (try Season.fetchCount(db), try Episode.fetchCount(db)) }
        #expect(counts == (0, 0))
    }
}
