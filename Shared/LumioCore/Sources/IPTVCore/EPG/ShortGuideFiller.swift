import Foundation
import GRDB

/// Fills in the guide for channels on screen when their provider has no guide download.
///
/// Many providers don't offer the XMLTV guide file (or it fails), but still answer
/// `get_short_epg`: the next few programmes of one channel. Asking for every channel would be
/// thousands of requests, so this asks only for the channels the guide is showing, a few at a
/// time, and at most once per channel every `retryAfter`. What it finds is stored as guide
/// programmes (marked `importedAt = 0`), so the guide, now/next and search read them as usual; the
/// next guide file that imports replaces them.
///
/// Only providers whose guide download failed, or that have no guide programmes at all, are
/// asked: a provider with a working guide file is never sent these requests.
public actor ShortGuideFiller {
    private let database: AppDatabase
    private let sources: any SourceFactory
    private let clock: any AppClock
    /// When each (provider, guide ID) was last asked for, so the guide scrolling back and forth
    /// doesn't ask again.
    private var asked: [String: Date] = [:]

    /// How long before a channel is asked for again.
    public static let retryAfter: TimeInterval = 30 * 60
    /// Channels asked for per call, and at the same time.
    static let perCall = 40
    static let atOnce = 4
    /// Programmes asked for per channel (some panels give fewer).
    static let programmesPerChannel = 8

    public init(database: AppDatabase, sources: any SourceFactory, clock: any AppClock = SystemClock()) {
        self.database = database
        self.sources = sources
        self.clock = clock
    }

    /// Asks the providers of `refs` that have no guide file for what's on, for the channels that
    /// have nothing from now on. Returns true when it stored anything (the guide should re-read).
    @discardableResult
    public func fill(_ refs: [EPGRef]) async -> Bool {
        let now = clock.now()
        let wanted = (try? await work(for: refs, now: now)) ?? []
        guard !wanted.isEmpty else { return false }
        for item in wanted { asked[item.key] = now }

        var stored = false
        await withTaskGroup(of: Bool.self) { group in
            var running = 0
            for item in wanted {
                if running == Self.atOnce, let done = await group.next() {
                    stored = stored || done
                    running -= 1
                }
                group.addTask { await self.fetch(item) }
                running += 1
            }
            for await done in group { stored = stored || done }
        }
        return stored
    }

    /// One channel to ask for: its provider, the stream to ask about and the guide ID to store under.
    struct Item: Sendable {
        var provider: Provider
        var streamID: Int
        var epgID: String
        var key: String { "\(provider.id.rawValue)\u{1F}\(epgID)" }
    }

    /// The channels worth asking for: a provider without a guide file, no programme from now on,
    /// and not asked for recently.
    func work(for refs: [EPGRef], now: Date) async throws -> [Item] {
        let recent = asked.filter { now.timeIntervalSince($0.value) < Self.retryAfter }
        asked = recent
        return try await database.reader.read { db in
            var eligible: [ProviderID: Provider?] = [:]
            func provider(_ id: ProviderID) throws -> Provider? {
                if let known = eligible[id] { return known }
                var found = try Provider.fetchOne(db, key: id)
                if let candidate = found, !(try Self.lacksGuide(candidate, db)) { found = nil }
                if found?.isEnabled == false { found = nil }
                eligible[id] = found
                return found
            }
            var items: [Item] = []
            var seen = Set<String>()
            for ref in refs {
                for id in ref.providers {
                    guard items.count < Self.perCall, let p = try provider(id) else { continue }
                    let item = Item(provider: p, streamID: 0, epgID: ref.epgID)
                    guard recent[item.key] == nil, seen.insert(item.key).inserted else { continue }
                    let upcoming = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM programme WHERE providerID = ? AND epgID = ? AND stop > ?)
                        """, arguments: [id, ref.epgID, now.timeIntervalSince1970]) ?? false
                    if upcoming { continue }
                    guard let stream = try Int.fetchOne(db, sql: """
                        SELECT streamID FROM channel WHERE providerID = ? AND lower(trim(epgChannelID)) = ?
                        ORDER BY sortIndex LIMIT 1
                        """, arguments: [id, ref.epgID]) else { continue }
                    items.append(Item(provider: p, streamID: stream, epgID: ref.epgID))
                }
            }
            return items
        }
    }

    /// The provider's guide download failed last time, or it has no programmes from a guide file.
    static func lacksGuide(_ provider: Provider, _ db: Database) throws -> Bool {
        if RefreshProblems(lastError: provider.lastError).guide != nil { return true }
        let imported = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM programme WHERE providerID = ? AND importedAt > 0)",
                                         arguments: [provider.id]) ?? false
        return !imported
    }

    private func fetch(_ item: Item) async -> Bool {
        do {
            let source = try sources.source(for: item.provider)
            let programmes = try await source.fetchShortEPG(streamID: item.streamID, limit: Self.programmesPerChannel)
            guard !programmes.isEmpty else { return false }
            try await database.writer.write { db in
                let statement = try db.cachedStatement(sql: """
                    INSERT INTO programme (providerID, epgID, start, stop, title, summary, importedAt)
                    VALUES (?, ?, ?, ?, ?, ?, 0)
                    ON CONFLICT(providerID, epgID, start) DO UPDATE SET
                        stop = excluded.stop, title = excluded.title, summary = excluded.summary
                    WHERE programme.importedAt = 0
                    """)
                for programme in programmes {
                    try statement.execute(arguments: [
                        item.provider.id, item.epgID, programme.start.timeIntervalSince1970,
                        programme.stop.timeIntervalSince1970, programme.title, programme.summary,
                    ])
                }
            }
            return true
        } catch {
            let message = CredentialRedactor.redact(String(describing: error))
            Log.epg.notice("Short guide for a channel of \(item.provider.id, privacy: .public) failed: \(message, privacy: .public)")
            return false
        }
    }
}
