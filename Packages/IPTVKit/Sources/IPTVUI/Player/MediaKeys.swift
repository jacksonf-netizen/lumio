import Foundation
import MediaPlayer
import IPTVCore

/// Hardware media keys and the Now Playing widget: play/pause, and next/previous track change channel.
@MainActor
final class MediaKeys {
    static let shared = MediaKeys()

    private weak var state: AppState?
    private var registered = false

    func attach(_ state: AppState) {
        self.state = state
        guard !registered else { return }
        registered = true
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.togglePlayPause() }
            return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.state?.hub.main.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.state?.hub.main.pause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.state?.zap(by: 1) }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.state?.zap(by: -1) }
            return .success
        }
    }

    private func togglePlayPause() {
        guard let main = state?.hub.main else { return }
        if main.phase == .paused { main.resume() } else { main.pause() }
    }

    func updateNowPlaying(title: String?, isLive: Bool) {
        guard let title else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
        ]
    }
}
