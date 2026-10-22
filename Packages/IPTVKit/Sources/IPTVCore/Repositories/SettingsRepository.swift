import Foundation
import GRDB

/// Typed settings stored as JSON in the `setting` table, at global, provider or channel scope.
public struct SettingsRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func value<T: Decodable>(_ type: T.Type, for key: SettingKey, scope: SettingScope = .global) throws -> T? {
        let record = try database.reader.read { db in
            try SettingRecord.fetchOne(db, key: ["scopeKey": scope.key, "key": key.rawValue])
        }
        guard let record else { return nil }
        return try? JSONDecoder.settings.decode(T.self, from: Data(record.value.utf8))
    }

    public func set<T: Encodable>(_ value: T?, for key: SettingKey, scope: SettingScope = .global) throws {
        try database.writer.write { db in
            if let value {
                let json = String(decoding: try JSONEncoder.settings.encode(value), as: UTF8.self)
                try SettingRecord(scope: scope, key: key.rawValue, value: json).upsert(db)
            } else {
                _ = try SettingRecord.deleteOne(db, key: ["scopeKey": scope.key, "key": key.rawValue])
            }
        }
    }

    /// Value at the narrowest scope that has one: channel, then provider, then global.
    public func resolved<T: Decodable>(_ type: T.Type, for key: SettingKey, providerID: ProviderID?,
                                       streamID: Int? = nil) throws -> T? {
        if let providerID, let streamID,
           let value = try value(type, for: key, scope: .channel(providerID, streamID: streamID)) {
            return value
        }
        if let providerID, let value = try value(type, for: key, scope: .provider(providerID)) {
            return value
        }
        return try value(type, for: key, scope: .global)
    }
}

/// All setting keys in one place.
public enum SettingKey: String, Sendable, CaseIterable {
    case catalogRefreshHours
    case epgRefreshHours
    case epgPastDays
    case epgFutureDays
    case epgLastRefreshAt
    case userAgent
    case preferredFormat
    case engine
    case bufferPreset
    case stallTimeoutSeconds
    case hiddenCategoryKinds
    /// Region codes ("UK", "US", …) whose categories are hidden everywhere. `[String]`.
    case hiddenRegions
    /// The user's region merges: provider spelling → region (`["NA": "US"]`). `[String: String]`.
    case regionAliases
    /// Per provider: catalog parts whose last refresh came back empty (see CatalogSyncService).
    case emptyCatalogParts
}

extension JSONEncoder {
    static let settings: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let settings: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
