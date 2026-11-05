import Foundation
import Observation
import IPTVCore
import IPTVPlayback

/// Owns the app's playback slots: the main player, the live preview pane and (later) multiview
/// tiles. Each slot has its own PlaybackController and engines; all share one ConnectionManager.
@MainActor
@Observable
public final class PlayerHub {
    public let main: PlaybackController
    public let preview: PlaybackController

    /// The live item last played in the main player before the current one ("last channel").
    public private(set) var previousLiveItem: PlaybackItem?
    public private(set) var currentLiveItem: PlaybackItem?

    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored let dependencies: PlaybackDependencies

    public init(environment: AppEnvironment) {
        self.environment = environment
        dependencies = environment.playbackDependencies(makeEngine: { kind in PlaybackEngines.make(kind) })
        let settings = PlayerHub.loadSettings(environment)
        main = PlaybackController(purpose: .main, settings: settings, dependencies: dependencies)
        var previewSettings = settings
        previewSettings.zapDebounce = 0.5
        preview = PlaybackController(purpose: .preview, settings: previewSettings, dependencies: dependencies)
        preview.isMuted = true
    }

    /// Makes a controller for a multiview tile.
    public func makeTileController(_ index: Int) -> PlaybackController {
        PlaybackController(purpose: .tile(index), settings: PlayerHub.loadSettings(environment), dependencies: dependencies)
    }

    /// Plays in the main player. Stops the preview first if it's showing the same item, so a
    /// single-connection account hands its connection straight over.
    public func playMain(_ item: PlaybackItem, debounce: Bool = false) {
        if item.isLive {
            if currentLiveItem?.id != item.id { previousLiveItem = currentLiveItem }
            currentLiveItem = item
        }
        let preview = self.preview
        let main = self.main
        if preview.item != nil {
            Task {
                await preview.stop()
                main.play(item, debounce: debounce)
            }
        } else {
            main.play(item, debounce: debounce)
        }
    }

    public func playPreview(_ item: PlaybackItem) {
        preview.play(item, debounce: true)
    }

    public func stopPreview() async {
        await preview.stop()
    }

    /// Re-reads playback settings (after the user changes them).
    public func reloadSettings() {
        let settings = PlayerHub.loadSettings(environment)
        main.settings = settings
        var previewSettings = settings
        previewSettings.zapDebounce = 0.5
        preview.settings = previewSettings
    }

    /// The Mac's engines: mpv first (MPEG-TS, every codec), AVPlayer as the fallback.
    static func loadSettings(_ environment: AppEnvironment) -> PlaybackSettings {
        environment.playbackSettings(engines: [.mpv, .avPlayer])
    }
}
