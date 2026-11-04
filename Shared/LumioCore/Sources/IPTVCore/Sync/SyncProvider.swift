import Foundation

/// A category of user data that changed locally and may need syncing.
public enum SyncChange: String, Sendable, CaseIterable {
    case providers
    case favorites
    case channelLayout
    case watchProgress
    case settings
}

/// Hook for a future account / cloud sync service. Repositories report local changes here and
/// feature code never talks to sync directly. v1 ships only `LocalOnlySyncProvider`.
public protocol SyncProvider: Sendable {
    /// Called after a local change is committed.
    func localDataDidChange(_ change: SyncChange) async
    /// Fetch and apply remote changes, if any.
    func pull() async throws
}

/// Does nothing: the app is fully local in v1.
public struct LocalOnlySyncProvider: SyncProvider {
    public init() {}
    public func localDataDidChange(_ change: SyncChange) async {}
    public func pull() async throws {}
}
