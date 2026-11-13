import Foundation
import GRDB

/// How much guide data to keep, relative to now.
public struct EPGWindow: Sendable, Equatable {
    public var pastDays: Double
    public var futureDays: Double

    public init(pastDays: Double = 1, futureDays: Double = 7) {
        self.pastDays = pastDays
        self.futureDays = futureDays
    }

    func range(around now: Date) -> ClosedRange<Date> {
        now.addingTimeInterval(-pastDays * 86_400)...now.addingTimeInterval(futureDays * 86_400)
    }
}

public struct EPGImportSummary: Sendable, Equatable {
    public var channels = 0
    public var programmesParsed = 0
    public var programmesStored = 0
    public var skipped = 0
    public var removedStale = 0
    public var pruned = 0
    /// Set when the file was only partly readable. Everything before the problem was imported.
    public var partialError: String?
    public var duration: Duration = .zero
}

/// Imports an XMLTV file into the database in the background, in batched transactions, without
/// ever loading the whole guide into memory. The UI keeps reading the previous data (WAL) until
/// each batch commits.
public struct EPGImporter: Sendable {
    private let database: AppDatabase
    private let clock: any AppClock
    private let batchSize: Int

    public init(database: AppDatabase, clock: any AppClock = SystemClock(), batchSize: Int = 5_000) {
        self.database = database
        self.clock = clock
        self.batchSize = batchSize
    }

