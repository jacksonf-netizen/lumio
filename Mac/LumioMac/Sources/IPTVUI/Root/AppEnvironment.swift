import Foundation
import IPTVCore
import IPTVPlayback

/// The Mac app's environment: the on-disk database, the macOS Keychain, URLSession and the Mac's
/// sleep/wake and network events. The services themselves are wired in the shared core.
extension AppEnvironment {
    /// The real app: on-disk database, the macOS Keychain and URLSession.
    public static func live() throws -> AppEnvironment {
        var url = try AppDatabase.defaultURL()
        var secrets: any SecretStore = KeychainSecretStore()
        var seed = false
        // Development and measurement: a fresh, separate library with credentials held in memory only,
        // so automated runs never touch the real library or the Keychain.
        //   Debug builds:  -databaseName smoke
        //   Any build:     IPTV_DEV_DATABASE=name (IPTV_DEV_SEED=1 adds a synthetic provider and channels)
        var devName = ProcessInfo.processInfo.environment["IPTV_DEV_DATABASE"]
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "databaseName"), !name.isEmpty { devName = name }
        #endif
        // Letters, digits, "-" and "_" only: the name becomes part of a file path that's deleted.
        devName = devName?.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        if let name = devName, !name.isEmpty {
            url = url.deletingLastPathComponent().appendingPathComponent("dev-\(name).sqlite")
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
            }
            secrets = InMemorySecretStore()
            seed = ProcessInfo.processInfo.environment["IPTV_DEV_SEED"] != nil
        }
        let database = try AppDatabase.open(at: url)
        if seed { try seedSyntheticLibrary(database) }
        return AppEnvironment(database: database, secrets: secrets, transport: URLSessionTransport(),
                              systemEvents: MacSystemEvents())
    }

    /// A provider with 300 channels in 10 groups (no network), for launch measurements.
    private static func seedSyntheticLibrary(_ database: AppDatabase) throws {
        let id = ProviderID("dev-seed")
        try database.writer.write { db in
            try Provider(id: id, name: "Synthetic", serverURL: URL(string: "http://dev.invalid")!,
                         lastRefreshAt: Date(), epgTimeOffsetMinutes: 0).insert(db)
            for c in 0..<10 {
                try Category(providerID: id, kind: .live, categoryID: "\(c)", name: "Group \(c)", sortIndex: c).insert(db)
            }
            let count = Int(ProcessInfo.processInfo.environment["IPTV_DEV_SEED_CHANNELS"] ?? "") ?? 300
            for n in 0..<count {
                try Channel(providerID: id, streamID: n, number: n + 1, name: "Channel \(n + 1)",
                            epgChannelID: "dev\(n)", categoryID: "\(n % 10)", sortIndex: n).insert(db)
            }
            try SettingRecord(scope: .provider(id), key: SettingKey.epgLastRefreshAt.rawValue,
                              value: String(Date().timeIntervalSince1970)).insert(db)
        }
        try LogicalChannelStore(database: database).rebuild()
    }

}
