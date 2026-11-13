import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Builds a `SourceProvider` for a provider (loads credentials, picks the implementation).
public protocol SourceFactory: Sendable {
    func source(for provider: Provider) throws -> any SourceProvider
    /// Guide links the user added to `provider` (`GuideLinkStore`).
    func guideLinks(for provider: Provider) throws -> [URL]
    /// Downloads a guide link to a temporary file the caller deletes.
    func downloadGuideLink(_ url: URL) async throws -> URL
}

public extension SourceFactory {
    func guideLinks(for provider: Provider) throws -> [URL] { [] }
    func downloadGuideLink(_ url: URL) async throws -> URL { throw XtreamError.notFound }
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

    public func guideLinks(for provider: Provider) throws -> [URL] {
        try GuideLinkStore(secrets: secrets).links(for: provider.id)
    }

    public func downloadGuideLink(_ url: URL) async throws -> URL {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 300)
        request.setValue(userAgent(), forHTTPHeaderField: "User-Agent")
        do {
            let (file, response) = try await transport.download(for: request)
            if let error = XtreamError.from(statusCode: response.statusCode) {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 0
            if size > XtreamClient.maxGuideDownloadBytes {
                try? FileManager.default.removeItem(at: file)
                throw XtreamError.invalidResponse("the guide file is \(size >> 20) MB, over the \(XtreamClient.maxGuideDownloadBytes >> 20) MB limit")
            }
            return file
        } catch {
            throw XtreamError.from(error)
        }
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
    /// The guide links the user added (`GuideLinkStore`), after the provider's own guide.
    case guideLinks
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
    private let servers: ServerFailover?

    private var running: [ProviderID: Task<SyncReport, Never>] = [:]
    private var subscribers: [UUID: AsyncStream<SyncEvent>.Continuation] = [:]

    public init(database: AppDatabase, sources: any SourceFactory, connections: ConnectionManager,
                servers: ServerFailover? = nil, clock: any AppClock = SystemClock()) {
        self.servers = servers
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

        var opened: any SourceProvider
        do {
            opened = try sources.source(for: provider)
        } catch {
            return finish(&report, provider: &provider, fatal: error, credentials: [])
        }
        let redact = opened.redactionCredentials

        // 1. Account: also validates credentials before downloading anything big.
        if parts.contains(.account) || parts.contains(.live) {
            emit(.step(providerID, .account))
            do {
                let account: AccountInfo
                do {
                    account = try await opened.fetchAccount()
                } catch let error as XtreamError where Self.mayMeanServerDown(error) {
                    // The address in use may have died: move to a working link and try once more.
                    guard let servers, case .switched = await servers.ensureWorking(providerID),
                          let moved = try? providers.provider(id: providerID) else { throw error }
                    provider.serverURL = moved.serverURL
                    opened = try sources.source(for: provider)
                    account = try await opened.fetchAccount()
                }
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

        let source = opened

        // 2–4. Catalog parts. One failing part doesn't stop the others.
        var catalogChanged = false
        if parts.contains(.live) {
            emit(.step(providerID, .live))
            do {
                async let categories = source.fetchCategories(.live)
                async let channels = source.fetchChannels()
                let fetched = try await channels
                let stored = ContinuousClock.now
                try keepUnlessConfirmedEmpty(fetched.count, part: "live", providerID: providerID)
                try catalog.replaceCategories(try await categories, providerID: providerID, kind: .live)
                let stats = try catalog.replaceChannels(fetched, providerID: providerID)
                Self.logStored(fetched.count, "channels", since: stored)
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
                let stored = ContinuousClock.now
                try keepUnlessConfirmedEmpty(fetched.count, part: "movies", providerID: providerID)
                try catalog.replaceCategories(try await categories, providerID: providerID, kind: .movie)
                report.movies = try catalog.replaceMovies(fetched, providerID: providerID)
                Self.logStored(fetched.count, "movies", since: stored)
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
                let stored = ContinuousClock.now
                try keepUnlessConfirmedEmpty(fetched.count, part: "series", providerID: providerID)
                try catalog.replaceCategories(try await categories, providerID: providerID, kind: .series)
                report.series = try catalog.replaceSeries(fetched, providerID: providerID)
                Self.logStored(fetched.count, "series", since: stored)
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
                if !parts.isDisjoint(with: .catalog) {
                    // Flood protection on some panels blocks a request right after a run of them.
                    try await clock.sleep(for: Self.guidePause)
                }
                if let file = try await downloadGuide(providerID, provider: &provider, source: source) {
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
            } catch XtreamError.notFound {
                report.partErrors[.guide] = "The provider has no guide download at this address (\"not found\"). Lumio keeps the guide it already has."
            } catch {
                report.partErrors[.guide] = message(error, redact)
            }
        }

        // 6. Guide links: after the provider's own guide, whether or not that loaded.
        if parts.contains(.guide), !Task.isCancelled {
            await importGuideLinks(providerID, provider: provider, report: &report, redact: redact)
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

    /// "Stored 200225 movies in 12.3 s": with the network log's download times, shows where a slow
    /// refresh spends its time.
    static func logStored(_ count: Int, _ what: String, since start: ContinuousClock.Instant) {
        let seconds = Double((ContinuousClock.now - start).components.attoseconds) / 1e18
            + Double((ContinuousClock.now - start).components.seconds)
        Log.sync.info("Stored \(count) \(what, privacy: .public) in \(String(format: "%.1f", seconds), privacy: .public) s")
    }

    /// Pause between the catalog requests and the guide download.
    static let guidePause: Duration = .seconds(5)
    /// Waits before each new try of the guide download. Flood protection and overloaded panels
    /// usually let go within a minute.
    static let guideRetryDelays: [Duration] = [.seconds(10), .seconds(30), .seconds(60)]

    /// Downloads the guide, trying again after a pause while the server may only be busy: panels
    /// with flood protection answer "not found" after a run of requests, and big guides from
    /// overloaded panels time out or drop halfway. Before the first new try it checks the address
    /// in use, and moves to a working link if that one died.
    private func downloadGuide(_ providerID: ProviderID, provider: inout Provider,
                               source: any SourceProvider) async throws -> URL? {
        var source = source
        var checkedLink = false
        var attempt = 0
        while true {
            do {
                return try await source.downloadGuide()
            } catch let error as XtreamError where attempt < Self.guideRetryDelays.count && Self.mayRetryGuide(error) {
                Log.sync.notice("Guide download for \(providerID, privacy: .public) failed (\(error.description, privacy: .public)); trying again")
                if !checkedLink, Self.mayMeanServerDown(error), let servers {
                    checkedLink = true
                    if case .switched = await servers.ensureWorking(providerID), let moved = try? providers.provider(id: providerID) {
                        provider.serverURL = moved.serverURL
                        source = try sources.source(for: provider)
                        continue
                    }
                }
                try await clock.sleep(for: Self.guideRetryDelays[attempt])
                attempt += 1
            }
        }
    }

    /// Errors a guide download may get past by trying again. Not a refused login, a guide over the
    /// size limit or a file that isn't a guide. A bare number is a transport error code.
    static func mayRetryGuide(_ error: XtreamError) -> Bool {
        switch error {
        case .notFound, .timeout, .offline, .cannotConnect, .server, .httpStatus, .rateLimited, .maxConnectionsReached: true
        case .invalidResponse(let detail): Int(detail) != nil
        default: false
        }
    }

    static func mayMeanServerDown(_ error: XtreamError) -> Bool {
        switch error {
        case .timeout, .cannotConnect, .server, .httpStatus, .notFound, .forbidden, .invalidResponse, .decoding: true
        default: false
        }
    }

    /// Downloads and imports `provider`'s guide links, one at a time. A link that fails is reported
    /// under `guideLinks` (never `guide`: that would make the provider look as if it had no guide
    /// file, see `ShortGuideFiller`), shown by its host and path only.
    private func importGuideLinks(_ providerID: ProviderID, provider: Provider, report: inout SyncReport,
                                  redact: [ProviderCredentials]) async {
        let links: [URL]
        do { links = try sources.guideLinks(for: provider) } catch {
            report.partErrors[.guideLinks] = "Couldn't read the guide links: \(message(error, redact))"
            return
        }
        guard !links.isEmpty else { return }
        emit(.step(providerID, .guideLinks))
        var files: [URL] = []
        defer { for file in files { try? FileManager.default.removeItem(at: file) } }
        var problems: [String] = []
        for link in links {
            if Task.isCancelled { return }
            do {
                files.append(try await sources.downloadGuideLink(link))
            } catch {
                problems.append("\(GuideLinkStore.display(link)): \(Self.hideLink(link, in: message(error, redact)))")
            }
        }
        if !files.isEmpty {
            let window = EPGWindow(
                pastDays: (try? settings.value(Double.self, for: .epgPastDays)) ?? 1,
                futureDays: (try? settings.value(Double.self, for: .epgFutureDays)) ?? 7)
            do {
                let summary = try await importer.importGuideLinks(files: files, providerID: providerID, window: window,
                                                                  complete: problems.isEmpty)
                problems += summary.partialErrors.map { "Partly read: \($0)" }
                if summary.matchedChannels == 0 { problems.append("None of its channels matched this provider's.") }
            } catch is CancellationError {
                return
            } catch {
                problems.append(message(error, redact))
            }
        }
        if !problems.isEmpty { report.partErrors[.guideLinks] = problems.joined(separator: " ") }
    }

    /// `text` with the link (and its query, where a login usually is) replaced by its host and path.
    static func hideLink(_ link: URL, in text: String) -> String {
        var text = text.replacingOccurrences(of: link.absoluteString, with: GuideLinkStore.display(link))
        for item in URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            if let value = item.value, value.count >= 3 { text = text.replacingOccurrences(of: value, with: "***") }
        }
        return text
    }

    private func message(_ error: Error, _ credentials: [ProviderCredentials]) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return CredentialRedactor.redact(text, credentials: credentials)
    }

    private func logicalCount() throws -> Int {
        try database.reader.read { db in try LogicalChannel.fetchCount(db) }
    }
}
