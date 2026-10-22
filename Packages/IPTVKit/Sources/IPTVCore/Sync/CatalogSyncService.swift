import Foundation

/// Builds a `SourceProvider` for a provider (loads credentials, picks the implementation).
public protocol SourceFactory: Sendable {
    func source(for provider: Provider) throws -> any SourceProvider
}

public enum SourceFactoryError: Error, CustomStringConvertible {
    case missingCredentials

    public var description: String { "No saved username and password for this provider. Edit it and enter them again." }
}

public struct XtreamSourceFactory: SourceFactory {
    private let secrets: any SecretStore
    private let transport: any HTTPTransport
    private let userAgent: @Sendable () -> String

    public init(secrets: any SecretStore, transport: any HTTPTransport = URLSessionTransport(),
                userAgent: @escaping @Sendable () -> String = { XtreamClient.defaultUserAgent }) {
        self.secrets = secrets
        self.transport = transport
        self.userAgent = userAgent
    }

    public func source(for provider: Provider) throws -> any SourceProvider {
        guard let credentials = try secrets.load(for: provider.id) else { throw SourceFactoryError.missingCredentials }
        return XtreamSourceProvider(provider: provider, credentials: credentials, transport: transport,
                                    userAgent: userAgent())
    }
}

/// What to refresh.
public struct RefreshParts: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let account = RefreshParts(rawValue: 1 << 0)
    public static let live = RefreshParts(rawValue: 1 << 1)
    public static let movies = RefreshParts(rawValue: 1 << 2)
    public static let series = RefreshParts(rawValue: 1 << 3)
    public static let guide = RefreshParts(rawValue: 1 << 4)

    public static let catalog: RefreshParts = [.account, .live, .movies, .series]
    public static let all: RefreshParts = [.catalog, .guide]
}

public enum SyncStep: String, Sendable, Equatable {
    case account, live, movies, series, guide, matching
}

public enum SyncEvent: Sendable, Equatable {
    case started(ProviderID)
    case step(ProviderID, SyncStep)
    case guideProgress(ProviderID, programmes: Int)
    case finished(ProviderID, error: String?)
}

public struct SyncReport: Sendable, Equatable {
    public var providerID: ProviderID
    public var account: AccountInfo?
    public var live: ReplaceStats?
    public var movies: ReplaceStats?
    public var series: ReplaceStats?
    public var guide: EPGImportSummary?
    /// First fatal error (account/auth). Per-part failures are in `partErrors`.
    public var error: String?
    public var partErrors: [SyncStep: String] = [:]
}

