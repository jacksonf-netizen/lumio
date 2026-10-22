import GRDB

// Versioned schema migrations. Never edit a migration that has shipped; add a new one instead.
// The schema is documented in Docs/schema.md; keep the two in sync.

extension AppDatabase {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: migrateV1)
        migrator.registerMigration("v2-epg-import", migrate: migrateV2)
        migrator.registerMigration("v3-guide-index") { db in
            // The guide reads one EPG id from whichever provider has data for it, so it needs an
            // index that doesn't start with providerID.
            try db.create(index: "programme_on_epgID_start", on: "programme", columns: ["epgID", "start"])
        }
        migrator.registerMigration("v4-category-region") { db in
            // Region prefix of each category ("UK" for "UK | Sports"); hidden regions are a setting.
            // Filled here for existing rows, and recomputed by every catalog sync.
            try db.alter(table: "category") { t in t.add(column: "region", .text) }
            try db.create(index: "category_on_region", on: "category", columns: ["region"])
            let rows = try Row.fetchAll(db, sql: "SELECT rowid, name FROM category")
            for row in rows {
                guard let region = RegionPrefix.detect(row["name"]) else { continue }
                try db.execute(sql: "UPDATE category SET region = ? WHERE rowid = ?", arguments: [region, row["rowid"] as Int64])
            }
        }
        migrator.registerMigration("v5-category-region-prefix") { db in
            // The provider's spelling of the region ("NA"), kept next to the region it's merged
            // into ("US"), so Settings can show merges and the user can change them.
            try db.alter(table: "category") { t in t.add(column: "regionPrefix", .text) }
            for row in try Row.fetchAll(db, sql: "SELECT rowid, name FROM category") {
                let prefix = RegionPrefix.detectPrefix(row["name"])
                try db.execute(sql: "UPDATE category SET regionPrefix = ?, region = ? WHERE rowid = ?",
                               arguments: [prefix, prefix.map { RegionPrefix.key(forPrefix: $0) }, row["rowid"] as Int64])
            }
        }
        migrator.registerMigration("v6-region-readings") { db in
            // Better region rules: country names without a separator, unknown provider codes, and
            // codes read the way each provider uses them. Recomputed for existing categories.
            try RegionPrefix.recompute(in: db, keepHidden: true)
        }
        migrator.registerMigration("v7-category-shown") { db in
            // Lets one group stay visible when its region is switched off (Settings → Regions).
            try db.alter(table: "categoryOverride") { t in t.add(column: "isShown", .boolean).notNull().defaults(to: false) }
        }
        migrator.registerMigration("v8-episode-relink") { db in
            // Episodes the library refers to whose series got a new ID (the provider moved panels).
            // Matched to the new episode IDs by season and episode number when the series' episode
            // list is next fetched (see CatalogRelinker).
            try db.create(table: "episodeRelink") { t in
                t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
                t.column("episodeID", .text).notNull()
                t.column("seriesID", .integer).notNull()
                t.column("seasonNumber", .integer).notNull()
                t.column("episodeNumber", .integer).notNull()
                t.primaryKey(["providerID", "episodeID"])
            }
        }
        return migrator
    }

    private static func migrateV1(_ db: Database) throws {
        // MARK: Providers

        try db.create(table: "provider") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("kind", .text).notNull()
            t.column("serverURL", .text).notNull()
            t.column("priority", .integer).notNull().defaults(to: 0)
            t.column("isEnabled", .boolean).notNull().defaults(to: true)
            t.column("createdAt", .double).notNull()
            t.column("accountStatus", .text)
            t.column("expiresAt", .double)
            t.column("maxConnections", .integer)
            t.column("activeConnections", .integer)
            t.column("allowedOutputFormats", .text).notNull().defaults(to: "[]")
            t.column("lastRefreshAt", .double)
            t.column("lastError", .text)
            t.column("epgTimeOffsetMinutes", .integer).notNull().defaults(to: 0)
            t.column("userAgentOverride", .text)
        }

        // MARK: Catalog

        try db.create(table: "category") { t in
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("categoryID", .text).notNull()
            t.column("name", .text).notNull()
            t.column("parentID", .text)
            t.column("sortIndex", .integer).notNull().defaults(to: 0)
            t.primaryKey(["providerID", "kind", "categoryID"])
        }

        try db.create(table: "channel") { t in
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("streamID", .integer).notNull()
            t.column("number", .integer)
            t.column("name", .text).notNull()
            t.column("logoURL", .text)
            t.column("epgChannelID", .text)
            t.column("categoryID", .text)
            t.column("tvArchive", .boolean).notNull().defaults(to: false)
            t.column("tvArchiveDuration", .integer).notNull().defaults(to: 0)
            t.column("addedAt", .double)
            t.column("isAdult", .boolean).notNull().defaults(to: false)
            t.column("directSource", .text)
            t.column("sortIndex", .integer).notNull().defaults(to: 0)
            t.primaryKey(["providerID", "streamID"])
        }
        try db.create(index: "channel_on_category", on: "channel", columns: ["providerID", "categoryID", "sortIndex"])
        try db.create(index: "channel_on_epgChannelID", on: "channel", columns: ["epgChannelID"])

        // Logical channels are derived data (rebuilt by ChannelMatcher). Overrides that must survive a
        // rebuild are keyed by the stable logical id and deliberately have no foreign key to this table.
        try db.create(table: "logicalChannel") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("logoURL", .text)
        }

        try db.create(table: "logicalChannelMember") { t in
            t.column("logicalChannelID", .text).notNull()
                .references("logicalChannel", onDelete: .cascade)
            t.column("providerID", .text).notNull()
            t.column("streamID", .integer).notNull()
            t.primaryKey(["providerID", "streamID"])
            t.foreignKey(["providerID", "streamID"], references: "channel", onDelete: .cascade)
        }
        try db.create(index: "logicalChannelMember_on_logical", on: "logicalChannelMember", columns: ["logicalChannelID"])

        // No foreign key to `channel`: overrides survive the channel briefly disappearing from a sync.
        try db.create(table: "channelLinkOverride") { t in
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("streamID", .integer).notNull()
            t.column("action", .text).notNull()
            t.column("targetLogicalChannelID", .text)
            t.primaryKey(["providerID", "streamID"])
        }

        try db.create(table: "movie") { t in
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("streamID", .integer).notNull()
            t.column("name", .text).notNull()
            t.column("categoryID", .text)
            t.column("posterURL", .text)
            t.column("rating", .double)
            t.column("year", .integer)
            t.column("plot", .text)
            t.column("tmdbID", .text)
            t.column("containerExtension", .text)
            t.column("durationSeconds", .integer)
            t.column("addedAt", .double)
            t.column("sortIndex", .integer).notNull().defaults(to: 0)
            t.primaryKey(["providerID", "streamID"])
        }
        try db.create(index: "movie_on_category", on: "movie", columns: ["providerID", "categoryID", "sortIndex"])
        try db.create(index: "movie_on_addedAt", on: "movie", columns: ["addedAt"])

        try db.create(table: "series") { t in
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("seriesID", .integer).notNull()
            t.column("name", .text).notNull()
            t.column("categoryID", .text)
            t.column("coverURL", .text)
            t.column("plot", .text)
            t.column("rating", .double)
            t.column("releaseDate", .text)
            t.column("lastModified", .double)
            t.column("sortIndex", .integer).notNull().defaults(to: 0)
            t.primaryKey(["providerID", "seriesID"])
        }
        try db.create(index: "series_on_category", on: "series", columns: ["providerID", "categoryID", "sortIndex"])

        try db.create(table: "season") { t in
            t.column("providerID", .text).notNull()
            t.column("seriesID", .integer).notNull()
            t.column("seasonNumber", .integer).notNull()
            t.column("name", .text)
            t.column("coverURL", .text)
            t.column("airDate", .text)
            t.primaryKey(["providerID", "seriesID", "seasonNumber"])
            t.foreignKey(["providerID", "seriesID"], references: "series", onDelete: .cascade)
        }

        try db.create(table: "episode") { t in
            t.column("providerID", .text).notNull()
            t.column("episodeID", .text).notNull()
            t.column("seriesID", .integer).notNull()
            t.column("seasonNumber", .integer).notNull()
            t.column("episodeNumber", .integer).notNull()
            t.column("title", .text).notNull()
            t.column("containerExtension", .text)
            t.column("durationSeconds", .integer)
            t.column("plot", .text)
            t.column("imageURL", .text)
            t.column("airDate", .text)
            t.primaryKey(["providerID", "episodeID"])
            t.foreignKey(["providerID", "seriesID"], references: "series", onDelete: .cascade)
        }
        try db.create(index: "episode_on_series", on: "episode",
                      columns: ["providerID", "seriesID", "seasonNumber", "episodeNumber"])

        // MARK: EPG

        try db.create(table: "epgChannel") { t in
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("epgID", .text).notNull()
            t.column("displayName", .text)
            t.column("iconURL", .text)
            t.primaryKey(["providerID", "epgID"])
        }

        try db.create(table: "programme") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("epgID", .text).notNull()
            t.column("start", .double).notNull()
            t.column("stop", .double).notNull()
            t.column("title", .text).notNull()
            t.column("subtitle", .text)
            t.column("summary", .text)
            t.column("category", .text)
            t.column("episodeNumber", .text)
            t.column("iconURL", .text)
        }
        // Serves the guide query (channel + time window), upserts, and cascade deletes.
        try db.create(index: "programme_on_channel_start", on: "programme",
                      columns: ["providerID", "epgID", "start"], options: .unique)
        // Serves pruning of old programmes.
        try db.create(index: "programme_on_stop", on: "programme", columns: ["stop"])

        try db.create(table: "epgMappingOverride") { t in
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("streamID", .integer).notNull()
            t.column("epgProviderID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("epgID", .text).notNull()
            t.primaryKey(["providerID", "streamID"])
        }

        try db.create(table: "logicalEPGOverride") { t in
            t.primaryKey("logicalChannelID", .text)
            t.column("epgProviderID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("epgID", .text).notNull()
        }

        // MARK: Library and customisation

        try db.create(table: "favorite") { t in
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("itemKind", .text).notNull()
            t.column("itemID", .text).notNull()
            t.column("addedAt", .double).notNull()
            t.column("sortIndex", .integer).notNull().defaults(to: 0)
            t.primaryKey(["providerID", "itemKind", "itemID"])
        }

        try db.create(table: "watchProgress") { t in
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("itemKind", .text).notNull()
            t.column("itemID", .text).notNull()
            t.column("positionSeconds", .double).notNull()
            t.column("durationSeconds", .double)
            t.column("isWatched", .boolean).notNull().defaults(to: false)
            t.column("updatedAt", .double).notNull()
            t.primaryKey(["providerID", "itemKind", "itemID"])
        }
        try db.create(index: "watchProgress_on_updatedAt", on: "watchProgress", columns: ["updatedAt"])

        try db.create(table: "recentItem") { t in
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("itemKind", .text).notNull()
            t.column("itemID", .text).notNull()
            t.column("lastPlayedAt", .double).notNull()
            t.primaryKey(["providerID", "itemKind", "itemID"])
        }
        try db.create(index: "recentItem_on_lastPlayedAt", on: "recentItem", columns: ["lastPlayedAt"])

        try db.create(table: "channelOverride") { t in
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("streamID", .integer).notNull()
            t.column("isHidden", .boolean).notNull().defaults(to: false)
            t.column("customName", .text)
            t.column("sortIndex", .integer)
            t.column("engine", .text)
            t.column("preferredFormat", .text)
            t.primaryKey(["providerID", "streamID"])
        }

        try db.create(table: "categoryOverride") { t in
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("kind", .text).notNull()
            t.column("categoryID", .text).notNull()
            t.column("isHidden", .boolean).notNull().defaults(to: false)
            t.column("customName", .text)
            t.column("sortIndex", .integer)
            t.primaryKey(["providerID", "kind", "categoryID"])
        }

        try db.create(table: "customGroup") { t in
            t.primaryKey("id", .text)
            t.column("name", .text).notNull()
            t.column("sortIndex", .integer).notNull().defaults(to: 0)
        }

        try db.create(table: "customGroupMember") { t in
            t.column("groupID", .text).notNull().references("customGroup", onDelete: .cascade)
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("streamID", .integer).notNull()
            t.column("sortIndex", .integer).notNull().defaults(to: 0)
            t.primaryKey(["groupID", "providerID", "streamID"])
        }

        try db.create(table: "playbackHistory") { t in
            t.column("providerID", .text).notNull().references("provider", onDelete: .cascade)
            t.column("streamID", .integer).notNull()
            t.column("successCount", .integer).notNull().defaults(to: 0)
            t.column("failureCount", .integer).notNull().defaults(to: 0)
            t.column("reliabilityScore", .double).notNull().defaults(to: 0.5)
            t.column("lastWorkingFormat", .text)
            t.column("lastWorkingEngine", .text)
            t.column("lastSuccessAt", .double)
            t.column("lastFailureAt", .double)
            t.column("lastError", .text)
            t.primaryKey(["providerID", "streamID"])
        }

        try db.create(table: "setting") { t in
            t.column("scopeKey", .text).notNull()
            // Null for global settings; set for provider/channel scope so they cascade.
            t.column("providerID", .text).references("provider", onDelete: .cascade)
            t.column("key", .text).notNull()
            t.column("value", .text).notNull()
            t.primaryKey(["scopeKey", "key"])
        }

        // MARK: Full-text search (FTS5, kept in sync with the content tables by triggers)

        try db.create(virtualTable: "channelFTS", using: FTS5()) { t in
            t.synchronize(withTable: "channel")
            t.tokenizer = .unicode61(diacritics: .remove)
            t.column("name")
        }
        try db.create(virtualTable: "programmeFTS", using: FTS5()) { t in
            t.synchronize(withTable: "programme")
            t.tokenizer = .unicode61(diacritics: .remove)
            t.column("title")
            t.column("subtitle")
        }
        try db.create(virtualTable: "movieFTS", using: FTS5()) { t in
            t.synchronize(withTable: "movie")
            t.tokenizer = .unicode61(diacritics: .remove)
            t.column("name")
        }
        try db.create(virtualTable: "seriesFTS", using: FTS5()) { t in
            t.synchronize(withTable: "series")
            t.tokenizer = .unicode61(diacritics: .remove)
            t.column("name")
        }
    }

    /// EPG import bookkeeping:
    /// - `programme.importedAt` lets an import delete rows the provider no longer lists.
    /// - Programme FTS gets hand-written triggers that only reindex when title/subtitle actually
    ///   change, so re-importing an unchanged guide doesn't rewrite the whole search index.
    private static func migrateV2(_ db: Database) throws {
        try db.dropFTS5SynchronizationTriggers(forTable: "programmeFTS")
        try db.drop(table: "programmeFTS")

        try db.alter(table: "programme") { t in
            t.add(column: "importedAt", .double)
        }
        try db.create(index: "programme_on_provider_importedAt", on: "programme", columns: ["providerID", "importedAt"])

        try db.execute(sql: """
            CREATE VIRTUAL TABLE programmeFTS USING fts5(
                title, subtitle,
                content='programme', content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER programmeFTS_ai AFTER INSERT ON programme BEGIN
                INSERT INTO programmeFTS(rowid, title, subtitle) VALUES (new.id, new.title, new.subtitle);
            END;
            CREATE TRIGGER programmeFTS_ad AFTER DELETE ON programme BEGIN
                INSERT INTO programmeFTS(programmeFTS, rowid, title, subtitle)
                VALUES ('delete', old.id, old.title, old.subtitle);
            END;
            CREATE TRIGGER programmeFTS_au AFTER UPDATE OF title, subtitle ON programme
            WHEN old.title IS NOT new.title OR old.subtitle IS NOT new.subtitle BEGIN
                INSERT INTO programmeFTS(programmeFTS, rowid, title, subtitle)
                VALUES ('delete', old.id, old.title, old.subtitle);
                INSERT INTO programmeFTS(rowid, title, subtitle) VALUES (new.id, new.title, new.subtitle);
            END;
            INSERT INTO programmeFTS(programmeFTS) VALUES ('rebuild');
            """)
    }
}
