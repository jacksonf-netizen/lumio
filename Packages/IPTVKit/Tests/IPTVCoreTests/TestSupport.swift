import Foundation
import GRDB
@testable import IPTVCore

enum TestData {
    static let serverURL = URL(string: "http://example.test:8080")!

    static func provider(_ name: String = "Test", id: ProviderID = .make()) -> Provider {
        // Whole-second dates: REAL timestamps don't round-trip sub-microsecond precision exactly.
        Provider(id: id, name: name, serverURL: serverURL, createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// Inserts one row into every provider-owned table, so cascade tests cover the whole schema.
    static func seedEverything(for providerID: ProviderID, in db: Database) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let logicalID = "epg:bbc1.uk-\(providerID)"
        try Category(providerID: providerID, kind: .live, categoryID: "1", name: "News").insert(db)
        try Channel(providerID: providerID, streamID: 10, name: "BBC One HD", epgChannelID: "bbc1.uk",
                    categoryID: "1").insert(db)
        try LogicalChannel(id: logicalID, name: "BBC One").insert(db)
        try LogicalChannelMember(logicalChannelID: logicalID, providerID: providerID, streamID: 10).insert(db)
        try ChannelLinkOverride(providerID: providerID, streamID: 10, action: .unlink).insert(db)
        try EPGChannel(providerID: providerID, epgID: "bbc1.uk", displayName: "BBC One").insert(db)
        var programme = Programme(providerID: providerID, epgID: "bbc1.uk", start: now,
                                  stop: now.addingTimeInterval(1800), title: "News at Six")
        try programme.insert(db)
        try EPGMappingOverride(providerID: providerID, streamID: 10, epgProviderID: providerID, epgID: "bbc1.uk").insert(db)
        try LogicalEPGOverride(logicalChannelID: logicalID, epgProviderID: providerID,
                               epgID: "bbc1.uk").insert(db)
        try Movie(providerID: providerID, streamID: 20, name: "Some Film").insert(db)
        try Series(providerID: providerID, seriesID: 30, name: "Some Show").insert(db)
        try Season(providerID: providerID, seriesID: 30, seasonNumber: 1).insert(db)
        try Episode(providerID: providerID, episodeID: "301", seriesID: 30, seasonNumber: 1,
                    episodeNumber: 1, title: "Pilot").insert(db)
        try Favorite(providerID: providerID, itemKind: .channel, itemID: "10").insert(db)
        try WatchProgress(providerID: providerID, itemKind: .movie, itemID: "20", positionSeconds: 60).insert(db)
        try RecentItem(providerID: providerID, itemKind: .channel, itemID: "10").insert(db)
        try ChannelOverride(providerID: providerID, streamID: 10, isHidden: true).insert(db)
        try CategoryOverride(providerID: providerID, kind: .live, categoryID: "1", customName: "My News").insert(db)
        let group = CustomGroup(name: "Sport-\(providerID)")
        try group.insert(db)
        try CustomGroupMember(groupID: group.id, providerID: providerID, streamID: 10).insert(db)
        try PlaybackHistory(providerID: providerID, streamID: 10, successCount: 1).insert(db)
        try db.execute(sql: "INSERT INTO episodeRelink (providerID, episodeID, seriesID, seasonNumber, episodeNumber) VALUES (?, 'e1', 30, 1, 1)",
                       arguments: [providerID.rawValue])
        try SettingRecord(scope: .provider(providerID), key: "bufferPreset", value: "\"large\"").insert(db)
        try SettingRecord(scope: .channel(providerID, streamID: 10), key: "engine", value: "\"mpv\"").insert(db)
    }

    /// Every ordinary table in the schema that has the given column.
    static func tables(withColumn column: String, in db: Database) throws -> [String] {
        let tables = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
              AND sql NOT LIKE 'CREATE VIRTUAL TABLE%' AND name NOT LIKE '%FTS_%'
            """)
        return try tables.filter { table in
            try db.columns(in: table).contains { $0.name == column }
        }
    }
}