/// Refreshes provider catalogs and guides in the background. The UI never waits on it: it reads
/// the database, which this service updates in small transactions.
public actor CatalogSyncService {
    private let database: AppDatabase
    private let providers: ProviderRepository
    private let catalog: CatalogRepository
    private let settings: SettingsRepository
    private let logical: LogicalChannelStore
    private let importer: EPGImporter
    private let sources: any SourceFactory
    private let connections: ConnectionManager
    private let clock: any AppClock

    private var running: [ProviderID: Task<SyncReport, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<SyncEvent>.Continuation] = [:]

    public init(database: AppDatabase, sources: any SourceFactory, connections: ConnectionManager,
                clock: any AppClock = SystemClock()) {
        self.database = database
        providers = ProviderRepository(database: database)
        catalog = CatalogRepository(database: database)
        settings = SettingsRepository(database: database)
        logical = LogicalChannelStore(database: database)
        importer = EPGImporter(database: database, clock: clock)
        self.sources = sources
        self.connections = connections
        self.clock = clock
    }

    // MARK: Events

    /// A stream of sync events for one subscriber. Ends when the subscriber stops iterating.
    public func events() -> AsyncStream<SyncEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SyncEvent>.makeStream(bufferingPolicy: .bufferingNewest(64))
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func emit(_ event: SyncEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    public var activeProviderIDs: Set<ProviderID> { Set(running.keys) }

    // MARK: Refresh

    /// Refreshes one provider. A refresh already running for it is shared, unless `restart` is set
    /// (after its login or address changed, the running one still uses the old details): then it's
    /// cancelled and a new one starts.
    @discardableResult
    public func refresh(_ providerID: ProviderID, parts: RefreshParts = .all, restart: Bool = false) async -> SyncReport {
        if restart, let existing = running[providerID] {
            existing.cancel()
            _ = await existing.value
            if running[providerID] == existing { running[providerID] = nil }
        }
        if let existing = running[providerID] { return await existing.value }
        let task = Task { await self.performRefresh(providerID, parts: parts) }
        running[providerID] = task
        let report = await task.value
        // A restart may have replaced it with a newer run meanwhile.
        if running[providerID] == task { running[providerID] = nil }
        return report
    }

    /// Refreshes every enabled provider whose data is older than the configured intervals.
    /// Called at launch and periodically; returns immediately for fresh providers.
    public func refreshStale(force: Bool = false) async {
        let list = (try? providers.all().filter(\.isEnabled)) ?? []
        await withTaskGroup(of: Void.self) { group in
            for provider in list {
                let parts = force ? RefreshParts.all : stalePart(of: provider)
                guard !parts.isEmpty else { continue }
                group.addTask { await self.refresh(provider.id, parts: parts) }
            }
        }
    }

    /// Cancels all running refreshes (e.g. when quitting or removing a provider).
    public func cancel(_ providerID: ProviderID? = nil) {
        for (id, task) in running where providerID == nil || id == providerID { task.cancel() }
    }

    func stalePart(of provider: Provider) -> RefreshParts {
        let now = clock.now()
        let catalogHours = (try? settings.value(Double.self, for: .catalogRefreshHours)) ?? 12
        let guideHours = (try? settings.value(Double.self, for: .epgRefreshHours)) ?? 12
        var parts: RefreshParts = []
        if provider.lastRefreshAt.map({ now.timeIntervalSince($0) > catalogHours * 3600 }) ?? true {
            parts.formUnion(.catalog)
        }
        let lastGuide = try? settings.value(Date.self, for: .epgLastRefreshAt, scope: .provider(provider.id))
        if lastGuide.map({ now.timeIntervalSince($0) > guideHours * 3600 }) ?? true {
            parts.insert(.guide)
        }
        return parts
    }

    private func performRefresh(_ providerID: ProviderID, parts: RefreshParts) async -> SyncReport {
        var report = SyncReport(providerID: providerID)
        emit(.started(providerID))
        Log.sync.info("Refresh \(providerID, privacy: .public) parts=\(parts.rawValue)")

        guard var provider = try? providers.provider(id: providerID) else {
            report.error = "Provider not found"
            emit(.finished(providerID, error: report.error))
            return report
        }

        let source: any SourceProvider
        do {
            source = try sources.source(for: provider)
        } catch {
            return finish(&report, provider: &provider, fatal: error, credentials: [])
        }
        let redact = source.redactionCredentials

        // 1. Account: also validates credentials before downloading anything big.
        if parts.contains(.account) || parts.contains(.live) {
            emit(.step(providerID, .account))
            do {
                let account = try await source.fetchAccount()
                report.account = account
                provider.accountStatus = account.status
                provider.expiresAt = account.expiresAt
                provider.maxConnections = account.maxConnections
                provider.activeConnections = account.activeConnections
                if !account.allowedOutputFormats.isEmpty { provider.allowedOutputFormats = account.allowedOutputFormats }
                try? providers.updateStatus(provider)
                await connections.setLimit(account.maxConnections, for: providerID)
            } catch {
                return finish(&report, provider: &provider, fatal: error, credentials: redact)
            }
        }

        // 2–4. Catalog parts. One failing part doesn't stop the others.
        var catalogChanged = false
        if parts.contains(.live) {
            emit(.step(providerID, .live))
            do {
                async let categories = source.fetchCategories(.live)
                async let channels = source.fetchChannels()
                let fetched = try await channels
                try keepUnlessConfirmedEmpty(fetched.count, part: "live", providerID: providerID)
                try catalog.replaceCategories(try await categories, providerID: providerID, kind: .live)
                let stats = try catalog.replaceChannels(fetched, providerID: providerID)
                report.live = stats
                catalogChanged = catalogChanged || stats.changed
            } catch {
                report.partErrors[.live] = message(error, redact)
            }
        }
        if parts.contains(.movies), !Task.isCancelled {
            emit(.step(providerID, .movies))
            do {
                async let categories = source.fetchCategories(.movie)
                async let movies = source.fetchMovies()
                let fetched = try await movies
                try keepUnlessConfirmedEmpty(fetched.count, part: "movies", providerID: providerID)
                try catalog.replaceCategories(try await categories, providerID: providerID, kind: .movie)
                report.movies = try catalog.replaceMovies(fetched, providerID: providerID)
            } catch {
                report.partErrors[.movies] = message(error, redact)
            }
        }
        if parts.contains(.series), !Task.isCancelled {
            emit(.step(providerID, .series))
            do {
                async let categories = source.fetchCategories(.series)
                async let series = source.fetchSeries()
                let fetched = try await series
                try keepUnlessConfirmedEmpty(fetched.count, part: "series", providerID: providerID)
                try catalog.replaceCategories(try await categories, providerID: providerID, kind: .series)
                report.series = try catalog.replaceSeries(fetched, providerID: providerID)
                // After a renumbering, fetch the episode lists of series the library uses, so their
                // episodes' progress and Recently Watched entries move to the new episode IDs.
                for seriesID in try catalog.seriesAwaitingRelink(providerID: providerID).prefix(200) where !Task.isCancelled {
                    if let details = try? await source.fetchSeriesDetails(seriesID: seriesID) {
                        try? catalog.replaceSeriesDetails(details, providerID: providerID, seriesID: seriesID)
                    }
                }
            } catch {
                report.partErrors[.series] = message(error, redact)
            }
        }
        for (part, stats) in [("live", report.live), ("movies", report.movies), ("series", report.series)] {
            guard let stats, stats.relinked + stats.unlinked > 0 else { continue }
            Log.sync.info("Provider renumbered \(part, privacy: .public): moved \(stats.relinked) library item(s) to new IDs, removed \(stats.unlinked) that no longer match")
        }

        if catalogChanged || (parts.contains(.live) && report.live != nil && (try? logicalCount()) == 0) {
            emit(.step(providerID, .matching))
            do { try logical.rebuild() } catch { report.partErrors[.matching] = message(error, redact) }
        }

        if !parts.isDisjoint(with: .catalog), report.partErrors.isEmpty {
            provider.lastRefreshAt = clock.now()
        }

        // 5. Guide last: it's the largest download, and channels must exist to filter it.
        if parts.contains(.guide), !Task.isCancelled {
            emit(.step(providerID, .guide))
            do {
                if let file = try await source.downloadGuide() {
                    defer { try? FileManager.default.removeItem(at: file) }
                    let window = EPGWindow(
                        pastDays: (try? settings.value(Double.self, for: .epgPastDays)) ?? 1,
                        futureDays: (try? settings.value(Double.self, for: .epgFutureDays)) ?? 7)
                    let summary = try await importer.importGuide(file: file, providerID: providerID, window: window) { count in
                        Task { await self.emit(.guideProgress(providerID, programmes: count)) }
                    }
                    report.guide = summary
                    if let partial = summary.partialError { report.partErrors[.guide] = "Guide partly imported: \(partial)" }
                    try? settings.set(clock.now(), for: .epgLastRefreshAt, scope: .provider(providerID))
                }
            } catch {
                report.partErrors[.guide] = message(error, redact)
            }
        }

        provider.lastError = report.partErrors.isEmpty
            ? nil
            : report.partErrors.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue): \($0.value)" }.joined(separator: "\n")
        try? providers.updateStatus(provider)
        emit(.finished(providerID, error: provider.lastError))
        Log.sync.info("Refresh \(providerID, privacy: .public) done; errors: \(report.partErrors.count)")
        return report
    }

    private func finish(_ report: inout SyncReport, provider: inout Provider, fatal error: Error,
                        credentials: [ProviderCredentials]) -> SyncReport {
        let text = message(error, credentials)
        report.error = text
        provider.lastError = text
        try? providers.updateStatus(provider)
        let id = provider.id
        Log.sync.error("Refresh \(id, privacy: .public) failed: \(text, privacy: .public)")
        emit(.finished(id, error: text))
        return report
    }

    struct EmptyListKept: Error, CustomStringConvertible {
        var description: String { "The provider returned an empty list, so the previous one was kept. It will be replaced if the next refresh is empty too." }
    }

    /// Overloaded panels sometimes answer with an empty list instead of an error. Replacing the
    /// stored catalog with it would empty Live TV, the guide or Movies until the next refresh, so an
    /// empty list only counts when the following refresh agrees.
    private func keepUnlessConfirmedEmpty(_ count: Int, part: String, providerID: ProviderID) throws {
        let scope = SettingScope.provider(providerID)
        let before = Set((try? settings.value([String].self, for: .emptyCatalogParts, scope: scope)) ?? [])
        var empty = before
        defer {
            // Only written when it changes: setting writes make open screens reload.
            if empty != before { try? settings.set(empty.isEmpty ? nil : empty.sorted(), for: .emptyCatalogParts, scope: scope) }
        }
        guard count == 0 else {
            empty.remove(part)
            return
        }
        let counts = (try? catalog.counts(providerID: providerID)) ?? CatalogCounts()
        let stored = switch part {
        case "live": counts.channels
        case "movies": counts.movies
        default: counts.series
        }
        if stored == 0 || empty.remove(part) != nil { return }
        empty.insert(part)
        throw EmptyListKept()
    }

    private func message(_ error: Error, _ credentials: [ProviderCredentials]) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return CredentialRedactor.redact(text, credentials: credentials)
    }

    private func logicalCount() throws -> Int {
        try database.reader.read { db in try LogicalChannel.fetchCount(db) }
    }
}
