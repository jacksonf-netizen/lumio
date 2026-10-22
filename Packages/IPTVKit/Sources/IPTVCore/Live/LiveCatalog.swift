import Foundation
import GRDB

/// Which providers a view shows: all of them merged (default) or just one.
public enum ProviderFilter: Hashable, Sendable {
    case all
    case only(ProviderID)
}

/// Where to find guide data for a channel: an EPG id, and the providers whose guides to try, in order.
public struct EPGRef: Hashable, Sendable {
    public var epgID: String
    public var providers: [ProviderID]

    public init(epgID: String, providers: [ProviderID]) {
        self.epgID = EPGKey.normalize(epgID)
        self.providers = providers
    }
}

/// A group in the channel browser.
public struct ChannelGroup: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case favorites, recents, all, custom, category }

    public var id: String
    public var name: String
    public var kind: Kind
    public var isHidden: Bool
    /// Underlying provider categories (empty for synthetic groups).
    public var categories: [CategoryKey]

    public struct CategoryKey: Hashable, Sendable {
        public var providerID: ProviderID
        public var categoryID: String

        public init(providerID: ProviderID, categoryID: String) {
            self.providerID = providerID
            self.categoryID = categoryID
        }
    }

    public init(id: String, name: String, kind: Kind, isHidden: Bool = false, categories: [CategoryKey] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isHidden = isHidden
        self.categories = categories
    }
}

/// One row in a channel list: a logical channel, shown via its preferred source.
public struct ChannelListItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var logoURL: URL?
    public var number: Int?
    public var providerID: ProviderID
    public var streamID: Int
    /// Providers that carry this channel, in priority order.
    public var sourceProviders: [ProviderID]
    public var epg: EPGRef?
    public var isFavorite: Bool
    public var isHidden: Bool
    public var hasCatchup: Bool
}

