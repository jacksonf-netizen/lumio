import Foundation
import GRDB

/// User customisation and history: favorites, recents, hide / rename / reorder, custom groups,
/// manual EPG matching and per-channel playback overrides. Every change is reported to the
/// SyncProvider.
public struct LibraryRepository: Sendable {
    let database: AppDatabase
    let sync: any SyncProvider
    private let clock: any AppClock

    public init(database: AppDatabase, sync: any SyncProvider = LocalOnlySyncProvider(), clock: any AppClock = SystemClock()) {
        self.database = database
        self.sync = sync
        self.clock = clock
    }

    // MARK: Favorites

    /// Toggles a logical channel's favorite state. Returns the new state.
    @discardableResult
    public func toggleFavorite(_ item: ChannelListItem) async throws -> Bool {
        let now = clock.now()
        let isFavorite = try await database.writer.write { db -> Bool in
            let members = try Self.members(of: item, db: db)
            let existing = try Favorite.filter(Column("itemKind") == LibraryItemKind.channel.rawValue)
                .fetchAll(db)
                .filter { fav in members.contains { $0.0 == fav.providerID && String($0.1) == fav.itemID } }
            if !existing.isEmpty {
                for favorite in existing { try favorite.delete(db) }
                return false
            }
            let next = (try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM favorite") ?? -1) + 1
            try Favorite(providerID: item.providerID, itemKind: .channel, itemID: String(item.streamID),
                         addedAt: now, sortIndex: next).upsert(db)
            return true
        }
        await sync.localDataDidChange(.favorites)
        return isFavorite
    }

    public func setFavorite(_ on: Bool, kind: LibraryItemKind, providerID: ProviderID, itemID: String) async throws {
        let now = clock.now()
        try await database.writer.write { db in
            if on {
                let next = (try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM favorite") ?? -1) + 1
                try Favorite(providerID: providerID, itemKind: kind, itemID: itemID, addedAt: now, sortIndex: next).upsert(db)
            } else {
                _ = try Favorite.deleteOne(db, key: ["providerID": providerID.rawValue, "itemKind": kind.rawValue, "itemID": itemID])
            }
        }
        await sync.localDataDidChange(.favorites)
    }

    public func isFavorite(kind: LibraryItemKind, providerID: ProviderID, itemID: String) async throws -> Bool {
        try await database.reader.read { db in
            try Favorite.exists(db, key: ["providerID": providerID.rawValue, "itemKind": kind.rawValue, "itemID": itemID])
        }
    }

    // MARK: Recents

    public func recordPlayed(providerID: ProviderID, kind: LibraryItemKind, itemID: String) async throws {
        let now = clock.now()
        try await database.writer.write { db in
            try RecentItem(providerID: providerID, itemKind: kind, itemID: itemID, lastPlayedAt: now).upsert(db)
            // Keep the table small.
            try db.execute(sql: """
                DELETE FROM recentItem WHERE itemKind = ? AND rowid NOT IN
                  (SELECT rowid FROM recentItem WHERE itemKind = ? ORDER BY lastPlayedAt DESC LIMIT 200)
                """, arguments: [kind.rawValue, kind.rawValue])
        }
    }

    /// Removes a channel from Recently Watched (every provider's source of it).
    public func removeRecent(_ item: ChannelListItem) async throws {
        try await database.writer.write { db in
            for (providerID, streamID) in try Self.members(of: item, db: db) {
                _ = try RecentItem.deleteOne(db, key: ["providerID": providerID.rawValue, "itemKind": LibraryItemKind.channel.rawValue,
                                                       "itemID": String(streamID)])
            }
        }
    }

    /// Removes a movie (`.movie`, stream id) or a series (`.series`, series id) from Recently
    /// Watched. For a series this removes every episode of it. Watch progress is kept, so the
    /// detail page can still resume.
    public func removeRecent(kind: LibraryItemKind, providerID: ProviderID, itemID: String) async throws {
        try await database.writer.write { db in
            if kind == .series {
                try db.execute(sql: """
                    DELETE FROM recentItem WHERE providerID = ? AND itemKind = 'episode' AND itemID IN
                      (SELECT episodeID FROM episode WHERE providerID = ? AND seriesID = ?)
                    """, arguments: [providerID.rawValue, providerID.rawValue, Int(itemID) ?? -1])
            }
            _ = try RecentItem.deleteOne(db, key: ["providerID": providerID.rawValue, "itemKind": kind.rawValue, "itemID": itemID])
        }
    }

    /// Empties Recently Watched for these kinds (e.g. `[.channel]`, or `[.series, .episode]`).
    public func clearRecents(_ kinds: [LibraryItemKind]) async throws {
        try await database.writer.write { db in
            for kind in kinds {
                try db.execute(sql: "DELETE FROM recentItem WHERE itemKind = ?", arguments: [kind.rawValue])
            }
        }
    }

    // MARK: Channel customisation

    public func setHidden(_ hidden: Bool, channel item: ChannelListItem) async throws {
        try await updateOverrides(for: item) { $0.isHidden = hidden }
        await sync.localDataDidChange(.channelLayout)
    }

    /// nil restores the provider's name.
    public func rename(_ item: ChannelListItem, to name: String?) async throws {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try await updateOverride(providerID: item.providerID, streamID: item.streamID) {
            $0.customName = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
        await sync.localDataDidChange(.channelLayout)
    }

    public func setEngine(_ engine: EngineKind?, format: StreamFormat?, for item: ChannelListItem) async throws {
        try await updateOverrides(for: item) {
            $0.engine = engine
            $0.preferredFormat = format
        }
        await sync.localDataDidChange(.settings)
    }

    /// Saves a user order for channels within a group.
    public func reorder(_ items: [ChannelListItem], in group: ChannelGroup) async throws {
        try await database.writer.write { db in
            switch group.kind {
            case .favorites:
                let favorites = try Favorite.filter(Column("itemKind") == LibraryItemKind.channel.rawValue).fetchAll(db)
                for (index, item) in items.enumerated() {
                    let members = try Self.members(of: item, db: db)
                    for var favorite in favorites where members.contains(where: { $0.0 == favorite.providerID && String($0.1) == favorite.itemID }) {
                        favorite.sortIndex = index
                        try favorite.update(db)
                    }
                }
            case .custom:
                let groupID = String(group.id.dropFirst("custom:".count))
                for (index, item) in items.enumerated() {
                    try db.execute(sql: "UPDATE customGroupMember SET sortIndex = ? WHERE groupID = ? AND providerID = ? AND streamID = ?",
                                   arguments: [index, groupID, item.providerID, item.streamID])
                }
            default:
                for (index, item) in items.enumerated() {
                    var override = try ChannelOverride.fetchOne(db, key: ["providerID": item.providerID.rawValue, "streamID": item.streamID])
                        ?? ChannelOverride(providerID: item.providerID, streamID: item.streamID)
                    override.sortIndex = index
                    try override.upsert(db)
                }
            }
        }
        await sync.localDataDidChange(.channelLayout)
    }

    public func overrides(for item: ChannelListItem) async throws -> ChannelOverride? {
        try await database.reader.read { db in
            try ChannelOverride.fetchOne(db, key: ["providerID": item.providerID.rawValue, "streamID": item.streamID])
        }
    }

    // MARK: Groups

    public func setHidden(_ hidden: Bool, group: ChannelGroup) async throws {
        try await updateCategoryOverrides(group) { $0.isHidden = hidden }
        await sync.localDataDidChange(.channelLayout)
    }

    public func rename(_ group: ChannelGroup, to name: String?) async throws {
        if group.kind == .custom {
            let id = String(group.id.dropFirst("custom:".count))
            try await database.writer.write { db in
                try db.execute(sql: "UPDATE customGroup SET name = ? WHERE id = ?", arguments: [name ?? group.name, id])
            }
        } else {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            try await updateCategoryOverrides(group) { $0.customName = (trimmed?.isEmpty ?? true) ? nil : trimmed }
        }
        await sync.localDataDidChange(.channelLayout)
    }

    public func reorderGroups(_ groups: [ChannelGroup]) async throws {
        try await database.writer.write { db in
            var customIndex = 0
            for (index, group) in groups.enumerated() {
                switch group.kind {
                case .category:
                    for key in group.categories {
                        var override = try CategoryOverride.fetchOne(db, key: [
                            "providerID": key.providerID.rawValue, "kind": ContentKind.live.rawValue, "categoryID": key.categoryID,
                        ]) ?? CategoryOverride(providerID: key.providerID, kind: .live, categoryID: key.categoryID)
                        override.sortIndex = index
                        try override.upsert(db)
                    }
                case .custom:
                    try db.execute(sql: "UPDATE customGroup SET sortIndex = ? WHERE id = ?",
                                   arguments: [customIndex, String(group.id.dropFirst("custom:".count))])
                    customIndex += 1
                default:
                    break
                }
            }
        }
        await sync.localDataDidChange(.channelLayout)
    }

    @discardableResult
    public func createGroup(named name: String) async throws -> CustomGroup {
        let group = try await database.writer.write { db -> CustomGroup in
            let next = (try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM customGroup") ?? -1) + 1
            let group = CustomGroup(name: name, sortIndex: next)
            try group.insert(db)
            return group
        }
        await sync.localDataDidChange(.channelLayout)
        return group
    }

    public func deleteGroup(_ group: ChannelGroup) async throws {
        guard group.kind == .custom else { return }
        try await database.writer.write { db in
            _ = try CustomGroup.deleteOne(db, key: String(group.id.dropFirst("custom:".count)))
        }
        await sync.localDataDidChange(.channelLayout)
    }

    public func customGroups() async throws -> [CustomGroup] {
        try await database.reader.read { db in try CustomGroup.order(Column("sortIndex")).fetchAll(db) }
    }

    public func add(_ item: ChannelListItem, toGroup groupID: String) async throws {
        try await database.writer.write { db in
            let next = (try Int.fetchOne(db, sql: "SELECT MAX(sortIndex) FROM customGroupMember WHERE groupID = ?", arguments: [groupID]) ?? -1) + 1
            try CustomGroupMember(groupID: groupID, providerID: item.providerID, streamID: item.streamID, sortIndex: next).upsert(db)
        }
        await sync.localDataDidChange(.channelLayout)
    }

    public func remove(_ item: ChannelListItem, fromGroup groupID: String) async throws {
        try await database.writer.write { db in
            let members = try Self.members(of: item, db: db)
            for (providerID, streamID) in members {
                _ = try CustomGroupMember.deleteOne(db, key: ["groupID": groupID, "providerID": providerID.rawValue, "streamID": streamID])
            }
        }
        await sync.localDataDidChange(.channelLayout)
    }

    // MARK: EPG matching

    /// Guide channels from every provider matching `query`, for manual EPG matching.
    public func searchGuideChannels(_ query: String, limit: Int = 100) async throws -> [EPGChannel] {
        let pattern = "%\(query.trimmingCharacters(in: .whitespaces))%"
        return try await database.reader.read { db in
            try EPGChannel.fetchAll(db, sql: """
                SELECT e.* FROM epgChannel e JOIN provider p ON p.id = e.providerID
                WHERE e.displayName LIKE ? OR e.epgID LIKE ?
                ORDER BY p.priority, e.displayName LIMIT ?
                """, arguments: [pattern, pattern, limit])
        }
    }

    /// Use `epgID` from `epgProviderID`'s guide for this channel. Pass nil to go back to automatic.
    public func setEPG(_ guide: EPGChannel?, for item: ChannelListItem) async throws {
        try await database.writer.write { db in
            if let guide {
                try LogicalEPGOverride(logicalChannelID: item.id, epgProviderID: guide.providerID, epgID: guide.epgID).upsert(db)
                try EPGMappingOverride(providerID: item.providerID, streamID: item.streamID,
                                       epgProviderID: guide.providerID, epgID: guide.epgID).upsert(db)
            } else {
                _ = try LogicalEPGOverride.deleteOne(db, key: item.id)
                _ = try EPGMappingOverride.deleteOne(db, key: ["providerID": item.providerID.rawValue, "streamID": item.streamID])
            }
        }
        await sync.localDataDidChange(.channelLayout)
    }

    // MARK: Helpers

    /// (providerID, streamID) of every source of the item's logical channel.
    static func members(of item: ChannelListItem, db: Database) throws -> [(ProviderID, Int)] {
        let rows = try Row.fetchAll(db, sql: "SELECT providerID, streamID FROM logicalChannelMember WHERE logicalChannelID = ?",
                                    arguments: [item.id])
        let members = rows.map { (ProviderID($0["providerID"] as String), $0["streamID"] as Int) }
        return members.isEmpty ? [(item.providerID, item.streamID)] : members
    }

    private func updateOverride(providerID: ProviderID, streamID: Int, _ change: @escaping @Sendable (inout ChannelOverride) -> Void) async throws {
        try await database.writer.write { db in
            var override = try ChannelOverride.fetchOne(db, key: ["providerID": providerID.rawValue, "streamID": streamID])
                ?? ChannelOverride(providerID: providerID, streamID: streamID)
            change(&override)
            try override.upsert(db)
        }
    }

    /// Applies to every source of the logical channel, so a later re-match can't undo it.
    private func updateOverrides(for item: ChannelListItem, _ change: @escaping @Sendable (inout ChannelOverride) -> Void) async throws {
        try await database.writer.write { db in
            for (providerID, streamID) in try Self.members(of: item, db: db) {
                var override = try ChannelOverride.fetchOne(db, key: ["providerID": providerID.rawValue, "streamID": streamID])
                    ?? ChannelOverride(providerID: providerID, streamID: streamID)
                change(&override)
                try override.upsert(db)
            }
        }
    }

    private func updateCategoryOverrides(_ group: ChannelGroup, _ change: @escaping @Sendable (inout CategoryOverride) -> Void) async throws {
        try await database.writer.write { db in
            for key in group.categories {
                var override = try CategoryOverride.fetchOne(db, key: [
                    "providerID": key.providerID.rawValue, "kind": ContentKind.live.rawValue, "categoryID": key.categoryID,
                ]) ?? CategoryOverride(providerID: key.providerID, kind: .live, categoryID: key.categoryID)
                change(&override)
                try override.upsert(db)
            }
        }
    }
}

// MARK: - Hidden categories (all kinds)

public struct HiddenCategory: Hashable, Sendable, Identifiable {
    public var id: String { "\(providerID.rawValue)|\(kind.rawValue)|\(categoryID)" }
    public var providerID: ProviderID
    public var providerName: String
    public var kind: ContentKind
    public var categoryID: String
    public var name: String
}

extension LibraryRepository {
    public func setCategoryHidden(_ hidden: Bool, providerID: ProviderID, kind: ContentKind, categoryID: String) async throws {
        try await database.writer.write { db in
            var override = try CategoryOverride.fetchOne(db, key: [
                "providerID": providerID.rawValue, "kind": kind.rawValue, "categoryID": categoryID,
            ]) ?? CategoryOverride(providerID: providerID, kind: kind, categoryID: categoryID)
            override.isHidden = hidden
            try override.upsert(db)
        }
        await sync.localDataDidChange(.channelLayout)
    }

    /// Every hidden category across providers and content kinds, for Settings.
    public func hiddenCategories() async throws -> [HiddenCategory] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT o.providerID, o.kind, o.categoryID, COALESCE(o.customName, c.name, o.categoryID) AS name, p.name AS providerName
                FROM categoryOverride o
                JOIN provider p ON p.id = o.providerID
                LEFT JOIN category c ON c.providerID = o.providerID AND c.kind = o.kind AND c.categoryID = o.categoryID
                WHERE o.isHidden
                ORDER BY o.kind, p.priority, name
                """).map { row in
                HiddenCategory(providerID: ProviderID(row["providerID"] as String), providerName: row["providerName"],
                               kind: ContentKind(rawValue: row["kind"]) ?? .live, categoryID: row["categoryID"], name: row["name"])
            }
        }
    }
}

// MARK: - Regions

/// A region found in live group names, for Settings → Regions. (Region switches only apply to
/// Live TV; movie and series categories are hidden one by one.)
public struct RegionSummary: Hashable, Sendable, Identifiable {
    public var id: String { code }
    /// "UK", "US", "EX-YU", …
    public var code: String
    /// "United Kingdom", or the code when there's no friendlier name.
    public var name: String
    public var liveGroups: Int
    /// How providers spell it ("US", "USA", "NA"), most used first.
    public var spellings: [String]
    /// Providers that have it, in priority order.
    public var providers: [String]
    /// A few group names without the prefix ("Sports", "News"), to make clear what's in it.
    public var examples: [String]
    /// The region's switch. Single groups inside it can still differ (see `shownCategories`).
    public var isHidden: Bool
    /// Groups in it (one per provider), and how many of them are actually shown.
    public var categoryCount = 0
    public var shownCategories = 0
    /// The bucket for groups without a recognisable region (`RegionPrefix.other`).
    public var isOther: Bool { code == RegionPrefix.other }
}

/// One category in Settings → Regions, with its own switch.
public struct RegionCategory: Hashable, Sendable, Identifiable {
    public var id: String { "\(providerID.rawValue)|\(kind.rawValue)|\(categoryID)" }
    public var providerID: ProviderID
    public var providerName: String
    public var kind: ContentKind
    public var categoryID: String
    /// As the provider names it ("UK | Sports"), or the user's rename.
    public var name: String
    public var region: String
    /// Whether it's shown, taking the region switch and the category's own switch into account.
    public var isShown: Bool
}

extension LibraryRepository {
    /// Every region in the enabled providers' live groups, by name, then "Other Groups" for the
    /// groups without a recognisable region, so every group is covered by a switch.
    public func regions() async throws -> [RegionSummary] {
        let hidden = Set(hiddenRegions())
        return try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT COALESCE(c.region, '\(RegionPrefix.other)') AS region, c.regionPrefix, c.name,
                       p.name AS providerName, \(Self.categoryShownSQL) AS shown
                FROM category c
                JOIN provider p ON p.id = c.providerID AND p.isEnabled
                LEFT JOIN categoryOverride o ON o.providerID = c.providerID AND o.kind = c.kind AND o.categoryID = c.categoryID
                WHERE c.kind = '\(ContentKind.live.rawValue)'
                ORDER BY p.priority, c.sortIndex
                """)
            var byCode: [String: RegionSummary] = [:]
            var liveNames: [String: Set<String>] = [:]
            var spellingCounts: [String: [String: Int]] = [:]
            for row in rows {
                let code: String = row["region"]
                let name: String = row["name"]
                let isOther = code == RegionPrefix.other
                var summary = byCode[code] ?? RegionSummary(code: code, name: isOther ? "Other Groups" : RegionPrefix.displayName(code),
                                                            liveGroups: 0, spellings: [],
                                                            providers: [], examples: [], isHidden: hidden.contains(code))
                summary.categoryCount += 1
                if row["shown"] as Bool { summary.shownCategories += 1 }
                // Groups with the same name on several providers are one group in the app.
                if liveNames[code, default: []].insert(name.lowercased()).inserted { summary.liveGroups += 1 }
                if let spelling: String = row["regionPrefix"] { spellingCounts[code, default: [:]][spelling, default: 0] += 1 }
                let provider: String = row["providerName"]
                if !summary.providers.contains(provider) { summary.providers.append(provider) }
                let example = isOther ? name : RegionPrefix.strip(name)
                if summary.examples.count < 4, !summary.examples.contains(example) { summary.examples.append(example) }
                byCode[code] = summary
            }
            for (code, counts) in spellingCounts {
                byCode[code]?.spellings = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
            }
            return byCode.values.sorted {
                $0.isOther != $1.isOther ? $1.isOther : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    /// SQL for whether category `c` (with its override joined as `o`) is shown: not hidden by the
    /// user, and either its region is on or the user switched this one back on.
    static let categoryShownSQL = "(COALESCE(o.isHidden, 0) = 0 AND NOT \(RegionPrefix.hiddenSQL("c")))"

    /// Every live group of the enabled providers, grouped by region code (`RegionPrefix.other` for
    /// those without one), in provider order.
    public func regionCategories() async throws -> [String: [RegionCategory]] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.providerID, p.name AS providerName, c.kind, c.categoryID, COALESCE(o.customName, c.name) AS name,
                       COALESCE(c.region, '\(RegionPrefix.other)') AS region, \(Self.categoryShownSQL) AS shown
                FROM category c
                JOIN provider p ON p.id = c.providerID AND p.isEnabled
                LEFT JOIN categoryOverride o ON o.providerID = c.providerID AND o.kind = c.kind AND o.categoryID = c.categoryID
                WHERE c.kind = '\(ContentKind.live.rawValue)'
                ORDER BY p.priority, c.sortIndex
                """)
            var result: [String: [RegionCategory]] = [:]
            for row in rows {
                guard let kind = ContentKind(rawValue: row["kind"]) else { continue }
                let category = RegionCategory(providerID: ProviderID(row["providerID"] as String), providerName: row["providerName"],
                                              kind: kind, categoryID: row["categoryID"], name: row["name"],
                                              region: row["region"], isShown: row["shown"])
                result[category.region, default: []].append(category)
            }
            return result
        }
    }

    /// Shows or hides one category, whatever its region switch says (for when a group is filed
    /// under the wrong region, or isn't recognised at all).
    public func setCategory(_ category: RegionCategory, shown: Bool) async throws {
        let regionHidden = hiddenRegions().contains(category.region)
        try await database.writer.write { db in
            var override = try CategoryOverride.fetchOne(db, key: [
                "providerID": category.providerID.rawValue, "kind": category.kind.rawValue, "categoryID": category.categoryID,
            ]) ?? CategoryOverride(providerID: category.providerID, kind: category.kind, categoryID: category.categoryID)
            // Only record what differs from the region switch.
            override.isShown = shown && regionHidden
            override.isHidden = !shown && !regionHidden
            try override.upsert(db)
        }
        await sync.localDataDidChange(.channelLayout)
    }

    /// Region codes currently hidden.
    public func hiddenRegions() -> [String] {
        (try? SettingsRepository(database: database).value([String].self, for: .hiddenRegions)) ?? []
    }

    /// Shows or hides every category in this region, including any switched on or off one by one.
    public func setRegion(_ code: String, hidden: Bool) async throws {
        var codes = Set(hiddenRegions())
        if hidden { codes.insert(code) } else { codes.remove(code) }
        try await setHiddenRegions(codes, resettingCategoriesIn: [code])
    }

    /// Replaces the hidden set (e.g. "Show All"). Categories in `resettingCategoriesIn` lose their
    /// own switches and follow their region again, like a parent checkbox.
    public func setHiddenRegions(_ codes: Set<String>, resettingCategoriesIn reset: Set<String> = []) async throws {
        try SettingsRepository(database: database).set(codes.isEmpty ? nil : codes.sorted(), for: .hiddenRegions)
        if !reset.isEmpty {
            let list = Array(reset)
            try await database.writer.write { db in
                try db.execute(sql: """
                    UPDATE categoryOverride SET isHidden = 0, isShown = 0
                    WHERE kind = '\(ContentKind.live.rawValue)' AND (isHidden OR isShown) AND EXISTS (
                        SELECT 1 FROM category c WHERE c.providerID = categoryOverride.providerID AND c.kind = categoryOverride.kind
                        AND c.categoryID = categoryOverride.categoryID
                        AND COALESCE(c.region, '\(RegionPrefix.other)') IN (\(databaseQuestionMarks(count: list.count))))
                    """, arguments: StatementArguments(list))
            }
            await sync.localDataDidChange(.channelLayout)
        }
        await sync.localDataDidChange(.settings)
    }

    /// The user's merges: provider spelling → region.
    public func regionAliases() -> [String: String] {
        (try? SettingsRepository(database: database).value([String: String].self, for: .regionAliases)) ?? [:]
    }

    /// Treats `source` as part of `target` from now on, for every spelling of it (and on future
    /// syncs). The merged region keeps `target`'s shown/hidden state.
    public func mergeRegion(_ source: String, into target: String) async throws {
        guard source != target, source != RegionPrefix.other, target != RegionPrefix.other else { return }
        try await updateAliases { aliases, db in
            let spellings = try String.fetchAll(db, sql: "SELECT DISTINCT regionPrefix FROM category WHERE region = ? AND regionPrefix IS NOT NULL",
                                                arguments: [source])
            for spelling in spellings { aliases[spelling] = target }
            for (spelling, region) in aliases where region == source { aliases[spelling] = target }
            // The region itself, so new spellings of it follow the merge.
            aliases[source] = target
        }
        var hidden = Set(hiddenRegions())
        if hidden.remove(source) != nil { try await setHiddenRegions(hidden) }
    }

    /// Splits one spelling ("NA") back out into a region of its own.
    /// It starts with the same shown/hidden state as the region it leaves.
    public func separateSpelling(_ spelling: String) async throws {
        let previous = try await database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT region FROM category WHERE regionPrefix = ? GROUP BY region ORDER BY COUNT(*) DESC",
                                arguments: [spelling])
        }
        try await updateAliases { aliases, _ in aliases[spelling] = spelling }
        var hidden = Set(hiddenRegions())
        if let previous, hidden.contains(previous), hidden.insert(spelling).inserted { try await setHiddenRegions(hidden) }
    }

    /// Forgets every merge and split, going back to the built-in conventions.
    public func resetRegionMerges() async throws {
        try await updateAliases { aliases, _ in aliases.removeAll() }
    }

    private func updateAliases(_ change: @escaping @Sendable (inout [String: String], Database) throws -> Void) async throws {
        try await database.writer.write { db in
            var aliases = try RegionPrefix.userAliases(db)
            try change(&aliases, db)
            // Drop merges that only restate the built-in table. A split ("IS" → "IS") is kept even
            // then, since it also overrides how a provider's own names read the code.
            aliases = aliases.filter { $0.key == $0.value || RegionPrefix.key(forPrefix: $0.key) != $0.value }
            if aliases.isEmpty {
                _ = try SettingRecord.deleteOne(db, key: ["scopeKey": SettingScope.global.key, "key": SettingKey.regionAliases.rawValue])
            } else {
                let json = String(decoding: try JSONEncoder.settings.encode(aliases), as: UTF8.self)
                try SettingRecord(scope: .global, key: SettingKey.regionAliases.rawValue, value: json).upsert(db)
            }
            try RegionPrefix.recompute(in: db, aliases: aliases)
        }
        await sync.localDataDidChange(.settings)
    }
}
