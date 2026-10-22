import Foundation
import GRDB

/// Keeps the user's library pointing at the right items when a provider's IDs change.
///
/// Favorites, recents, watch progress, renames, hidden channels, custom groups and the like are
/// stored by the provider's own IDs (stream, series, episode and category IDs). Those IDs belong to
/// the provider's panel: a new login on the same panel keeps them, but a move to a different panel
/// (or a rebuilt one) numbers everything afresh, and may even reuse an old number for something
/// else. Each sync compares the old catalog with the new one and, for every ID the library uses:
///
/// - keeps it when the same item still has it;
/// - otherwise looks for the same item under a new ID (by guide ID, name and region, or for movies
///   by TMDB ID, name and year) and moves the library entries over;
/// - when most of the catalog was renumbered and the old ID now belongs to a different item, removes
///   the entries rather than leave a favorite pointing at the wrong channel. An item that simply
///   disappeared is left alone, in case it comes back.
enum CatalogRelinker {
    /// One catalog item, reduced to what identifies it across panels.
    struct Item: Sendable {
        var id: String
        var name: String
        var epgID: String? = nil
        /// Name of its category ("UK | Sports"), for the region and to break ties.
        var group: String? = nil
        var year: Int? = nil
        var tmdbID: String? = nil

        fileprivate var normalized: String { ChannelMatcher.normalizedName(name) }
        fileprivate var region: String? { RegionPrefix.detect(name) ?? group.flatMap { RegionPrefix.detect($0) } }
        fileprivate var plainGroup: String? { group.map { RegionPrefix.strip($0).lowercased() } }
        fileprivate var exact: String { name.trimmingCharacters(in: .whitespaces).lowercased() }
        fileprivate var guide: String? { epgID.flatMap { $0.isEmpty ? nil : $0.lowercased() } }
    }

    struct Plan: Sendable, Equatable {
        /// Old ID → new ID.
        var moves: [String: String] = [:]
        /// IDs that now belong to a different item, and nothing matched.
        var drops: Set<String> = []
        /// In a renumbered catalog, old IDs that now belong to a different item (cached details
        /// stored under them, such as a series' episodes, are stale).
        var reused: Set<String> = []
        var isEmpty: Bool { moves.isEmpty && drops.isEmpty }
    }

    /// Whether `old` and `new` are the same item.
    static func same(_ old: Item, _ new: Item) -> Bool {
        if let a = old.tmdbID, let b = new.tmdbID, !a.isEmpty, !b.isEmpty { return a == b }
        if let a = old.guide, a == new.guide { return true }
        guard old.normalized == new.normalized, !old.normalized.isEmpty else { return false }
        if let a = old.year, let b = new.year, a != b { return false }
        return true
    }

    /// What to do with the IDs in `referenced`, given the catalog before and after a sync.
    static func plan(old: [Item], new: [Item], referenced: Set<String>) -> Plan {
        var plan = Plan()
        guard !referenced.isEmpty, !old.isEmpty, !new.isEmpty else { return plan }
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Renumbered: most of the old catalog no longer sits under the same IDs.
        let stable = old.filter { item in newByID[item.id].map { same(item, $0) } ?? false }.count
        let renumbered = old.count >= 10 && stable * 2 < old.count
        let index = Index(new)

        if renumbered {
            plan.reused = Set(old.filter { item in newByID[item.id].map { !same(item, $0) } ?? false }.map(\.id))
        }
        for id in referenced {
            guard let item = oldByID[id] else { continue }
            if let current = newByID[id] {
                // Same panel: a rename keeps its ID, so only a renumbered catalog is checked.
                if same(item, current) || !renumbered { continue }
            }
            let match = index.match(item)
            if let match, match != id {
                plan.moves[id] = match
            } else if match == nil, newByID[id] != nil {
                plan.drops.insert(id)
            }
        }
        return plan
    }

