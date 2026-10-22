import Foundation
import GRDB

/// The app's SQLite database. Construct one per process and pass it down; there is no shared
/// global, so tests can use an in-memory database.
public struct AppDatabase: Sendable {
    /// Use for writes. Readers that should not block on writes can use `reader`.
    public let writer: any DatabaseWriter

    public var reader: any DatabaseReader { writer }

    /// Wraps an existing connection and applies all pending migrations.
    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (creating if needed) the on-disk database. Uses WAL via `DatabasePool`, so the UI can
    /// read while a background EPG import is writing.
    public static func open(at url: URL) throws -> AppDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pool = try DatabasePool(path: url.path, configuration: makeConfiguration())
        Log.database.info("Opened database at \(url.path, privacy: .public)")
        return try AppDatabase(pool)
    }

    /// An empty in-memory database with the full schema. For tests and SwiftUI previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue(configuration: makeConfiguration()))
    }

    /// Default on-disk location: ~/Library/Application Support/IPTVStreamer/iptv.sqlite
    /// (inside the app's sandbox container when sandboxed).
    public static func defaultURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("IPTVStreamer", isDirectory: true)
            .appendingPathComponent("iptv.sqlite")
    }

    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            // With WAL, NORMAL is durable against app crashes and much faster for bulk imports.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return config
    }

    /// Names of applied migrations, for diagnostics and tests.
    public func appliedMigrations() throws -> [String] {
        try reader.read { db in try Self.migrator.appliedIdentifiers(db).sorted() }
    }
}
