import Foundation

/// One way to play a logical channel: a specific provider's stream.
public struct SourceCandidate: Hashable, Sendable {
    public var providerID: ProviderID
    public var streamID: Int
    /// Provider priority (lower = preferred).
    public var providerPriority: Int
    /// 0...1, from `PlaybackHistory`; 0.5 when unknown.
    public var reliability: Double

    public init(providerID: ProviderID, streamID: Int, providerPriority: Int, reliability: Double = 0.5) {
        self.providerID = providerID
        self.streamID = streamID
        self.providerPriority = providerPriority
        self.reliability = reliability
    }
}

public struct TileAssignment: Hashable, Sendable {
    public var tile: Int
    /// nil when no provider could serve this tile.
    public var source: SourceCandidate?
}

/// Chooses which provider plays a channel, and how multiview tiles are spread across providers.
public enum SourceSelector {
    /// Orders candidates best-first: has capacity, then provider priority, then reliability.
    /// `capacity` is free slots per provider (previews counted as free); missing means 0.
    public static func rank(_ candidates: [SourceCandidate], capacity: [ProviderID: Int]) -> [SourceCandidate] {
        candidates.sorted { a, b in
            let aFree = (capacity[a.providerID] ?? 0) > 0
            let bFree = (capacity[b.providerID] ?? 0) > 0
            if aFree != bFree { return aFree }
            // A clearly unreliable source drops behind a lower-priority one.
            let aBad = a.reliability < 0.25
            let bBad = b.reliability < 0.25
            if aBad != bBad { return !aBad }
            if a.providerPriority != b.providerPriority { return a.providerPriority < b.providerPriority }
            if a.reliability != b.reliability { return a.reliability > b.reliability }
            return (a.providerID.rawValue, a.streamID) < (b.providerID.rawValue, b.streamID)
        }
    }

    /// Assigns each multiview tile a source so that as many tiles as possible play, then prefers
    /// higher-priority and more reliable sources. Tiles whose index is in `pinned` may only use that
    /// provider (a manual override).
    ///
    /// Exhaustive search: with at most 4 tiles and a handful of providers this is tiny and gives
    /// the optimal answer (e.g. 4 tiles over 2 accounts × 2 connections always fits).
    public static func assignTiles(_ tiles: [[SourceCandidate]], capacity: [ProviderID: Int],
                                   pinned: [Int: ProviderID] = [:]) -> [TileAssignment] {
        let options: [[SourceCandidate?]] = tiles.enumerated().map { index, candidates in
            let allowed = pinned[index].map { pin in candidates.filter { $0.providerID == pin } } ?? candidates
            return rank(allowed, capacity: capacity).map { Optional($0) } + [nil]
        }

        var best: [SourceCandidate?] = Array(repeating: nil, count: tiles.count)
        var bestScore = Score.worst
        var current: [SourceCandidate?] = []
        var remaining = capacity

        func search(_ index: Int) {
            if index == options.count {
                let score = Score(current)
                if score > bestScore {
                    bestScore = score
                    best = current
                }
                return
            }
            for option in options[index] {
                if let option {
                    guard (remaining[option.providerID] ?? 0) > 0 else { continue }
                    remaining[option.providerID]! -= 1
                    current.append(option)
                    search(index + 1)
                    current.removeLast()
                    remaining[option.providerID]! += 1
                } else {
                    current.append(nil)
                    search(index + 1)
                    current.removeLast()
                }
            }
        }
        search(0)
        return best.enumerated().map { TileAssignment(tile: $0.offset, source: $0.element) }
    }

    private struct Score: Comparable {
        var assigned: Int
        var priorityCost: Int
        var reliability: Double
        /// Earlier tiles get their first choice when everything else ties.
        var orderBonus: Int

        static let worst = Score(assigned: -1, priorityCost: 0, reliability: 0, orderBonus: 0)

        init(assigned: Int, priorityCost: Int, reliability: Double, orderBonus: Int) {
            self.assigned = assigned
            self.priorityCost = priorityCost
            self.reliability = reliability
            self.orderBonus = orderBonus
        }

        init(_ picks: [SourceCandidate?]) {
            assigned = picks.compactMap { $0 }.count
            priorityCost = picks.compactMap { $0?.providerPriority }.reduce(0, +)
            reliability = picks.compactMap { $0?.reliability }.reduce(0, +)
            orderBonus = picks.enumerated().reduce(0) { sum, item in
                sum + (item.element == nil ? 0 : (picks.count - item.offset))
            }
        }

        static func < (a: Score, b: Score) -> Bool {
            if a.assigned != b.assigned { return a.assigned < b.assigned }
            if a.priorityCost != b.priorityCost { return a.priorityCost > b.priorityCost }
            if abs(a.reliability - b.reliability) > 1e-9 { return a.reliability < b.reliability }
            return a.orderBonus < b.orderBonus
        }
    }

    /// Exponentially weighted reliability update after a playback attempt.
    public static func updatedReliability(_ current: Double, success: Bool, weight: Double = 0.3) -> Double {
        let target = success ? 1.0 : 0.0
        return min(1, max(0, current + weight * (target - current)))
    }
}
