import Foundation

/// What a stream connection is used for.
public enum ConnectionPurpose: Hashable, Sendable, CustomStringConvertible {
    case main
    /// The small live preview in the channel list. Preemptible: it gives up its slot when main
    /// playback or a multiview tile needs one.
    case preview
    case tile(Int)

    public var description: String {
        switch self {
        case .main: "main"
        case .preview: "preview"
        case .tile(let n): "tile \(n)"
        }
    }

    var isPreemptible: Bool { self == .preview }
}

/// Proof that a connection slot is held. Release it exactly once with `ConnectionManager.release`.
public struct ConnectionLease: Hashable, Sendable, CustomStringConvertible {
    public let id: UUID
    public let providerID: ProviderID
    public let purpose: ConnectionPurpose

    public var description: String { "lease \(id.uuidString.prefix(8)) [\(providerID) \(purpose)]" }
}

public enum ConnectionError: Error, Equatable, Sendable, CustomStringConvertible {
    case noFreeSlot(providerID: ProviderID, inUse: Int, limit: Int)
    case noProviderAvailable

    public var description: String {
        switch self {
        case .noFreeSlot(_, let inUse, let limit):
            "All \(limit) connection\(limit == 1 ? "" : "s") for this provider are in use (\(inUse) open in this app)."
        case .noProviderAvailable:
            "No provider has a free connection. Close a stream or a multiview tile, or add another provider."
        }
    }
}

/// Usage of one provider's connection slots.
public struct ConnectionUsage: Sendable, Equatable {
    public var limit: Int
    public var inUse: Int
    public var purposes: [ConnectionPurpose]

    public var free: Int { max(0, limit - inUse) }

    public init(limit: Int, inUse: Int, purposes: [ConnectionPurpose]) {
        self.limit = limit
        self.inUse = inUse
        self.purposes = purposes
    }
}

/// Tracks open streams per provider against each provider's `max_connections`. Every playback
/// request (main player, preview, multiview tile) must hold a lease from here while its stream is
/// open, so a single-connection account never gets a second concurrent stream from this app.
///
/// The provider-reported `active_cons` is not trusted for our own streams (it lags); our own count
/// is authoritative, and `max_connections` is the ceiling.
public actor ConnectionManager {
    /// Called to stop a preemptible stream. It must close the stream before returning.
    public typealias PreemptionHandler = @Sendable () async -> Void

    private struct Held {
        let lease: ConnectionLease
        let onPreempt: PreemptionHandler?
    }

    private var limits: [ProviderID: Int] = [:]
    private var held: [ProviderID: [Held]] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Used when a provider hasn't reported `max_connections` yet.
    public let defaultLimit: Int

    public init(defaultLimit: Int = 1) {
        self.defaultLimit = max(1, defaultLimit)
    }

    // MARK: Limits

    /// Sets the provider's connection ceiling. nil or values below 1 fall back to `defaultLimit`.
    public func setLimit(_ limit: Int?, for providerID: ProviderID) {
        let value = (limit ?? 0) >= 1 ? limit! : defaultLimit
        limits[providerID] = value
        Log.connections.info("Limit for \(providerID, privacy: .public) = \(value)")
        notifyChange()
    }

    public func removeProvider(_ providerID: ProviderID) {
        limits[providerID] = nil
        held[providerID] = nil
        notifyChange()
    }

    public func limit(for providerID: ProviderID) -> Int {
        limits[providerID] ?? defaultLimit
    }

    // MARK: Acquire / release

    /// Takes a slot on `providerID`. If none is free and the request isn't itself a preview, a
    /// preview on that provider is preempted: its slot is reassigned immediately and its handler is
    /// awaited, so the preview's stream is closed before this call returns.
    public func acquire(_ providerID: ProviderID, purpose: ConnectionPurpose,
                        onPreempt: PreemptionHandler? = nil) async throws -> ConnectionLease {
        let limit = limit(for: providerID)
        var list = held[providerID] ?? []
        let lease = ConnectionLease(id: UUID(), providerID: providerID, purpose: purpose)

        if list.count < limit {
            list.append(Held(lease: lease, onPreempt: onPreempt))
            held[providerID] = list
            log("acquired", lease)
            notifyChange()
            return lease
        }

        guard !purpose.isPreemptible,
              let victimIndex = list.firstIndex(where: { $0.lease.purpose.isPreemptible })
        else {
            Log.connections.notice("No free slot on \(providerID, privacy: .public) for \(purpose.description, privacy: .public) (\(list.count)/\(limit))")
            throw ConnectionError.noFreeSlot(providerID: providerID, inUse: list.count, limit: limit)
        }

        // Swap the slot over before awaiting, so no other request can take it in between.
        let victim = list.remove(at: victimIndex)
        list.append(Held(lease: lease, onPreempt: onPreempt))
        held[providerID] = list
        log("preempting \(victim.lease) for", lease)
        notifyChange()
        await victim.onPreempt?()
        return lease
    }

    /// Like `acquire`, but tries each provider in order and returns the first lease obtained.
    public func acquireFirstAvailable(_ providerIDs: [ProviderID], purpose: ConnectionPurpose,
                                      onPreempt: PreemptionHandler? = nil) async throws -> ConnectionLease {
        // First pass: providers with a genuinely free slot, so we don't preempt needlessly.
        for id in providerIDs where free(on: id) > 0 {
            if let lease = try? await acquire(id, purpose: purpose, onPreempt: onPreempt) { return lease }
        }
        for id in providerIDs {
            if let lease = try? await acquire(id, purpose: purpose, onPreempt: onPreempt) { return lease }
        }
        throw ConnectionError.noProviderAvailable
    }

    /// Returns the slot. Releasing an unknown or already-released lease is a harmless no-op (a
    /// preempted lease has already been reassigned).
    public func release(_ lease: ConnectionLease) {
        guard var list = held[lease.providerID],
              let index = list.firstIndex(where: { $0.lease.id == lease.id })
        else { return }
        list.remove(at: index)
        held[lease.providerID] = list
        log("released", lease)
        notifyChange()
    }

    public func isHeld(_ lease: ConnectionLease) -> Bool {
        held[lease.providerID]?.contains { $0.lease.id == lease.id } ?? false
    }

    // MARK: Queries

    public func free(on providerID: ProviderID) -> Int {
        max(0, limit(for: providerID) - (held[providerID]?.count ?? 0))
    }

    /// Free slots counting preemptible previews as free.
    public func available(on providerID: ProviderID) -> Int {
        let list = held[providerID] ?? []
        return max(0, limit(for: providerID) - list.filter { !$0.lease.purpose.isPreemptible }.count)
    }

    public func usage(for providerID: ProviderID) -> ConnectionUsage {
        let list = held[providerID] ?? []
        return ConnectionUsage(limit: limit(for: providerID), inUse: list.count, purposes: list.map(\.lease.purpose))
    }

    public func snapshot() -> [ProviderID: ConnectionUsage] {
        var result: [ProviderID: ConnectionUsage] = [:]
        for id in Set(limits.keys).union(held.keys) { result[id] = usage(for: id) }
        return result
    }

    public var totalInUse: Int { held.values.reduce(0) { $0 + $1.count } }

    /// Suspends until the next change in usage. For UI that shows live connection counts.
    public func waitForChange() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    private func notifyChange() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func log(_ action: String, _ lease: ConnectionLease) {
        let usage = usage(for: lease.providerID)
        Log.connections.debug("\(action, privacy: .public) \(lease.description, privacy: .public) → \(usage.inUse)/\(usage.limit)")
    }
}
