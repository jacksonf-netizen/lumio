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

    /// Inserts with `priority` set after all existing providers.
    @discardableResult
    public func insert(_ provider: Provider) throws -> Provider {
        try database.writer.write { db in
            var provider = provider
            let maxPriority = try Int.fetchOne(db, sql: "SELECT MAX(priority) FROM provider") ?? -1
            provider.priority = maxPriority + 1
            try provider.insert(db)
            return provider
        }
    }

    public func update(_ provider: Provider) throws {
        try database.writer.write { db in try provider.update(db) }
    }

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

    private static let ordered = Provider.order(Column("priority"), Column("name"))
}
