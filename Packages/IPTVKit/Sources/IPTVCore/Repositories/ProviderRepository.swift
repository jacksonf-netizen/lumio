import Foundation
import GRDB

/// Reads and writes `provider` rows. Does not touch credentials; see `ProviderService`.
public struct ProviderRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// All providers in priority order (lowest `priority` first).
    public func all() throws -> [Provider] {
        try database.reader.read { db in try Self.ordered.fetchAll(db) }
    }

    public func provider(id: ProviderID) throws -> Provider? {
        try database.reader.read { db in try Provider.fetchOne(db, key: id) }
    }

    /// Emits the provider list now and after every change.
    public func observeAll() -> AsyncValueObservation<[Provider]> {
        ValueObservation
            .tracking { db in try Self.ordered.fetchAll(db) }
            .values(in: database.reader, scheduling: .async(onQueue: .main))
    }

    /// Inserts with `priority` set after all existing providers. `links` are its server addresses
    /// in order (just `serverURL` when empty); the first one is used.
    @discardableResult
    public func insert(_ provider: Provider, links: [URL] = []) throws -> Provider {
        try database.writer.write { db in
            var provider = provider
            let maxPriority = try Int.fetchOne(db, sql: "SELECT MAX(priority) FROM provider") ?? -1
            provider.priority = maxPriority + 1
            let links = links.isEmpty ? [provider.serverURL] : links
            provider.serverURL = links[0]
            try provider.insert(db)
            for (position, url) in links.enumerated() {
                try ServerLink(providerID: provider.id, position: position, url: url).insert(db)
            }
            return provider
        }
    }

    public func update(_ provider: Provider) throws {
        try database.writer.write { db in try provider.update(db) }
    }

    /// Writes only what the user edits (name, address, on/off, guide offset, user-agent).
    public func updateSettings(_ provider: Provider) throws {
        try database.writer.write { db in try provider.update(db, columns: Self.settingColumns) }
    }

    /// Writes only what refreshes learn (account status, limits, last refresh and error).
    ///
    /// The user's edits and refreshes each write their own columns, so a refresh that started
    /// before an edit and finishes after it can't put the old name or server address back.
    public func updateStatus(_ provider: Provider) throws {
        try database.writer.write { db in try provider.update(db, columns: Self.statusColumns) }
    }

    // The address in use (`serverURL`) is neither: `setLinks` and `ServerFailover` change it.
    static let settingColumns = ["name", "isEnabled", "epgTimeOffsetMinutes", "userAgentOverride"]
    static let statusColumns = ["accountStatus", "expiresAt", "maxConnections", "activeConnections",
                                "allowedOutputFormats", "lastRefreshAt", "lastError"]

    /// Deletes the provider and, through `ON DELETE CASCADE`, every row it owns.
    @discardableResult
    public func delete(id: ProviderID) throws -> Bool {
        try database.writer.write { db in try Provider.deleteOne(db, key: id) }
    }

    /// Rewrites priorities to match the given order. Ids not listed keep their relative order after
    /// the listed ones.
    public func reorder(_ orderedIDs: [ProviderID]) throws {
        try database.writer.write { db in
            let existing = try Self.ordered.fetchAll(db)
            let listed = orderedIDs.compactMap { id in existing.first { $0.id == id } }
            let rest = existing.filter { !orderedIDs.contains($0.id) }
            for (index, var provider) in (listed + rest).enumerated() where provider.priority != index {
                provider.priority = index
                try provider.update(db)
            }
        }
    }

    // MARK: Server links

    /// The provider's server addresses in the user's order. A provider saved before links existed
    /// (or written directly in tests) has its `serverURL` as its only link.
    public func links(for id: ProviderID) throws -> [ServerLink] {
        try database.reader.read { db in try Self.links(for: id, db) }
    }

    /// Every provider's links, for Settings.
    public func observeLinks() -> AsyncValueObservation<[ServerLink]> {
        ValueObservation
            .tracking { db in try ServerLink.order(Column("providerID"), Column("position")).fetchAll(db) }
            .values(in: database.reader, scheduling: .async(onQueue: .main))
    }

    /// Replaces the list (the user edited it). Links that stay keep what checks learnt about them.
    /// The address in use stays if it's still listed; otherwise the first link takes over.
    public func setLinks(_ urls: [URL], for id: ProviderID) throws {
        guard let first = urls.first else { return }
        try database.writer.write { db in
            guard var provider = try Provider.fetchOne(db, key: id) else { return }
            let old = try Self.links(for: id, db)
            try ServerLink.filter(Column("providerID") == id).deleteAll(db)
            for (position, url) in urls.enumerated() {
                var link = old.first { $0.url == url } ?? ServerLink(providerID: id, position: position, url: url)
                link.position = position
                try link.insert(db)
            }
            if !urls.contains(provider.serverURL) {
                provider.serverURL = first
                try provider.update(db, columns: ["serverURL"])
            }
        }
    }

    /// Writes what a check found out about one link.
    public func recordCheck(_ id: ProviderID, url: URL, at date: Date, failure: String?) throws {
        try database.writer.write { db in
            guard var link = try Self.links(for: id, db).first(where: { $0.url == url }) else { return }
            link.lastCheckedAt = date
            if let failure {
                link.downSince = link.downSince ?? date
                link.lastFailure = failure
            } else {
                link.downSince = nil
                link.lastFailure = nil
            }
            try link.save(db)
        }
    }

    /// Makes `url` the address in use. Ignored unless it's one of the provider's links.
    public func setActive(_ url: URL, for id: ProviderID) throws {
        try database.writer.write { db in
            guard var provider = try Provider.fetchOne(db, key: id),
                  try Self.links(for: id, db).contains(where: { $0.url == url }) else { return }
            provider.serverURL = url
            try provider.update(db, columns: ["serverURL"])
        }
    }

    private static func links(for id: ProviderID, _ db: Database) throws -> [ServerLink] {
        let links = try ServerLink.filter(Column("providerID") == id).order(Column("position")).fetchAll(db)
        if links.isEmpty, let provider = try Provider.fetchOne(db, key: id) {
            return [ServerLink(providerID: id, position: 0, url: provider.serverURL)]
        }
        return links
    }

    private static let ordered = Provider.order(Column("priority"), Column("name"))
}
