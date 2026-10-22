import Foundation
import GRDB

// MARK: - Settings

/// Tunables for the reliability layer. Defaults suit typical IPTV providers.
public struct PlaybackSettings: Sendable, Equatable {
    public var defaultEngine: EngineKind = .mpv
    public var defaultFormat: StreamFormat = .ts
    public var buffer: BufferPreset = .normal
    /// No new frames or buffer growth for this long while playing = stalled.
    public var stallTimeout: Double = 8
    /// Time allowed from opening to the first frame.
    public var openTimeout: Double = 15
    /// Tries per rung of the fallback ladder (first try + reconnects).
    public var attemptsPerRung: Int = 3
    public var backoffBase: Double = 1
    public var backoffCap: Double = 15
    /// Playing this long counts as "it was working": a later stall reconnects on the same rung
    /// with a fresh attempt budget.
    public var stableAfter: Double = 20
    /// Wait for zapping to settle before opening a stream.
    public var zapDebounce: Double = 0.35
    /// How often the watchdog samples metrics.
    public var watchdogInterval: Double = 1

    public init() {}

    /// Delay before reconnect attempt `attempt` (1-based): exponential, capped, with jitter in [0.5, 1].
    public func backoff(attempt: Int, jitter: Double) -> Double {
        let raw = backoffBase * pow(2, Double(max(0, attempt - 1)))
        return min(backoffCap, raw) * (0.5 + 0.5 * min(1, max(0, jitter)))
    }
}

// MARK: - URL resolution

/// Turns a source into a stream URL. Credentials are applied here and nowhere else in playback.
public protocol StreamURLResolver: Sendable {
    func url(for source: PlaybackSource, content: PlaybackItem.Content, format: StreamFormat?) throws -> URL
    func userAgent(for providerID: ProviderID) -> String
    /// Credentials for masking URLs in logs and the diagnostics overlay.
    func redactionCredentials(for providerID: ProviderID) -> [ProviderCredentials]
}

/// Resolves URLs for Xtream providers using the stored server URL and Keychain credentials.
///
/// Read fresh for every stream (one database row and one Keychain item, well under a millisecond),
/// so an edited login or server address applies to the very next channel: a cache here once kept
/// playing with the old, expired login until the app was restarted.
public final class ProviderStreamResolver: StreamURLResolver, @unchecked Sendable {
    private let providers: ProviderRepository
    private let secrets: any SecretStore
    private let defaultUserAgent: @Sendable () -> String

    public init(database: AppDatabase, secrets: any SecretStore,
                userAgent: @escaping @Sendable () -> String = { XtreamClient.defaultUserAgent }) {
        providers = ProviderRepository(database: database)
        self.secrets = secrets
        defaultUserAgent = userAgent
    }

    private func entry(_ id: ProviderID) throws -> (Provider, ProviderCredentials) {
        guard let provider = try providers.provider(id: id) else { throw XtreamError.notFound }
        guard let credentials = try secrets.load(for: id) else { throw SourceFactoryError.missingCredentials }
        return (provider, credentials)
    }

    public func url(for source: PlaybackSource, content: PlaybackItem.Content, format: StreamFormat?) throws -> URL {
        let (provider, credentials) = try entry(source.providerID)
        let client = XtreamClient(serverURL: provider.serverURL, credentials: credentials, transport: URLSessionTransport())
        switch content {
        case .live: return client.liveURL(streamID: source.streamID ?? 0, format: format ?? .ts)
        case .movie: return client.movieURL(streamID: source.streamID ?? 0, containerExtension: source.containerExtension)
        case .episode: return client.episodeURL(episodeID: source.itemID, containerExtension: source.containerExtension)
        }
    }

    public func userAgent(for providerID: ProviderID) -> String {
        (try? entry(providerID).0.userAgentOverride) ?? defaultUserAgent()
    }

    public func redactionCredentials(for providerID: ProviderID) -> [ProviderCredentials] {
        (try? entry(providerID)).map { [$0.1] } ?? []
    }
}

// MARK: - History

/// Remembers what worked per source, feeding the fallback ladder and source ranking.
public protocol PlaybackHistoryStore: Sendable {
    func recordSuccess(_ plan: PlaybackPlan) async
    func recordFailure(_ plan: PlaybackPlan, error: EngineFailure) async
}

public struct NoPlaybackHistory: PlaybackHistoryStore {
    public init() {}
    public func recordSuccess(_ plan: PlaybackPlan) async {}
    public func recordFailure(_ plan: PlaybackPlan, error: EngineFailure) async {}
}

/// Stores history in the `playbackHistory` table (live channels only; VOD ids aren't stream ids).
public struct DatabasePlaybackHistory: PlaybackHistoryStore {
    private let database: AppDatabase
    private let clock: any AppClock

    public init(database: AppDatabase, clock: any AppClock = SystemClock()) {
        self.database = database
        self.clock = clock
    }

    public func recordSuccess(_ plan: PlaybackPlan) async {
        await update(plan) { history in
            history.successCount += 1
            history.reliabilityScore = SourceSelector.updatedReliability(history.reliabilityScore, success: true)
            history.lastWorkingFormat = plan.format ?? history.lastWorkingFormat
            history.lastWorkingEngine = plan.engine
            history.lastSuccessAt = clock.now()
        }
    }

    public func recordFailure(_ plan: PlaybackPlan, error: EngineFailure) async {
        await update(plan) { history in
            history.failureCount += 1
            history.reliabilityScore = SourceSelector.updatedReliability(history.reliabilityScore, success: false)
            history.lastFailureAt = clock.now()
            history.lastError = error.description
            // Forget a "last working" config that just failed, so the ladder starts from defaults.
            if history.lastWorkingEngine == plan.engine && history.lastWorkingFormat == plan.format {
                history.lastWorkingEngine = nil
                history.lastWorkingFormat = nil
            }
        }
    }

    private func update(_ plan: PlaybackPlan, _ change: @Sendable (inout PlaybackHistory) -> Void) async {
        guard let streamID = plan.source.streamID else { return }
        do {
            try await database.writer.write { db in
                var history = try PlaybackHistory.fetchOne(db, key: ["providerID": plan.source.providerID.rawValue, "streamID": streamID])
                    ?? PlaybackHistory(providerID: plan.source.providerID, streamID: streamID)
                change(&history)
                try history.upsert(db)
            }
        } catch {
            Log.playback.error("Couldn't save playback history: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - System events

public enum SystemEvent: Sendable, Equatable {
    case network(available: Bool)
    case willSleep
    case didWake
}

/// Network reachability and sleep/wake. macOS implementation: `MacSystemEvents` in IPTVPlayback.
public protocol SystemEventSource: Sendable {
    /// A new stream per subscriber.
    func events() -> AsyncStream<SystemEvent>
}

public struct NoSystemEvents: SystemEventSource {
    public init() {}
    public func events() -> AsyncStream<SystemEvent> { AsyncStream { _ in } }
}
