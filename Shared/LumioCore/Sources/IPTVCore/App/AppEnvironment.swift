import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The shared core's services, wired together the same way in every Lumio app. Each app builds one
/// at launch with its own secret store, network transport and system events, and passes it down.
/// No singletons: previews and tests build their own with an in-memory database and secret store.
public struct AppEnvironment: Sendable {
    public let database: AppDatabase
    public let providers: ProviderService
    public let catalog: CatalogRepository
    public let epg: EPGRepository
    public let settings: SettingsRepository
    public let logicalChannels: LogicalChannelStore
    public let connections: ConnectionManager
    public let sync: CatalogSyncService
    /// Keeps providers on a server link that works.
    public let servers: ServerFailover
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
        let servers = ServerFailover(database: database, secrets: secrets, transport: transport, clock: clock, userAgent: {
            (try? settings.value(String.self, for: .userAgent)) ?? XtreamClient.defaultUserAgent
        })
        self.servers = servers
        sync = CatalogSyncService(database: database, sources: sources, connections: connections, servers: servers, clock: clock)
    }

    /// In-memory environment for previews and tests. Never touches the network.
    public static func preview() -> AppEnvironment {
        // An in-memory database only fails to open if SQLite itself is broken.
        AppEnvironment(database: try! AppDatabase.inMemory(), secrets: InMemorySecretStore(), transport: OfflineTransport())
    }

    /// Call once at launch: restores connection limits from cached account info, checks every
    /// provider's server links, then refreshes stale providers in the background. Returns
    /// immediately; streams don't wait for any of it (they start on the link last known to work).
    public func startBackgroundWork() {
        let environment = self
        Task.detached(priority: .utility) {
            for provider in (try? environment.providers.repository.all()) ?? [] {
                await environment.connections.setLimit(provider.maxConnections, for: provider.id)
            }
            await environment.servers.recheckAll()
            await environment.sync.refreshStale()
            // While the app runs: stale refreshes every 30 minutes, all links every 6 hours, and
            // every 5 minutes for a provider whose links are all down, so it recovers soon after.
            var lastLinkCheck = Date()
            var lastRefresh = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5 * 60))
                if Date().timeIntervalSince(lastLinkCheck) >= 6 * 3600 {
                    lastLinkCheck = Date()
                    await environment.servers.recheckAll()
                } else {
                    await environment.servers.recheckAllDown()
                }
                if Date().timeIntervalSince(lastRefresh) >= 30 * 60 {
                    lastRefresh = Date()
                    await environment.sync.refreshStale()
                }
            }
        }
    }
}

/// Transport that always reports "offline". Used by previews.
public struct OfflineTransport: HTTPTransport {
    public init() {}
    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw XtreamError.offline }
    public func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) { throw XtreamError.offline }
}