    /// Imports `file` (gzip or plain XML) for `providerID`. `progress` receives the running count of
    /// parsed programmes.
    public func importGuide(file: URL, providerID: ProviderID, window: EPGWindow = EPGWindow(),
                            progress: (@Sendable (Int) -> Void)? = nil) async throws -> EPGImportSummary {
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let summary = try runImport(file: file, providerID: providerID, window: window,
                                                    cancel: cancel, progress: progress)
                        continuation.resume(returning: summary)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancel.cancel()
        }
    }

    /// Deletes programmes that ended before the window, for all providers.
    @discardableResult
    public func prune(window: EPGWindow = EPGWindow()) throws -> Int {
        let cutoff = window.range(around: clock.now()).lowerBound
        return try database.writer.write { db in
            try db.execute(sql: "DELETE FROM programme WHERE stop < ?", arguments: [cutoff.timeIntervalSince1970])
            return db.changesCount
        }
    }

    // MARK: Implementation (runs on a background queue)

    private func runImport(file: URL, providerID: ProviderID, window: EPGWindow, cancel: CancelFlag,
                           progress: (@Sendable (Int) -> Void)?) throws -> EPGImportSummary {
        let started = ContinuousClock.now
        let importStamp = clock.now()
        let range = window.range(around: importStamp)

        let staged = try XMLTVStaging.stage(file)
        defer { try? FileManager.default.removeItem(at: staged) }
        if cancel.isCancelled { throw CancellationError() }

        let wanted = try referencedEPGIDs(for: providerID)
        Log.epg.info("Importing guide for \(providerID, privacy: .public); \(wanted.count) referenced channel ids")

        var summary = EPGImportSummary()
        var programmeBatch: [XMLTVProgramme] = []
        programmeBatch.reserveCapacity(batchSize)
        var channelBatch: [XMLTVChannel] = []
        var writeError: Error?

        func flushProgrammes() {
            guard !programmeBatch.isEmpty, writeError == nil else { return }
            do {
                try writeProgrammes(programmeBatch, providerID: providerID, stamp: importStamp)
                summary.programmesStored += programmeBatch.count
            } catch {
                writeError = error
            }
            programmeBatch.removeAll(keepingCapacity: true)
        }

        func flushChannels() {
            guard !channelBatch.isEmpty, writeError == nil else { return }
            do { try writeChannels(channelBatch, providerID: providerID) } catch { writeError = error }
            channelBatch.removeAll(keepingCapacity: true)
        }

        let parser = XMLTVParser(
            onChannel: { channel in
                channelBatch.append(channel)
                if channelBatch.count >= 1_000 { flushChannels() }
            },
            onProgramme: { programme in
                summary.programmesParsed += 1
                guard programme.stop >= range.lowerBound, programme.start <= range.upperBound else { return }
                if !wanted.isEmpty, !wanted.contains(EPGKey.normalize(programme.channel)) { return }
                programmeBatch.append(programme)
                if programmeBatch.count >= batchSize {
                    flushProgrammes()
                    progress?(summary.programmesParsed)
                }
            },
            shouldContinue: { !cancel.isCancelled && writeError == nil })

        let result = parser.parse(fileAt: staged)
        flushChannels()
        flushProgrammes()
        if let writeError { throw writeError }
        if cancel.isCancelled { throw CancellationError() }

        summary.channels = result.channels
        summary.skipped = result.skipped
        summary.partialError = result.error
        progress?(summary.programmesParsed)

        try database.writer.write { db in
            // Only a complete import may remove rows: a partial file would wipe good data.
            if result.error == nil, summary.programmesStored > 0 {
                // Programmes from guide links (source 1) are the link import's to replace.
                try db.execute(sql: "DELETE FROM programme WHERE providerID = ? AND source = 0 AND importedAt < ?",
                               arguments: [providerID, importStamp.timeIntervalSince1970])
                summary.removedStale = db.changesCount
            }
            try db.execute(sql: "DELETE FROM programme WHERE stop < ?",
                           arguments: [range.lowerBound.timeIntervalSince1970])
            summary.pruned = db.changesCount
        }

        summary.duration = ContinuousClock.now - started
        Log.epg.info("""
            Guide import for \(providerID, privacy: .public): parsed \(summary.programmesParsed), \
            stored \(summary.programmesStored), stale \(summary.removedStale), pruned \(summary.pruned), \
            in \(summary.duration.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)\
            \(summary.partialError.map { " (partial: \($0))" } ?? "", privacy: .public)
            """)
        return summary
    }

    /// EPG ids any channel might show: every provider's channels (so one provider's guide can serve
    /// another's channels) plus manual overrides pointing at this provider's guide.
    private func referencedEPGIDs(for providerID: ProviderID) throws -> Set<String> {
        try database.reader.read { db in
            var ids = Set(try String.fetchAll(db, sql: "SELECT DISTINCT epgChannelID FROM channel WHERE epgChannelID IS NOT NULL"))
            ids.formUnion(try String.fetchAll(db, sql: "SELECT epgID FROM epgMappingOverride WHERE epgProviderID = ?",
                                              arguments: [providerID]))
            ids.formUnion(try String.fetchAll(db, sql: "SELECT epgID FROM logicalEPGOverride WHERE epgProviderID = ?",
                                              arguments: [providerID]))
            return Set(ids.map(EPGKey.normalize))
        }
    }

    private func writeProgrammes(_ batch: [XMLTVProgramme], providerID: ProviderID, stamp: Date) throws {
        try database.writer.write { db in
            let statement = try db.cachedStatement(sql: """
                INSERT INTO programme
                    (providerID, epgID, start, stop, title, subtitle, summary, category, episodeNumber, iconURL, importedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(providerID, epgID, start) DO UPDATE SET
                    stop = excluded.stop, title = excluded.title, subtitle = excluded.subtitle,
                    summary = excluded.summary, category = excluded.category,
                    episodeNumber = excluded.episodeNumber, iconURL = excluded.iconURL,
                    importedAt = excluded.importedAt, source = 0
                """)
            let stampValue = stamp.timeIntervalSince1970
            for p in batch {
                try statement.execute(arguments: [
                    providerID, EPGKey.normalize(p.channel), p.start.timeIntervalSince1970, p.stop.timeIntervalSince1970,
                    p.title, p.subtitle, p.summary, p.category, p.episodeNumber, p.iconURL?.absoluteString, stampValue,
                ])
            }
        }
    }

    private func writeChannels(_ batch: [XMLTVChannel], providerID: ProviderID) throws {
        try database.writer.write { db in
            for channel in batch {
                try EPGChannel(providerID: providerID, epgID: EPGKey.normalize(channel.id),
                               displayName: channel.displayName, iconURL: channel.iconURL).upsert(db)
            }
        }
    }
}

/// Thread-safe cancellation flag shared between a Task and a background queue.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

// MARK: - Guide links

/// What importing a provider's guide links did.
public struct GuideLinkImportSummary: Sendable, Equatable {
    /// The provider's guide IDs that got programmes from a link.
    public var matchedChannels = 0
    public var programmesStored = 0
    public var removedStale = 0
    /// A link that could only be partly read, and why.
    public var partialErrors: [String] = []
    public var duration: Duration = .zero
}