/// Read model for the Live TV browser and the guide: merged groups and channels across providers,
/// with the user's hidden / renamed / reordered customisations applied.
public struct LiveCatalog: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: Groups

    public func groups(filter: ProviderFilter = .all, includeHidden: Bool = false) async throws -> [ChannelGroup] {
        try await database.reader.read { db in try Self.groups(db, filter: filter, includeHidden: includeHidden) }
    }

    static func groups(_ db: Database, filter: ProviderFilter, includeHidden: Bool) throws -> [ChannelGroup] {
        var result: [ChannelGroup] = [
            ChannelGroup(id: "favorites", name: "Favorites", kind: .favorites, isHidden: false, categories: []),
            ChannelGroup(id: "recents", name: "Recently Watched", kind: .recents, isHidden: false, categories: []),
            ChannelGroup(id: "all", name: "All Channels", kind: .all, isHidden: false, categories: []),
        ]
        for group in try CustomGroup.order(Column("sortIndex"), Column("name")).fetchAll(db) {
            result.append(ChannelGroup(id: "custom:\(group.id)", name: group.name, kind: .custom, isHidden: false, categories: []))
        }

        let rows = try Row.fetchAll(db, sql: """
            SELECT c.providerID, c.categoryID, c.name, c.sortIndex, p.priority,
                   o.isHidden AS hidden, o.customName AS customName, o.sortIndex AS userSort
            FROM category c
            JOIN provider p ON p.id = c.providerID AND p.isEnabled
            LEFT JOIN categoryOverride o ON o.providerID = c.providerID AND o.kind = c.kind AND o.categoryID = c.categoryID
            WHERE c.kind = 'live' AND NOT \(RegionPrefix.hiddenSQL("c")) \(filter.sqlCondition(column: "c.providerID"))
            ORDER BY COALESCE(o.sortIndex, 1000000), p.priority, c.sortIndex
            """, arguments: filter.sqlArguments)

        // In the merged view, categories with the same (display) name from different providers are one group.
        var order: [String] = []
        var merged: [String: ChannelGroup] = [:]
        for row in rows {
            let providerID = ProviderID(row["providerID"])
            let categoryID: String = row["categoryID"]
            let name: String = row["customName"] ?? row["name"]
            let hidden = (row["hidden"] as Bool?) ?? false
            let key: String
            switch filter {
            case .all: key = "cat:" + name.lowercased().trimmingCharacters(in: .whitespaces)
            case .only: key = "cat:\(providerID.rawValue):\(categoryID)"
            }
            let category = ChannelGroup.CategoryKey(providerID: providerID, categoryID: categoryID)
            if var existing = merged[key] {
                existing.categories.append(category)
                existing.isHidden = existing.isHidden && hidden
                merged[key] = existing
            } else {
                merged[key] = ChannelGroup(id: key, name: name, kind: .category, isHidden: hidden, categories: [category])
                order.append(key)
            }
        }
        for key in order {
            guard let group = merged[key], includeHidden || !group.isHidden else { continue }
            result.append(group)
        }
        return result
    }

    // MARK: Channels

    public func channels(in group: ChannelGroup, filter: ProviderFilter = .all,
                         includeHidden: Bool = false) async throws -> [ChannelListItem] {
        try await database.reader.read { db in
            try Self.channels(db, group: group, filter: filter, includeHidden: includeHidden)
        }
    }

    /// Every visible channel (for the guide's "All channels" and global zapping).
    public func allChannels(filter: ProviderFilter = .all) async throws -> [ChannelListItem] {
        let all = ChannelGroup(id: "all", name: "All", kind: .all, isHidden: false, categories: [])
        return try await channels(in: all, filter: filter)
    }

    public func item(logicalID: String) async throws -> ChannelListItem? {
        try await database.reader.read { db in
            let context = try Context(db, filter: .all)
            let rows = try Self.channelRows(db, where: "m.logicalChannelID = ?", arguments: [logicalID], filter: .all)
            return Self.collapse(rows, context: context, includeHidden: true).first
        }
    }

    static func channels(_ db: Database, group: ChannelGroup, filter: ProviderFilter,
                         includeHidden: Bool) throws -> [ChannelListItem] {
        let context = try Context(db, filter: filter)
        var rows: [ChannelRow]
        switch group.kind {
        case .all:
            rows = try channelRows(db, where: "1", arguments: [], filter: filter)
            // Hidden categories hide their channels from "All" too; hidden regions always do.
            let regionHidden = try regionHiddenCategoryKeys(db)
            let hiddenCategories = includeHidden ? regionHidden : try hiddenCategoryKeys(db).union(regionHidden)
            if !hiddenCategories.isEmpty {
                rows.removeAll { hiddenCategories.contains("\($0.channel.providerID.rawValue)|\($0.channel.categoryID ?? "")") }
            }
        case .category:
            guard !group.categories.isEmpty else { return [] }
            let clauses = group.categories.map { _ in "(c.providerID = ? AND c.categoryID = ?)" }.joined(separator: " OR ")
            let args = group.categories.flatMap { [$0.providerID.rawValue, $0.categoryID] as [DatabaseValueConvertible] }
            rows = try channelRows(db, where: "(\(clauses))", arguments: StatementArguments(args), filter: filter)
        case .favorites:
            rows = try channelRows(db, where: """
                EXISTS (SELECT 1 FROM favorite f WHERE f.itemKind = 'channel' AND f.providerID = c.providerID
                        AND f.itemID = CAST(c.streamID AS TEXT))
                """, arguments: [], filter: filter)
            let favoriteOrder = try favoriteOrder(db)
            rows.sort { (favoriteOrder[$0.logicalID] ?? .max) < (favoriteOrder[$1.logicalID] ?? .max) }
            return collapse(rows, context: context, includeHidden: true, keepOrder: true)
        case .recents:
            rows = try channelRows(db, where: """
                EXISTS (SELECT 1 FROM recentItem r WHERE r.itemKind = 'channel' AND r.providerID = c.providerID
                        AND r.itemID = CAST(c.streamID AS TEXT))
                """, arguments: [], filter: filter)
            let recent = try recentOrder(db)
            rows.sort { (recent[$0.logicalID] ?? .max) < (recent[$1.logicalID] ?? .max) }
            return Array(collapse(rows, context: context, includeHidden: true, keepOrder: true).prefix(50))
        case .custom:
            let groupID = String(group.id.dropFirst("custom:".count))
            rows = try channelRows(db, where: """
                EXISTS (SELECT 1 FROM customGroupMember g WHERE g.groupID = ? AND g.providerID = c.providerID
                        AND g.streamID = c.streamID)
                """, arguments: [groupID], filter: filter)
            let memberOrder = try customOrder(db, groupID: groupID)
            rows.sort { (memberOrder[$0.logicalID] ?? .max) < (memberOrder[$1.logicalID] ?? .max) }
            return collapse(rows, context: context, includeHidden: true, keepOrder: true)
        }
        return collapse(rows, context: context, includeHidden: includeHidden)
    }

    // MARK: Building rows

    struct ChannelRow {
        var channel: Channel
        var logicalID: String
        var priority: Int
        var override: ChannelOverride?
    }

    /// Per-query lookups shared by all rows.
    struct Context {
        var favorites: Set<String>
        var mappings: [String: EPGMappingOverride]
        var logicalEPG: [String: LogicalEPGOverride]
        var logicalNames: [String: (String, URL?)]

        init(_ db: Database, filter: ProviderFilter) throws {
            favorites = Set(try Row.fetchAll(db, sql: "SELECT providerID, itemID FROM favorite WHERE itemKind = 'channel'")
                .map { "\($0["providerID"] as String)|\($0["itemID"] as String)" })
            mappings = Dictionary(try EPGMappingOverride.fetchAll(db).map { ("\($0.providerID.rawValue)|\($0.streamID)", $0) },
                                  uniquingKeysWith: { a, _ in a })
            logicalEPG = Dictionary(try LogicalEPGOverride.fetchAll(db).map { ($0.logicalChannelID, $0) }, uniquingKeysWith: { a, _ in a })
            logicalNames = Dictionary(try LogicalChannel.fetchAll(db).map { ($0.id, ($0.name, $0.logoURL)) }, uniquingKeysWith: { a, _ in a })
        }
    }

    static func channelRows(_ db: Database, where condition: String, arguments: StatementArguments,
                            filter: ProviderFilter) throws -> [ChannelRow] {
        let sql = """
            SELECT c.*, COALESCE(m.logicalChannelID, 'solo:' || c.providerID || ':' || c.streamID) AS lid,
                   p.priority AS ppriority,
                   o.isHidden AS oHidden, o.customName AS oName, o.sortIndex AS oSort, o.engine AS oEngine,
                   o.preferredFormat AS oFormat
            FROM channel c
            JOIN provider p ON p.id = c.providerID AND p.isEnabled
            LEFT JOIN logicalChannelMember m ON m.providerID = c.providerID AND m.streamID = c.streamID
            LEFT JOIN channelOverride o ON o.providerID = c.providerID AND o.streamID = c.streamID
            WHERE \(condition) \(filter.sqlCondition(column: "c.providerID"))
            ORDER BY COALESCE(o.sortIndex, 1000000000), p.priority, c.sortIndex
            """
        var allArguments = arguments
        allArguments += filter.sqlArguments
        return try Row.fetchAll(db, sql: sql, arguments: allArguments).map { row in
            let channel = try Channel(row: row)
            let hasOverride = row["oHidden"] as Bool? != nil
            let override = hasOverride ? ChannelOverride(
                providerID: channel.providerID, streamID: channel.streamID, isHidden: row["oHidden"] ?? false,
                customName: row["oName"], sortIndex: row["oSort"],
                engine: (row["oEngine"] as String?).flatMap(EngineKind.init(rawValue:)),
                preferredFormat: (row["oFormat"] as String?).flatMap(StreamFormat.init(rawValue:))) : nil
            return ChannelRow(channel: channel, logicalID: row["lid"], priority: row["ppriority"], override: override)
        }
    }

    /// One row per logical channel, keeping the first (best-ordered) source as the primary.
    static func collapse(_ rows: [ChannelRow], context: Context, includeHidden: Bool, keepOrder: Bool = true) -> [ChannelListItem] {
        var order: [String] = []
        var grouped: [String: [ChannelRow]] = [:]
        for row in rows {
            if grouped[row.logicalID] == nil { order.append(row.logicalID) }
            grouped[row.logicalID, default: []].append(row)
        }
        var items: [ChannelListItem] = []
        items.reserveCapacity(order.count)
        for id in order {
            guard let members = grouped[id], let primary = members.first else { continue }
            let hidden = primary.override?.isHidden ?? false
            if hidden && !includeHidden { continue }
            let channel = primary.channel
            let byPriority = members.sorted { $0.priority < $1.priority }
            let logical = context.logicalNames[id]
            let name = primary.override?.customName ?? logical?.0 ?? ChannelMatcher.displayName(channel.name)

            var epg: EPGRef?
            if let override = context.logicalEPG[id] {
                epg = EPGRef(epgID: override.epgID, providers: [override.epgProviderID])
            } else if let mapping = members.lazy.compactMap({ context.mappings["\($0.channel.providerID.rawValue)|\($0.channel.streamID)"] }).first {
                epg = EPGRef(epgID: mapping.epgID, providers: [mapping.epgProviderID])
            } else if let epgID = byPriority.lazy.compactMap(\.channel.epgChannelID).first {
                epg = EPGRef(epgID: epgID, providers: byPriority.map(\.channel.providerID))
            }

            items.append(ChannelListItem(
                id: id, name: name, logoURL: channel.logoURL ?? logical?.1 ?? members.lazy.compactMap(\.channel.logoURL).first,
                number: channel.number, providerID: channel.providerID, streamID: channel.streamID,
                sourceProviders: byPriority.map(\.channel.providerID).uniqued(),
                epg: epg,
                isFavorite: members.contains { context.favorites.contains("\($0.channel.providerID.rawValue)|\($0.channel.streamID)") },
                isHidden: hidden,
                hasCatchup: members.contains { $0.channel.tvArchive }))
        }
        return items
    }

    private static func hiddenCategoryKeys(_ db: Database) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "SELECT providerID, categoryID FROM categoryOverride WHERE kind = 'live' AND isHidden")
            .map { "\($0["providerID"] as String)|\($0["categoryID"] as String)" })
    }

    private static func regionHiddenCategoryKeys(_ db: Database) throws -> Set<String> {
        Set(try Row.fetchAll(db, sql: "SELECT providerID, categoryID FROM category c WHERE kind = 'live' AND \(RegionPrefix.hiddenSQL("c"))")
            .map { "\($0["providerID"] as String)|\($0["categoryID"] as String)" })
    }

    private static func favoriteOrder(_ db: Database) throws -> [String: Int] {
        try logicalOrder(db, sql: """
            SELECT COALESCE(m.logicalChannelID, 'solo:' || f.providerID || ':' || f.itemID) AS lid
            FROM favorite f LEFT JOIN logicalChannelMember m ON m.providerID = f.providerID AND CAST(m.streamID AS TEXT) = f.itemID
            WHERE f.itemKind = 'channel' ORDER BY f.sortIndex, f.addedAt
            """, arguments: [])
    }

    private static func recentOrder(_ db: Database) throws -> [String: Int] {
        try logicalOrder(db, sql: """
            SELECT COALESCE(m.logicalChannelID, 'solo:' || r.providerID || ':' || r.itemID) AS lid
            FROM recentItem r LEFT JOIN logicalChannelMember m ON m.providerID = r.providerID AND CAST(m.streamID AS TEXT) = r.itemID
            WHERE r.itemKind = 'channel' ORDER BY r.lastPlayedAt DESC
            """, arguments: [])
    }

    private static func customOrder(_ db: Database, groupID: String) throws -> [String: Int] {
        try logicalOrder(db, sql: """
            SELECT COALESCE(m.logicalChannelID, 'solo:' || g.providerID || ':' || g.streamID) AS lid
            FROM customGroupMember g LEFT JOIN logicalChannelMember m ON m.providerID = g.providerID AND m.streamID = g.streamID
            WHERE g.groupID = ? ORDER BY g.sortIndex
            """, arguments: [groupID])
    }

    private static func logicalOrder(_ db: Database, sql: String, arguments: StatementArguments) throws -> [String: Int] {
        var order: [String: Int] = [:]
        for (index, id) in try String.fetchAll(db, sql: sql, arguments: arguments).enumerated() where order[id] == nil {
            order[id] = index
        }
        return order
    }
}

extension ProviderFilter {
    func sqlCondition(column: String) -> String {
        switch self {
        case .all: ""
        case .only: "AND \(column) = ?"
        }
    }

    var sqlArguments: StatementArguments {
        switch self {
        case .all: []
        case .only(let id): [id.rawValue]
        }
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
