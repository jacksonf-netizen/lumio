import Foundation

/// What the Movies and Series screens of every Lumio app do, so the Mac and Android TV apps follow
/// the same rules: details come from the provider and are kept in the catalog, a title resumes once
/// 30 seconds have been watched, and playback saves its position as it goes.
extension AppEnvironment {
    /// A movie's full details from its provider. What the catalog keeps of them (plot, duration,
    /// file type) is saved, so the next visit shows them straight away.
    public func fetchMovieDetails(providerID: ProviderID, streamID: Int) async throws -> MovieDetails {
        let details = try await source(for: providerID).fetchMovieDetails(streamID: streamID)
        try? catalog.updateMovieDetails(details, providerID: providerID, streamID: streamID)
        return details
    }

    /// A series' seasons and episodes, fetched again from its provider and saved.
    @discardableResult
    public func refreshSeriesDetails(providerID: ProviderID, seriesID: Int) async throws -> SeriesDetails {
        let details = try await source(for: providerID).fetchSeriesDetails(seriesID: seriesID)
        try catalog.replaceSeriesDetails(details, providerID: providerID, seriesID: seriesID)
        return details
    }

    private func source(for providerID: ProviderID) throws -> any SourceProvider {
        guard let provider = try providers.repository.provider(id: providerID) else { throw VODError.providerGone }
        return try sources.source(for: provider)
    }
}

public enum VODError: Error, LocalizedError {
    case providerGone

    public var errorDescription: String? {
        switch self {
        case .providerGone: "That provider no longer exists."
        }
    }
}

extension WatchProgress {
    /// Started (30 seconds or more) and not finished: Play becomes Resume.
    public var canResume: Bool { !isWatched && positionSeconds >= 30 }
}

/// Saves a movie's or episode's position while it plays: every 10 seconds and when playback stops
/// or moves on. Reaching the end marks it watched (as does the last stretch, see `saveProgress`).
/// One tracker per player; tracking a new item stops tracking the last.
@MainActor
public final class VODProgressTracker {
    private var task: Task<Void, Never>?

    public init() {}

    /// Starts tracking `item` (just handed to `controller`) and records it in Recents. `onSave`
    /// runs after each save, so screens can show the new position.
    public func track(_ item: PlaybackItem, on controller: PlaybackController, kind: LibraryItemKind,
                      providerID: ProviderID, itemID: String, library: LibraryRepository,
                      onSave: @escaping @MainActor () -> Void = {}) {
        task?.cancel()
        Task { try? await library.recordPlayed(providerID: providerID, kind: kind, itemID: itemID) }
        task = Task { @MainActor in
            var position = 0.0
            var duration: Double?
            var lastSaved = Date()
            @MainActor func save() async {
                guard position > 0 else { return }
                try? await library.saveProgress(kind: kind, providerID: providerID, itemID: itemID, position: position, duration: duration)
                onSave()
            }
            // Wait for this item to start.
            while !Task.isCancelled, controller.item?.id == item.id, controller.phase != .playing {
                try? await Task.sleep(for: .milliseconds(500))
                if case .failed = controller.phase { return }
            }
            while !Task.isCancelled, controller.item?.id == item.id {
                if let metrics = controller.metrics, let current = metrics.position, current > 0 {
                    position = current
                    duration = metrics.duration ?? duration
                }
                if controller.phase == .ended {
                    try? await library.setWatched(true, kind: kind, providerID: providerID, itemID: itemID)
                    onSave()
                    return
                }
                if controller.phase == .idle { break }
                if Date().timeIntervalSince(lastSaved) >= 10 {
                    await save()
                    lastSaved = Date()
                }
                try? await Task.sleep(for: .seconds(1))
            }
            await save()
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }
}