    /// Lookups over the new catalog, from the most to the least certain.
    private struct Index {
        let items: [Item]
        let byTMDB: [String: [Item]]
        let byGuideAndName: [String: [Item]]
        let byExact: [String: [Item]]
        let byNameAndRegion: [String: [Item]]
        let byName: [String: [Item]]
        let byGuideAndRegion: [String: [Item]]

        init(_ items: [Item]) {
            self.items = items
            byTMDB = Dictionary(grouping: items.filter { !($0.tmdbID ?? "").isEmpty }) { $0.tmdbID! }
            byGuideAndName = Dictionary(grouping: items.filter { $0.guide != nil }) { "\($0.guide!)|\($0.normalized)" }
            byExact = Dictionary(grouping: items) { $0.exact }
            byNameAndRegion = Dictionary(grouping: items.filter { !$0.normalized.isEmpty }) { "\($0.normalized)|\($0.region ?? "")" }
            byName = Dictionary(grouping: items.filter { !$0.normalized.isEmpty }) { $0.normalized }
            byGuideAndRegion = Dictionary(grouping: items.filter { $0.guide != nil }) { "\($0.guide!)|\($0.region ?? "")" }
        }

        func match(_ item: Item) -> String? {
            var tiers: [[Item]?] = []
            if let tmdb = item.tmdbID, !tmdb.isEmpty { tiers.append(byTMDB[tmdb]) }
            if let guide = item.guide { tiers.append(byGuideAndName["\(guide)|\(item.normalized)"]) }
            tiers.append(byExact[item.exact])
            if !item.normalized.isEmpty {
                tiers.append(byNameAndRegion["\(item.normalized)|\(item.region ?? "")"])
                // A panel that leaves the region off ("Dune (1984)" for "EN - Dune") still matches;
                // two different regions never do.
                tiers.append(byName[item.normalized])
            }
            if let guide = item.guide { tiers.append(byGuideAndRegion["\(guide)|\(item.region ?? "")"]) }
            for case let candidates? in tiers {
                let fitting = candidates.filter { candidate in
                    if let a = item.year, let b = candidate.year, a != b { return false }
                    if let a = item.region, let b = candidate.region, a != b { return false }
                    return true
                }
                if let chosen = pick(item, from: fitting) { return chosen.id }
            }
            return nil
        }

        /// One candidate, or the one in the same group, or the first of identical duplicates
        /// (the same channel listed twice, like a backup feed). Otherwise nothing: better no link
        /// than the wrong one.
        private func pick(_ item: Item, from candidates: [Item]) -> Item? {
            guard let first = candidates.first else { return nil }
            if candidates.count == 1 { return first }
            let sameGroup = candidates.filter { $0.plainGroup != nil && $0.plainGroup == item.plainGroup }
            if sameGroup.count == 1 { return sameGroup[0] }
            let pool = sameGroup.isEmpty ? candidates : sameGroup
            let identical = pool.allSatisfy { $0.normalized == pool[0].normalized && $0.region == pool[0].region }
            return identical ? pool[0] : nil
        }
    }

    // MARK: Applying

    /// A column that stores one kind of provider ID.
    struct Target {
        var table: String
        var column: String
        /// Extra condition, such as "itemKind = 'channel'".
        var condition: String? = nil
        /// Whether the column holds integers (stream and series IDs) rather than text.
        var isInteger = false
    }

    static let channelTargets: [Target] = [
        Target(table: "favorite", column: "itemID", condition: "itemKind = 'channel'"),
        Target(table: "recentItem", column: "itemID", condition: "itemKind = 'channel'"),
        Target(table: "channelOverride", column: "streamID", isInteger: true),
        Target(table: "customGroupMember", column: "streamID", isInteger: true),
        Target(table: "playbackHistory", column: "streamID", isInteger: true),
        Target(table: "epgMappingOverride", column: "streamID", isInteger: true),
        Target(table: "channelLinkOverride", column: "streamID", isInteger: true),
    ]

