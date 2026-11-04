import Foundation
import IPTVCore

/// Network and sleep events the app pushes in (`system.event` requests), for the core's playback:
/// on Android, from ConnectivityManager and from the app going to the background (the TV sleeping
/// or the user leaving) and coming back. Repeated network states are passed on once.
public final class PushedSystemEvents: SystemEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<SystemEvent>.Continuation] = [:]
    private var lastAvailable: Bool?

    public init() {}

    public func events() -> AsyncStream<SystemEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SystemEvent>.makeStream()
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
        }
        lock.withLock { continuations[id] = continuation }
        return stream
    }

    public func send(_ event: SystemEvent) {
        if case .network(let available) = event {
            let changed = lock.withLock { () -> Bool in
                defer { lastAvailable = available }
                return lastAvailable != available
            }
            guard changed else { return }
        }
        Log.playback.notice("System event: \(String(describing: event), privacy: .public)")
        lock.withLock { Array(continuations.values) }.forEach { $0.yield(event) }
    }
}
