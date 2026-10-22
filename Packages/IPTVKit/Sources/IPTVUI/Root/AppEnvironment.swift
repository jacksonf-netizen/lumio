import Foundation
import IPTVCore
import IPTVPlayback

/// Everything the UI needs, built once at launch and passed down. No singletons: previews and tests
/// build their own with an in-memory database and secret store.
public struct AppEnvironment: Sendable {
    public let database: AppDatabase
    public let providers: ProviderService
    public let catalog: CatalogRepository
    public let epg: EPGRepository
    public let settings: SettingsRepository
    public let logicalChannels: LogicalChannelStore
    public let connections: ConnectionManager
    public let sync: CatalogSyncService
    public let secrets: any SecretStore
    public let systemEvents: any SystemEventSource
    public let items: PlaybackItemBuilder
    /// Builds provider sources for on-demand requests (movie and series details).
    public let sources: any SourceFactory

    public init(database: AppDatabase, secrets: any SecretStore, transport: any HTTPTransport,
                systemEvents: any SystemEventSource = NoSystemEvents(),
                syncProvider: any SyncProvider = LocalOnlySyncProvider(), clock: any AppClock = SystemClock()) {
        self.database = database
        self.secrets = secrets
        self.systemEvents = systemEvents
        items = PlaybackItemBuilder(database: database)
        providers = ProviderService(database: database, secrets: secrets, sync: syncProvider)
        catalog = CatalogRepository(database: database)
        epg = EPGRepository(database: database)
        let settings = SettingsRepository(database: database)
        self.settings = settings
        logicalChannels = LogicalChannelStore(database: database)
        connections = ConnectionManager()
        let sources = XtreamSourceFactory(secrets: secrets, transport: transport, userAgent: {
            (try? settings.value(String.self, for: .userAgent)) ?? XtreamClient.defaultUserAgent
        })
        self.sources = sources
        sync = CatalogSyncService(database: database, sources: sources, connections: connections, clock: clock)
    }

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

    /// In-memory environment for SwiftUI previews. Never touches the network.
    public static func preview() -> AppEnvironment {
        // An in-memory database only fails to open if SQLite itself is broken.
        AppEnvironment(database: try! AppDatabase.inMemory(), secrets: InMemorySecretStore(), transport: OfflineTransport())
    }

    /// Call once at launch: restores connection limits from cached account info, then refreshes
    /// stale providers in the background. Returns immediately.
    public func startBackgroundWork() {
        let environment = self
        Task.detached(priority: .utility) {
            for provider in (try? environment.providers.repository.all()) ?? [] {
                await environment.connections.setLimit(provider.maxConnections, for: provider.id)
            }
            await environment.sync.refreshStale()
            // Re-check every 30 minutes while the app runs.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30 * 60))
                await environment.sync.refreshStale()
            }
        }
    }
}

/// Transport that always reports "offline". Used by previews.
struct OfflineTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw XtreamError.offline }
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) { throw XtreamError.offline }
}
