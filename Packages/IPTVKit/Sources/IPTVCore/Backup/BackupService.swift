import Foundation
import GRDB

/// Export / import of settings, favorites, channel layout and watch history as JSON.
/// Credentials are never included. On import, providers are matched by server URL, so a backup
/// restores onto a fresh install once the same providers have been added again.
public struct BackupService: Sendable {
    public static let format = "iptv-streamer-backup"
    public static let currentVersion = 1

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public struct Backup: Codable, Sendable {
        public var format: String
        public var version: Int
        public var exportedAt: Date
        public var providers: [ProviderInfo]
        public var favorites: [Favorite]
        public var watchProgress: [WatchProgress]
        public var channelOverrides: [ChannelOverride]
        public var categoryOverrides: [CategoryOverride]
        public var customGroups: [CustomGroup]
        public var customGroupMembers: [CustomGroupMember]
        public var channelLinks: [ChannelLinkOverride]
        public var epgMappings: [EPGMappingOverride]
        public var logicalEPG: [LogicalEPGOverride]
        public var settings: [SettingRecord]
    }

    /// Provider configuration without credentials.
    public struct ProviderInfo: Codable, Sendable {
        public var id: ProviderID
        public var name: String
        public var serverURL: URL
        public var priority: Int
        public var isEnabled: Bool
        public var epgTimeOffsetMinutes: Int
        public var userAgentOverride: String?
    }

    public struct ImportSummary: Sendable, Equatable {
        public var matchedProviders: [String] = []
        public var unmatchedProviders: [String] = []
        public var imported = 0
        public var skipped = 0
    }

    public enum BackupError: Error, CustomStringConvertible {
        case notABackup
        case newerVersion(Int)

        public var description: String {
            switch self {
            case .notABackup: "This file isn't a Lumio backup."
            case .newerVersion(let v): "This backup was made by a newer version of the app (format \(v))."
            }
        }
    }

    // MARK: Export

    public func export() async throws -> Data {
        let backup = try await database.reader.read { db in
            Backup(
                format: Self.format, version: Self.currentVersion, exportedAt: Date(),
                providers: try Provider.fetchAll(db).map {
                    ProviderInfo(id: $0.id, name: $0.name, serverURL: $0.serverURL, priority: $0.priority, isEnabled: $0.isEnabled,
                                 epgTimeOffsetMinutes: $0.epgTimeOffsetMinutes, userAgentOverride: $0.userAgentOverride)
                },
                favorites: try Favorite.fetchAll(db),
                watchProgress: try WatchProgress.fetchAll(db),
                channelOverrides: try ChannelOverride.fetchAll(db),
                categoryOverrides: try CategoryOverride.fetchAll(db),
                customGroups: try CustomGroup.fetchAll(db),
                customGroupMembers: try CustomGroupMember.fetchAll(db),
                channelLinks: try ChannelLinkOverride.fetchAll(db),
                epgMappings: try EPGMappingOverride.fetchAll(db),
                logicalEPG: try LogicalEPGOverride.fetchAll(db),
                settings: try SettingRecord.fetchAll(db))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    // MARK: Import

    /// Merges a backup into the current library. Existing items with the same keys are replaced.
    @discardableResult
    public func importBackup(_ data: Data) async throws -> ImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let backup = try? decoder.decode(Backup.self, from: data), backup.format == Self.format else {
            throw BackupError.notABackup
        }
        guard backup.version <= Self.currentVersion else { throw BackupError.newerVersion(backup.version) }

        return try await database.writer.write { db in
            var summary = ImportSummary()
            let current = try Provider.fetchAll(db)
            // Exported provider id → provider in this library.
            var map: [ProviderID: ProviderID] = [:]
            for info in backup.providers {
                if var match = current.first(where: { $0.serverURL == info.serverURL && $0.name == info.name })
                    ?? current.first(where: { $0.serverURL == info.serverURL }) {
                    map[info.id] = match.id
                    summary.matchedProviders.append(info.name)
                    match.priority = info.priority
                    match.isEnabled = info.isEnabled
                    match.epgTimeOffsetMinutes = info.epgTimeOffsetMinutes
                    match.userAgentOverride = info.userAgentOverride
                    try match.update(db)
                } else {
                    summary.unmatchedProviders.append(info.name)
                }
            }

            func store<R: PersistableRecord>(_ records: [R], provider: KeyPath<R, ProviderID>, remap: (inout R, ProviderID) -> Void) throws {
                for var record in records {
                    guard let target = map[record[keyPath: provider]] else {
                        summary.skipped += 1
                        continue
                    }
                    remap(&record, target)
                    try record.upsert(db)
                    summary.imported += 1
                }
            }
            try store(backup.favorites, provider: \.providerID) { $0.providerID = $1 }
            try store(backup.watchProgress, provider: \.providerID) { $0.providerID = $1 }
            try store(backup.channelOverrides, provider: \.providerID) { $0.providerID = $1 }
            try store(backup.categoryOverrides, provider: \.providerID) { $0.providerID = $1 }
            try store(backup.channelLinks, provider: \.providerID) { $0.providerID = $1 }

            for group in backup.customGroups {
                try group.upsert(db)
                summary.imported += 1
            }
            try store(backup.customGroupMembers, provider: \.providerID) { $0.providerID = $1 }

            for var mapping in backup.epgMappings {
                guard let owner = map[mapping.providerID], let guide = map[mapping.epgProviderID] else { summary.skipped += 1; continue }
                mapping.providerID = owner
                mapping.epgProviderID = guide
                try mapping.upsert(db)
                summary.imported += 1
            }
            for var override in backup.logicalEPG {
                guard let guide = map[override.epgProviderID] else { summary.skipped += 1; continue }
                override.epgProviderID = guide
                // Logical ids embed provider ids only for unmatched ("solo") channels.
                for (old, new) in map { override.logicalChannelID = override.logicalChannelID.replacingOccurrences(of: old.rawValue, with: new.rawValue) }
                try override.upsert(db)
                summary.imported += 1
            }
            for var setting in backup.settings {
                if let old = setting.providerID {
                    guard let new = map[old] else { summary.skipped += 1; continue }
                    setting.providerID = new
                    setting.scopeKey = setting.scopeKey.replacingOccurrences(of: old.rawValue, with: new.rawValue)
                }
                // Per-install refresh bookkeeping isn't restored.
                if [SettingKey.epgLastRefreshAt, .emptyCatalogParts].map(\.rawValue).contains(setting.key) { continue }
                try setting.upsert(db)
                summary.imported += 1
            }
            // Restored region merges apply to the categories already here.
            if backup.settings.contains(where: { $0.key == SettingKey.regionAliases.rawValue }) {
                try RegionPrefix.recompute(in: db)
            }
            return summary
        }
    }
}
