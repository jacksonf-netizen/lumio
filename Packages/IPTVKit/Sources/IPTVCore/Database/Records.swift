import Foundation
import GRDB

// GRDB conformances for the models. Kept separate from the model files so the models themselves
// stay plain value types.

/// Shared record behaviour: dates are stored as Unix timestamps (REAL), which keeps EPG range
/// queries fast and compact.
public protocol TimestampDateRecord: FetchableRecord, EncodableRecord {}

extension TimestampDateRecord {
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }

    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
}

/// A Codable table record with timestamp dates.
public protocol AppRecord: Codable, TimestampDateRecord, PersistableRecord {}

// MARK: - Column value types

extension ProviderID: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { rawValue.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> ProviderID? {
        String.fromDatabaseValue(dbValue).map(ProviderID.init)
    }
}

extension SourceKind: DatabaseValueConvertible {}
extension ContentKind: DatabaseValueConvertible {}
extension LibraryItemKind: DatabaseValueConvertible {}
extension EngineKind: DatabaseValueConvertible {}
extension StreamFormat: DatabaseValueConvertible {}
extension ChannelLinkOverride.Action: DatabaseValueConvertible {}

// MARK: - Tables

extension Provider: AppRecord {
    public static let databaseTableName = "provider"
}

extension Category: AppRecord {
    public static let databaseTableName = "category"
}

extension Channel: AppRecord {
    public static let databaseTableName = "channel"
}

extension LogicalChannel: AppRecord {
    public static let databaseTableName = "logicalChannel"
}

extension LogicalChannelMember: AppRecord {
    public static let databaseTableName = "logicalChannelMember"
}

extension ChannelLinkOverride: AppRecord {
    public static let databaseTableName = "channelLinkOverride"
}

extension EPGChannel: AppRecord {
    public static let databaseTableName = "epgChannel"
}

extension Programme: TimestampDateRecord, MutablePersistableRecord {
    public static let databaseTableName = "programme"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

extension EPGMappingOverride: AppRecord {
    public static let databaseTableName = "epgMappingOverride"
}

extension LogicalEPGOverride: AppRecord {
    public static let databaseTableName = "logicalEPGOverride"
}

extension Movie: AppRecord {
    public static let databaseTableName = "movie"
}

extension Series: AppRecord {
    public static let databaseTableName = "series"
}

extension Season: AppRecord {
    public static let databaseTableName = "season"
}

extension Episode: AppRecord {
    public static let databaseTableName = "episode"
}

extension Favorite: AppRecord {
    public static let databaseTableName = "favorite"
}

extension WatchProgress: AppRecord {
    public static let databaseTableName = "watchProgress"
}

extension RecentItem: AppRecord {
    public static let databaseTableName = "recentItem"
}

extension ChannelOverride: AppRecord {
    public static let databaseTableName = "channelOverride"
}

extension CategoryOverride: AppRecord {
    public static let databaseTableName = "categoryOverride"
}

extension CustomGroup: AppRecord {
    public static let databaseTableName = "customGroup"
}

extension CustomGroupMember: AppRecord {
    public static let databaseTableName = "customGroupMember"
}

extension PlaybackHistory: AppRecord {
    public static let databaseTableName = "playbackHistory"
}

extension SettingRecord: AppRecord {
    public static let databaseTableName = "setting"
}
