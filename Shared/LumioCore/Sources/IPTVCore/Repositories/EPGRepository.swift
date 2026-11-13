import Foundation
import GRDB

/// Reads guide data. Applies each provider's `epgTimeOffsetMinutes` on the way out, so the stored
/// data is never rewritten when the offset changes.
public struct EPGRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    /// Programmes overlapping `window` for the given guide channels of one provider, grouped by
    /// normalised EPG id and sorted by start. This is the guide grid's query: it touches only the
    /// visible channels and time range.
    public func programmes(providerID: ProviderID, epgIDs: [String], in window: DateInterval,
                           offsetMinutes: Int = 0) throws -> [String: [Programme]] {
        let ids = Array(Set(epgIDs.map(EPGKey.normalize)))
        guard !ids.isEmpty else { return [:] }
        let shift = TimeInterval(offsetMinutes * 60)
        // Stored times are unshifted, so shift the window the other way.
        let from = window.start.addingTimeInterval(-shift).timeIntervalSince1970
        let to = window.end.addingTimeInterval(-shift).timeIntervalSince1970

        // A guide link's programmes (`source` 1) keep their own times. The window is widened by the
        // shift, so either kind is found; the final filter trims what the shift took out of range.
        let rows = try database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM programme
                WHERE providerID = ? AND epgID IN (\(databaseQuestionMarks(count: ids.count)))
                  AND stop > ? AND start < ?
                ORDER BY epgID, start
                """, arguments: StatementArguments([providerID.rawValue] + ids + [min(from, window.start.timeIntervalSince1970),
                                                                                   max(to, window.end.timeIntervalSince1970)]))
                .map { (try Programme(row: $0), ($0["source"] as Int? ?? 0) == 0) }
        }
        var grouped: [String: [Programme]] = [:]
        for (programmeRow, shifted) in rows {
            var programme = programmeRow
            if shift != 0, shifted {
                programme.start.addTimeInterval(shift)
                programme.stop.addTimeInterval(shift)
            }
            guard programme.stop > window.start, programme.start < window.end else { continue }
            grouped[programme.epgID, default: []].append(programme)
        }
        return grouped
    }

    /// The programme on now and the one after it.
    public func nowAndNext(providerID: ProviderID, epgID: String, at date: Date = Date(),
                           offsetMinutes: Int = 0) throws -> (now: Programme?, next: Programme?) {
        let list = try programmes(providerID: providerID, epgIDs: [epgID],
                                  in: DateInterval(start: date, duration: 12 * 3600),
                                  offsetMinutes: offsetMinutes)[EPGKey.normalize(epgID)] ?? []
        let now = list.first { $0.start <= date && $0.stop > date }
        let next = list.first { $0.start >= (now?.stop ?? date) }
        return (now, next)
    }

    public func programmeCount(providerID: ProviderID) throws -> Int {
        try database.reader.read { db in
            try Programme.filter(Column("providerID") == providerID.rawValue).fetchCount(db)
        }
    }

    /// All guide channels a provider publishes (for manual EPG matching).
    public func guideChannels(providerID: ProviderID) throws -> [EPGChannel] {
        try database.reader.read { db in
            try EPGChannel.filter(Column("providerID") == providerID.rawValue)
                .order(Column("displayName"))
                .fetchAll(db)
        }
    }
}