extension EPGImporter {
    /// Imports guide links (`GuideLinkStore`) for `providerID`'s channels that its own guide leaves
    /// out. Programmes are stored under the provider with `source = 1`, matched to its channels by
    /// guide ID, else by name and region, else by a name only one of its channels has. The provider's
    /// own guide always wins, and its imports never remove these rows. Rows from an earlier link
    /// import are removed only when `complete` (every link downloaded) and each file read whole.
    public func importGuideLinks(files: [URL], providerID: ProviderID, window: EPGWindow = EPGWindow(),
                                 complete: Bool) async throws -> GuideLinkImportSummary {
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(returning: try runLinkImport(files: files, providerID: providerID, window: window,
                                                                         complete: complete, cancel: cancel))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancel.cancel()
        }
    }

    /// The provider's guide IDs a link may fill, by how they can be matched.
    struct LinkTargets {
        /// Guide IDs with no programmes from the provider's own guide.
        var ids: Set<String> = []
        /// Normalised name + "|" + region → those IDs.
        var byNameAndRegion: [String: Set<String>] = [:]
        /// Normalised name → those IDs (used only when there's exactly one).
        var byName: [String: Set<String>] = [:]
    }

    func linkTargets(providerID: ProviderID) throws -> LinkTargets {
        try database.reader.read { db in
            let covered = Set(try String.fetchAll(db, sql: """
                SELECT DISTINCT epgID FROM programme WHERE providerID = ? AND source = 0 AND importedAt > 0
                """, arguments: [providerID]))
            let rows = try Row.fetchAll(db, sql: """
                SELECT c.name, c.epgChannelID, cat.region FROM channel c
                LEFT JOIN category cat ON cat.providerID = c.providerID AND cat.kind = 'live' AND cat.categoryID = c.categoryID
                WHERE c.providerID = ? AND c.epgChannelID IS NOT NULL AND trim(c.epgChannelID) <> ''
                """, arguments: [providerID])
            var targets = LinkTargets()
            for row in rows {
                let id = EPGKey.normalize(row["epgChannelID"] as String)
                guard !covered.contains(id) else { continue }
                targets.ids.insert(id)
                let channelName: String = row["name"]
                let name = ChannelMatcher.normalizedName(channelName)
                guard !name.isEmpty else { continue }
                targets.byName[name, default: []].insert(id)
                if let region = (row["region"] as String?) ?? RegionPrefix.detect(channelName) {
                    targets.byNameAndRegion[name + "|" + region, default: []].insert(id)
                }
            }
            return targets
        }
    }

    /// Which of the provider's guide IDs each of a link's channels fills (link channel ID, normalised).
    static func matchLinkChannels(_ channels: [XMLTVChannel], to targets: LinkTargets, claimed: inout Set<String>) -> [String: [String]] {
        var map: [String: [String]] = [:]
        var rest: [(id: String, name: String, region: String?)] = []
        // 1. The same guide ID.
        for channel in channels {
            let id = EPGKey.normalize(channel.id)
            if targets.ids.contains(id), !claimed.contains(id) {
                map[id] = [id]
                claimed.insert(id)
            } else if map[id] == nil, let display = channel.displayName {
                rest.append((id, ChannelMatcher.normalizedName(display), linkRegion(id: channel.id, name: display)))
            }
        }
        // 2. Name and region, else a name only one of the provider's channels has. A name two of the
        // link's channels share ("FOX (Boston)" and "FOX (Denver)" both read "fox") is left out.
        var seen: [String: Int] = [:]
        for channel in rest where !channel.name.isEmpty { seen[channel.name + "|" + (channel.region ?? ""), default: 0] += 1 }
        for channel in rest where !channel.name.isEmpty && seen[channel.name + "|" + (channel.region ?? "")] == 1 {
            var found: Set<String> = []
            if let region = channel.region {
                found = targets.byNameAndRegion[channel.name + "|" + region] ?? []
            } else if let only = targets.byName[channel.name], only.count == 1 {
                found = only
            }
            let free = found.subtracting(claimed)
            guard !free.isEmpty else { continue }
            map[channel.id] = free.sorted()
            claimed.formUnion(free)
        }
        return map
    }

    /// A link channel's region: the country at the end of its ID ("ESPN.us" → US), else a prefix
    /// on its name ("US: ESPN").
    static func linkRegion(id: String, name: String) -> String? {
        if let dot = id.lastIndex(of: ".") {
            let suffix = id[id.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            if (2...3).contains(suffix.count), suffix.allSatisfy(\.isLetter) {
                return RegionPrefix.key(forPrefix: suffix.uppercased())
            }
        }
        return RegionPrefix.detect(name)
    }

    private func runLinkImport(files: [URL], providerID: ProviderID, window: EPGWindow, complete: Bool,
                               cancel: CancelFlag) throws -> GuideLinkImportSummary {
        let started = ContinuousClock.now
        let stamp = clock.now()
        let range = window.range(around: stamp)
        let targets = try linkTargets(providerID: providerID)
        var summary = GuideLinkImportSummary()
        var claimed: Set<String> = []
        var allWhole = complete

        for file in files {
            if cancel.isCancelled { throw CancellationError() }
            let staged = try XMLTVStaging.stage(file)
            defer { try? FileManager.default.removeItem(at: staged) }
            // XMLTV lists its channels before its programmes: they're matched once, at the first programme.
            var channels: [XMLTVChannel] = []
            var map: [String: [String]]?
            var batch: [(String, XMLTVProgramme)] = []
            var writeError: Error?
            func flush() {
                guard !batch.isEmpty, writeError == nil else { return }
                do {
                    try writeLinkProgrammes(batch, providerID: providerID, stamp: stamp)
                    summary.programmesStored += batch.count
                } catch {
                    writeError = error
                }
                batch.removeAll(keepingCapacity: true)
            }
            let parser = XMLTVParser(
                onChannel: { channels.append($0) },
                onProgramme: { programme in
                    if map == nil {
                        map = Self.matchLinkChannels(channels, to: targets, claimed: &claimed)
                        channels = []
                    }
                    guard let ids = map?[EPGKey.normalize(programme.channel)],
                          programme.stop >= range.lowerBound, programme.start <= range.upperBound else { return }
                    for id in ids { batch.append((id, programme)) }
                    if batch.count >= batchSize { flush() }
                },
                shouldContinue: { !cancel.isCancelled && writeError == nil })
            let result = parser.parse(fileAt: staged)
            flush()
            if let writeError { throw writeError }
            if cancel.isCancelled { throw CancellationError() }
            if let error = result.error {
                allWhole = false
                summary.partialErrors.append(error)
            }
        }
        summary.matchedChannels = claimed.count

        try database.writer.write { db in
            if allWhole, summary.programmesStored > 0 {
                try db.execute(sql: "DELETE FROM programme WHERE providerID = ? AND source = 1 AND importedAt < ?",
                               arguments: [providerID, stamp.timeIntervalSince1970])
                summary.removedStale = db.changesCount
            }
            // Channels the provider's own guide covers now are its own again.
            try db.execute(sql: """
                DELETE FROM programme WHERE providerID = ? AND source = 1 AND epgID IN (
                    SELECT DISTINCT epgID FROM programme WHERE providerID = ? AND source = 0 AND importedAt > 0)
                """, arguments: [providerID, providerID])
        }
        summary.duration = ContinuousClock.now - started
        Log.epg.info("""
            Guide links for \(providerID, privacy: .public): \(files.count) files, \(summary.matchedChannels) channels matched, \
            stored \(summary.programmesStored), stale \(summary.removedStale), \
            in \(summary.duration.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)
            """)
        return summary
    }

    /// Link programmes never overwrite the provider's own (`source = 0` from its guide file); they
    /// do replace short-guide rows (`importedAt = 0`) and earlier link rows.
    private func writeLinkProgrammes(_ batch: [(String, XMLTVProgramme)], providerID: ProviderID, stamp: Date) throws {
        try database.writer.write { db in
            let statement = try db.cachedStatement(sql: """
                INSERT INTO programme
                    (providerID, epgID, start, stop, title, subtitle, summary, category, episodeNumber, iconURL, importedAt, source)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
                ON CONFLICT(providerID, epgID, start) DO UPDATE SET
                    stop = excluded.stop, title = excluded.title, subtitle = excluded.subtitle,
                    summary = excluded.summary, category = excluded.category,
                    episodeNumber = excluded.episodeNumber, iconURL = excluded.iconURL,
                    importedAt = excluded.importedAt, source = 1
                WHERE programme.source = 1 OR programme.importedAt = 0
                """)
            let stampValue = stamp.timeIntervalSince1970
            for (id, p) in batch {
                try statement.execute(arguments: [
                    providerID, id, p.start.timeIntervalSince1970, p.stop.timeIntervalSince1970,
                    p.title, p.subtitle, p.summary, p.category, p.episodeNumber, p.iconURL?.absoluteString, stampValue,
                ])
            }
        }
    }
}
