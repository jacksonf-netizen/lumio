import Foundation
import Observation
import IPTVCore

/// App-wide UI state shared by every window: playback, the zapping context and screen models.
/// Created once by the app and passed to each scene.
@MainActor
@Observable
public final class AppState {
    public let environment: AppEnvironment
    public let hub: PlayerHub
    let providers: ProvidersViewModel
    let live: LiveTVModel
    /// Favorites → Channels → List: a second Live TV browser fixed on the Favorites group.
    let favoritesList: LiveTVModel
    let library: LibraryRepository
    let liveCatalog: LiveCatalog
    let guide: GuideRepository
    let multiview: MultiviewModel
    let vod: VODCatalog
    /// Release checks (inactive unless the build has a release feed).
    public let updates = UpdateController()
    @ObservationIgnored private let vodTracker = VODProgressTracker()

    /// Selected sidebar section in the main window. The app opens on Recents (or the first section
    /// the user hasn't switched off).
    public var section: SidebarItem = .recents
    /// Sections switched off in Settings → General. Settings itself can't be.
    public private(set) var hiddenSections: Set<SidebarItem> = []
    /// The full-screen player overlay in the main window.
    public var isPlayerPresented = false
    /// Multiview, shown over the main window in place of the player.
    public var isMultiviewPresented = false
    /// True while a separate player window is open; then the overlay isn't used.
    public var playerWindowOpen = false
    public var showDiagnostics = false
    public var showGuideOverlay = false

    /// Channels the player zaps through (the list the user started playing from), with the
    /// current and previous channel. The rules are the shared core's (ZapList).
    public private(set) var zap = ZapList<ChannelListItem>()
    public var zapList: [ChannelListItem] { zap.channels }
    public var currentChannel: ChannelListItem? { zap.current }
    public var previousChannel: ChannelListItem? { zap.previous }
    /// Bumped on every channel change so the info banner can show itself.
    public private(set) var channelChangeCount = 0

    public init(environment: AppEnvironment) {
        self.environment = environment
        hub = PlayerHub(environment: environment)
        providers = ProvidersViewModel(environment: environment)
        library = LibraryRepository(database: environment.database)
        liveCatalog = LiveCatalog(database: environment.database)
        guide = GuideRepository(database: environment.database)
        live = LiveTVModel(environment: environment, catalog: liveCatalog, guide: guide, library: library, hub: hub)
        favoritesList = LiveTVModel(environment: environment, catalog: liveCatalog, guide: guide, library: library, hub: hub)
        favoritesList.selectedGroupID = "favorites"
        multiview = MultiviewModel(hub: hub, environment: environment)
        vod = VODCatalog(database: environment.database)
        live.state = self
        favoritesList.state = self
        loadHiddenSections()
        providers.start()
        live.start()
    }

    // MARK: Sidebar

    func isShown(_ item: SidebarItem) -> Bool { !hiddenSections.contains(item) }

    func setSection(_ item: SidebarItem, shown: Bool) {
        guard item != .settings else { return }
        if shown { hiddenSections.remove(item) } else { hiddenSections.insert(item) }
        let raw = SidebarItem.allCases.filter(hiddenSections.contains).map(\.rawValue)
        try? environment.settings.set(raw.isEmpty ? nil : raw, for: .hiddenSidebarItems)
        leaveHiddenSection()
    }

    /// Reads the switched-off sections (at launch and after a backup is restored).
    func loadHiddenSections() {
        let raw = (try? environment.settings.value([String].self, for: .hiddenSidebarItems)) ?? []
        hiddenSections = Set(raw.compactMap(SidebarItem.init(rawValue:))).subtracting([.settings])
        leaveHiddenSection()
    }

    /// Moves off a section that's switched off, to the first one that isn't (Settings at worst).
    private func leaveHiddenSection() {
        guard hiddenSections.contains(section) else { return }
        section = SidebarItem.allCases.first(where: isShown) ?? .settings
    }

    // MARK: Watching live TV

    /// Plays a channel in the main player and shows the player.
    public func watch(_ channel: ChannelListItem, in list: [ChannelListItem]? = nil, debounce: Bool = false) {
        zap.watch(channel, in: list)
        channelChangeCount += 1
        guard let item = try? environment.items.liveItem(providerID: channel.providerID, streamID: channel.streamID) else {
            Log.app.error("No playable item for \(channel.id, privacy: .public)")
            return
        }
        hub.playMain(item, debounce: debounce)
        if !playerWindowOpen { isPlayerPresented = true }
        let library = self.library
        Task { try? await library.recordPlayed(providerID: channel.providerID, kind: .channel, itemID: String(channel.streamID)) }
    }

    /// Next / previous channel in the zap list (wraps around). Debounced so holding a key doesn't
    /// open every channel on the way.
    public func zap(by offset: Int) {
        // A one-channel list doesn't reopen the stream.
        guard let next = zap.channel(by: offset), next.id != currentChannel?.id else { return }
        watch(next, debounce: true)
    }

    /// Jumps to a channel by its number (provider numbering), or by position if no number matches.
    public func jump(toNumber number: Int) {
        if let match = zap.channel(number: number, numberOf: \.number) { watch(match) }
    }

    public func lastChannel() {
        guard let previous = previousChannel else { return }
        watch(previous)
    }

    /// Plays any item (movies, episodes) in the main player.
    public func play(_ item: PlaybackItem) {
        hub.playMain(item)
        if !playerWindowOpen { isPlayerPresented = true }
    }

    /// Plays a movie or episode and saves its position as it plays (the shared VODProgressTracker:
    /// every 10 s and when playback stops; the end marks it watched).
    public func playVOD(_ item: PlaybackItem, kind: LibraryItemKind, providerID: ProviderID, itemID: String) {
        play(item)
        vodTracker.track(item, on: hub.main, kind: kind, providerID: providerID, itemID: itemID, library: library) { [weak self] in
            self?.vodProgressVersion += 1
        }
    }

    /// Bumped whenever watch progress is saved, so VOD screens refresh.
    public private(set) var vodProgressVersion = 0

    /// Opens multiview, starting with `channel` in the first tile.
    /// Opens multiview from the player, with the channel that was playing in the first tile.
    public func startMultiview(with channel: ChannelListItem?) {
        showGuideOverlay = false
        multiview.start(with: channel)
        isPlayerPresented = false
        isMultiviewPresented = true
    }

    /// Back to the full-window player, on the tile whose sound was playing.
    public func exitMultiview() {
        let focused = multiview.tiles.first { $0.index == multiview.audioTile }?.channel
        if let channel = focused ?? multiview.tiles.first(where: { $0.channel != nil })?.channel ?? currentChannel {
            watchFromMultiview(channel)
        } else {
            closeMultiview()
        }
    }

    /// Leaves multiview for the browser, stopping every tile.
    public func closeMultiview() {
        isMultiviewPresented = false
        let multiview = self.multiview
        Task { await multiview.stopAll() }
    }

    /// Leaves multiview for the full-window player on `channel`. Every tile's stream is closed
    /// before the player opens its own, so the provider never sees more streams than its limit.
    public func watchFromMultiview(_ channel: ChannelListItem) {
        let multiview = self.multiview
        Task {
            await multiview.stopAll()
            isMultiviewPresented = false
            watch(channel)
        }
    }

    /// Leaves the player and stops playback.
    public func closePlayer() {
        isPlayerPresented = false
        showGuideOverlay = false
        let main = hub.main
        Task { await main.stop() }
    }
}

extension ProcessInfo {
    /// When this process started (from the kernel), for launch-time measurement.
    public var launchDate: Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }
}
