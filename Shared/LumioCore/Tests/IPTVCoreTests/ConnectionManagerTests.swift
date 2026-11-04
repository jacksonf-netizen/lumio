import Foundation
import Testing
@testable import IPTVCore

@Suite("Connection slot accounting")
struct ConnectionManagerTests {
    let a = ProviderID("provider-a")
    let b = ProviderID("provider-b")

    @Test func respectsTheLimitAndFreesOnRelease() async throws {
        let manager = ConnectionManager()
        await manager.setLimit(2, for: a)
        let first = try await manager.acquire(a, purpose: .main)
        let second = try await manager.acquire(a, purpose: .tile(1))
        await #expect(throws: ConnectionError.noFreeSlot(providerID: a, inUse: 2, limit: 2)) {
            try await manager.acquire(a, purpose: .tile(2))
        }
        await manager.release(first)
        let third = try await manager.acquire(a, purpose: .tile(2))
        await manager.release(second)
        await manager.release(third)
        #expect(await manager.totalInUse == 0)
    }

    @Test func unknownLimitDefaultsToOneAndZeroMeansUnknown() async throws {
        let manager = ConnectionManager()
        #expect(await manager.limit(for: a) == 1)
        await manager.setLimit(0, for: a)
        #expect(await manager.limit(for: a) == 1)
        await manager.setLimit(nil, for: a)
        #expect(await manager.limit(for: a) == 1)
    }

    @Test func doubleReleaseIsHarmless() async throws {
        let manager = ConnectionManager()
        await manager.setLimit(2, for: a)
        let lease = try await manager.acquire(a, purpose: .main)
        let other = try await manager.acquire(a, purpose: .tile(0))
        await manager.release(lease)
        await manager.release(lease)
        #expect(await manager.usage(for: a).inUse == 1)
        #expect(await manager.isHeld(other))
    }

    @Test func mainPlaybackPreemptsThePreviewAndWaitsForItToStop() async throws {
        let manager = ConnectionManager()
        await manager.setLimit(1, for: a)
        let stopped = Flag()
        let preview = try await manager.acquire(a, purpose: .preview) {
            try? await Task.sleep(for: .milliseconds(20))
            stopped.set()
        }
        let main = try await manager.acquire(a, purpose: .main)
        // The preview's stream was closed before the main lease was handed out.
        #expect(stopped.isSet)
        #expect(!(await manager.isHeld(preview)))
        #expect(await manager.isHeld(main))
        // The preview's late release must not free the main stream's slot.
        await manager.release(preview)
        #expect(await manager.usage(for: a).inUse == 1)
    }

    @Test func aPreviewNeverPreemptsAnything() async throws {
        let manager = ConnectionManager()
        await manager.setLimit(1, for: a)
        _ = try await manager.acquire(a, purpose: .preview)
        await #expect(throws: ConnectionError.self) { try await manager.acquire(a, purpose: .preview) }
    }

    @Test func firstAvailablePrefersFreeSlotsOverPreempting() async throws {
        let manager = ConnectionManager()
        await manager.setLimit(1, for: a)
        await manager.setLimit(1, for: b)
        let preemptedA = Flag()
        _ = try await manager.acquire(a, purpose: .preview) { preemptedA.set() }
        let lease = try await manager.acquireFirstAvailable([a, b], purpose: .main)
        #expect(lease.providerID == b)
        #expect(!preemptedA.isSet)
    }

    @Test func firstAvailableFailsClearlyWhenEverythingIsFull() async throws {
        let manager = ConnectionManager()
        _ = try await manager.acquire(a, purpose: .main)
        _ = try await manager.acquire(b, purpose: .main)
        await #expect(throws: ConnectionError.noProviderAvailable) {
            try await manager.acquireFirstAvailable([a, b], purpose: .tile(1))
        }
    }

    @Test func rapidConcurrentZappingNeverLeaksOrOverbooks() async throws {
        let manager = ConnectionManager()
        await manager.setLimit(2, for: a)
        let overbooked = Flag()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<500 {
                group.addTask {
                    let purpose: ConnectionPurpose = i % 5 == 0 ? .preview : .tile(i % 4)
                    guard let lease = try? await manager.acquire(a, purpose: purpose) else { return }
                    if await manager.usage(for: a).inUse > 2 { overbooked.set() }
                    await Task.yield()
                    await manager.release(lease)
                }
            }
        }
        #expect(!overbooked.isSet)
        #expect(await manager.totalInUse == 0)
    }

    @Test func removingAProviderDropsItsLeases() async throws {
        let manager = ConnectionManager()
        _ = try await manager.acquire(a, purpose: .main)
        await manager.removeProvider(a)
        #expect(await manager.totalInUse == 0)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
