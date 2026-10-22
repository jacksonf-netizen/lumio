import Foundation
import Testing
@testable import IPTVCore

@Suite("Source selection and multiview tile assignment")
struct SourceSelectorTests {
    let a = ProviderID("a")
    let b = ProviderID("b")
    let c = ProviderID("c")

    func candidate(_ p: ProviderID, _ stream: Int, priority: Int, reliability: Double = 0.5) -> SourceCandidate {
        SourceCandidate(providerID: p, streamID: stream, providerPriority: priority, reliability: reliability)
    }

    @Test func ranksFreeSlotsThenPriorityThenReliability() {
        let ranked = SourceSelector.rank([
            candidate(a, 1, priority: 0),
            candidate(b, 2, priority: 1, reliability: 0.9),
            candidate(c, 3, priority: 2, reliability: 0.95),
        ], capacity: [a: 0, b: 1, c: 1])
        #expect(ranked.map(\.providerID) == [b, c, a])
    }

    @Test func unreliableSourcesDropBehind() {
        let ranked = SourceSelector.rank([
            candidate(a, 1, priority: 0, reliability: 0.1),
            candidate(b, 2, priority: 1, reliability: 0.6),
        ], capacity: [a: 1, b: 1])
        #expect(ranked.first?.providerID == b)
    }

    @Test func fourTilesOverTwoAccountsWithTwoConnectionsEachJustWorks() {
        // Every channel is available on both providers.
        let tiles = (0..<4).map { i in [candidate(a, i, priority: 0), candidate(b, 100 + i, priority: 1)] }
        let result = SourceSelector.assignTiles(tiles, capacity: [a: 2, b: 2])
        #expect(result.allSatisfy { $0.source != nil })
        #expect(result.filter { $0.source?.providerID == a }.count == 2)
        #expect(result.filter { $0.source?.providerID == b }.count == 2)
        // Earlier tiles get the preferred provider when it's a tie.
        #expect(result[0].source?.providerID == a)
    }

    @Test func assignmentMaximisesPlayingTilesNotGreedyChoice() {
        // Tile 0 could use a or b; tile 1 only exists on a. Greedy would give tile 0 provider a and
        // leave tile 1 dark.
        let result = SourceSelector.assignTiles([
            [candidate(a, 1, priority: 0), candidate(b, 2, priority: 1)],
            [candidate(a, 3, priority: 0)],
        ], capacity: [a: 1, b: 1])
        #expect(result[0].source?.providerID == b)
        #expect(result[1].source?.providerID == a)
    }

    @Test func reportsTilesThatCannotBeServed() {
        let result = SourceSelector.assignTiles([
            [candidate(a, 1, priority: 0)], [candidate(a, 2, priority: 0)], [candidate(a, 3, priority: 0)],
        ], capacity: [a: 2])
        #expect(result.filter { $0.source == nil }.count == 1)
        #expect(result[2].source == nil)
    }

    @Test func pinnedTilesOnlyUseTheirProvider() {
        let tiles = [[candidate(a, 1, priority: 0), candidate(b, 2, priority: 1)]]
        let result = SourceSelector.assignTiles(tiles, capacity: [a: 1, b: 1], pinned: [0: b])
        #expect(result[0].source?.providerID == b)
        let blocked = SourceSelector.assignTiles(tiles, capacity: [a: 1, b: 0], pinned: [0: b])
        #expect(blocked[0].source == nil)
    }

    @Test func reliabilityMovesTowardsOutcomes() {
        var r = 0.5
        for _ in 0..<10 { r = SourceSelector.updatedReliability(r, success: false) }
        #expect(r < 0.05)
        for _ in 0..<10 { r = SourceSelector.updatedReliability(r, success: true) }
        #expect(r > 0.95)
    }
}
