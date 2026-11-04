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
                try db.execute(sql: "DELETE FROM programme WHERE providerID = ? AND importedAt < ?",
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
                    importedAt = excluded.importedAt
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
