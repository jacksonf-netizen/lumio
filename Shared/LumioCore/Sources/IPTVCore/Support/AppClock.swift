import Foundation

/// Time source used by anything that waits or timestamps (reconnect backoff, stall watchdog,
/// refresh scheduling). Inject a manual clock in tests so they run instantly and deterministically.
public protocol AppClock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

/// Real wall-clock time.
public struct SystemClock: AppClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
