import Foundation
import GRDB

/// Guide reads for the grid and now/next. For each channel, uses the first provider in its
/// `EPGRef.providers` that has data, otherwise whichever provider has the most; applies that
/// provider's time offset. Only the requested channels and time window are read.
public struct GuideRepository: Sendable {
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    public func programmes(for refs: [EPGRef], in window: DateInterval) async throws -> [EPGRef: [Programme]] {
        guard !refs.isEmpty else { return [:] }
        return try await database.reader.read { db in try Self.programmes(db, refs: refs, window: window) }
    }

    /// Now and next for each channel at `date`.
    public func nowNext(for refs: [EPGRef], at date: Date = Date()) async throws -> [EPGRef: NowNext] {
        let window = DateInterval(start: date, duration: 8 * 3600)
        let byRef = try await programmes(for: refs, in: window)
        var result: [EPGRef: NowNext] = [:]
        for (ref, list) in byRef {
            let now = list.first { $0.start <= date && $0.stop > date }
            let next = list.first { $0.start >= (now?.stop ?? date) }
            result[ref] = NowNext(now: now, next: next)
        }
        return result
    }

    static func programmes(_ db: Database, refs: [EPGRef], window: DateInterval) throws -> [EPGRef: [Programme]] {
        let offsets = Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id, epgTimeOffsetMinutes FROM provider")
            .map { (ProviderID($0["id"] as String), TimeInterval(($0["epgTimeOffsetMinutes"] as Int) * 60)) })
        let maxShift = offsets.values.map(abs).max() ?? 0
        let from = window.start.addingTimeInterval(-maxShift).timeIntervalSince1970
        let to = window.end.addingTimeInterval(maxShift).timeIntervalSince1970

        let ids = Array(Set(refs.map(\.epgID)))
        var byKey: [String: [ProviderID: [Programme]]] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            let rows = try Programme.fetchAll(db, sql: """
                SELECT * FROM programme INDEXED BY programme_on_epgID_start
                WHERE epgID IN (\(databaseQuestionMarks(count: chunk.count))) AND start < ? AND stop > ?
                ORDER BY epgID, start
                """, arguments: StatementArguments(chunk + [to, from]))
            for programme in rows {
                byKey[programme.epgID, default: [:]][programme.providerID, default: []].append(programme)
            }
        }

        var result: [EPGRef: [Programme]] = [:]
        for ref in refs {
            guard let candidates = byKey[ref.epgID], !candidates.isEmpty else { continue }
            let provider = ref.providers.first { candidates[$0]?.isEmpty == false }
                ?? candidates.max { $0.value.count < $1.value.count }!.key
            let shift = offsets[provider] ?? 0
            result[ref] = (candidates[provider] ?? []).compactMap { programme in
                var programme = programme
                if shift != 0 {
                    programme.start.addTimeInterval(shift)
                    programme.stop.addTimeInterval(shift)
                }
                return programme.stop > window.start && programme.start < window.end ? programme : nil
            }
        }
        return result
    }
}

public struct NowNext: Hashable, Sendable {
    public var now: Programme?
    public var next: Programme?

    public init(now: Programme?, next: Programme?) {
        self.now = now
        self.next = next
    }

    /// 0...1 through the current programme.
    public func progress(at date: Date = Date()) -> Double? {
        guard let now else { return nil }
        let total = now.stop.timeIntervalSince(now.start)
        guard total > 0 else { return nil }
        return min(1, max(0, date.timeIntervalSince(now.start) / total))
    }
}