    static func libraryTargets(_ kind: LibraryItemKind) -> [Target] {
        ["favorite", "recentItem", "watchProgress"].map {
            Target(table: $0, column: "itemID", condition: "itemKind = '\(kind.rawValue)'")
        }
    }

    static func categoryTargets(_ kind: ContentKind) -> [Target] {
        [Target(table: "categoryOverride", column: "categoryID", condition: "kind = '\(kind.rawValue)'")]
    }

    /// The IDs the library uses in `targets` for this provider.
    static func referenced(_ targets: [Target], providerID: ProviderID, in db: Database) throws -> Set<String> {
        var ids = Set<String>()
        for target in targets {
            ids.formUnion(try String.fetchAll(db, sql: """
                SELECT DISTINCT CAST(\(target.column) AS TEXT) FROM \(target.table)
                WHERE providerID = ? \(target.condition.map { "AND \($0)" } ?? "")
                """, arguments: [providerID.rawValue]))
        }
        return ids
    }

    /// Moves and removes library entries. Moves go through a temporary value first so that swaps
    /// (A → B while B → C) never collide; when an entry already exists under the new ID, the moved
    /// one replaces it.
    static func apply(_ plan: Plan, to targets: [Target], providerID: ProviderID, in db: Database) throws {
        guard !plan.isEmpty else { return }
        let provider = providerID.rawValue
        for target in targets {
            let scope = "providerID = ? \(target.condition.map { "AND \($0)" } ?? "")"
            for id in plan.drops {
                try db.execute(sql: "DELETE FROM \(target.table) WHERE \(scope) AND \(target.column) = ?",
                               arguments: [provider, value(id, target)])
            }
            for (old, new) in plan.moves {
                try db.execute(sql: "UPDATE OR REPLACE \(target.table) SET \(target.column) = ? WHERE \(scope) AND \(target.column) = ?",
                               arguments: ["~relink~" + new, provider, value(old, target)])
            }
            for new in Set(plan.moves.values) {
                try db.execute(sql: "UPDATE OR REPLACE \(target.table) SET \(target.column) = ? WHERE \(scope) AND \(target.column) = ?",
                               arguments: [value(new, target), provider, "~relink~" + new])
            }
        }
    }

    /// Logical channels of unmatched streams are named after the stream ("solo:provider:123"), so
    /// overrides that point at one follow its stream to the new ID.
    static func applyToLogicalIDs(_ plan: Plan, providerID: ProviderID, in db: Database) throws {
        guard !plan.moves.isEmpty || !plan.drops.isEmpty else { return }
        let prefix = "solo:\(providerID.rawValue):"
        for id in plan.drops {
            try db.execute(sql: "DELETE FROM logicalEPGOverride WHERE logicalChannelID = ?", arguments: [prefix + id])
            try db.execute(sql: "DELETE FROM channelLinkOverride WHERE targetLogicalChannelID = ?", arguments: [prefix + id])
        }
        for (old, new) in plan.moves {
            try db.execute(sql: "UPDATE OR REPLACE logicalEPGOverride SET logicalChannelID = ? WHERE logicalChannelID = ?",
                           arguments: ["~relink~" + prefix + new, prefix + old])
            try db.execute(sql: "UPDATE channelLinkOverride SET targetLogicalChannelID = ? WHERE targetLogicalChannelID = ?",
                           arguments: ["~relink~" + prefix + new, prefix + old])
        }
        for new in Set(plan.moves.values) {
            try db.execute(sql: "UPDATE OR REPLACE logicalEPGOverride SET logicalChannelID = ? WHERE logicalChannelID = ?",
                           arguments: [prefix + new, "~relink~" + prefix + new])
            try db.execute(sql: "UPDATE channelLinkOverride SET targetLogicalChannelID = ? WHERE targetLogicalChannelID = ?",
                           arguments: [prefix + new, "~relink~" + prefix + new])
        }
    }

    private static func value(_ id: String, _ target: Target) -> DatabaseValueConvertible {
        target.isInteger ? (Int(id) ?? 0) as DatabaseValueConvertible : id
    }
}
