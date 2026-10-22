import Foundation
import GRDB

/// Rebuilds the derived `logicalChannel` / `logicalChannelMember` tables from the channels of all
/// enabled providers. Cheap enough to run after every catalog sync or override change.
public struct LogicalChannelStore: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    @discardableResult
    public func rebuild() throws -> ChannelMatcher.Output {
        try database.writer.write { db in
            let providers = try Provider.filter(Column("isEnabled") == true).fetchAll(db)
            let priority = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0.priority) })
            let channels = try Channel
                .filter(providers.map(\.id.rawValue).contains(Column("providerID")))
                .fetchAll(db)
            let overrides = try ChannelLinkOverride.fetchAll(db)
            let output = ChannelMatcher.match(
                channels.map { ChannelMatcher.Input(channel: $0, providerPriority: priority[$0.providerID] ?? .max) },
                overrides: overrides)

            // Replace wholesale inside the transaction; readers see the old or the new set, never a mix.
            try LogicalChannelMember.deleteAll(db)
            try LogicalChannel.deleteAll(db)
            for logical in output.logicalChannels { try logical.insert(db) }
            for member in output.members { try member.insert(db) }
            Log.sync.info("Rebuilt \(output.logicalChannels.count) logical channels from \(channels.count) channels")
            return output
        }
    }

    /// Sources behind one logical channel, in provider priority order.
    public func sources(of logicalChannelID: String) throws -> [Channel] {
        try database.reader.read { db in
            try Channel.fetchAll(db, sql: """
                SELECT channel.* FROM logicalChannelMember m
                JOIN channel ON channel.providerID = m.providerID AND channel.streamID = m.streamID
                JOIN provider ON provider.id = m.providerID
                WHERE m.logicalChannelID = ? AND provider.isEnabled
                ORDER BY provider.priority, channel.sortIndex
                """, arguments: [logicalChannelID])
        }
    }

    public func logicalChannelID(providerID: ProviderID, streamID: Int) throws -> String? {
        try database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT logicalChannelID FROM logicalChannelMember WHERE providerID = ? AND streamID = ?",
                                arguments: [providerID, streamID])
        }
    }

    /// Manual link / unlink. Pass nil to remove an override and go back to automatic matching.
    public func setOverride(_ override: ChannelLinkOverride?, providerID: ProviderID, streamID: Int) throws {
        try database.writer.write { db in
            if let override {
                try override.upsert(db)
            } else {
                _ = try ChannelLinkOverride.deleteOne(db, key: ["providerID": providerID.rawValue, "streamID": streamID])
            }
        }
        try rebuild()
    }
}
