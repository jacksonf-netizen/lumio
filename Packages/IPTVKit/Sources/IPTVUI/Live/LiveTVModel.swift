import Foundation
import GRDB
import Observation
import IPTVCore

/// State for the Live TV browser: groups, channels, selection, now/next and the preview.
@MainActor
@Observable
final class LiveTVModel {
    var filter: ProviderFilter = .all {
        didSet { if filter != oldValue { reloadGroups() } }
    }
    var showHidden = false {
        didSet { if showHidden != oldValue { reloadGroups() } }
    }
    private(set) var groups: [ChannelGroup] = []
    var selectedGroupID: ChannelGroup.ID? = "all" {
        didSet { if selectedGroupID != oldValue { reloadChannels() } }
    }
    private(set) var channels: [ChannelListItem] = []
    var selectedChannelID: ChannelListItem.ID? {
        didSet { if selectedChannelID != oldValue { selectionChanged() } }
    }
    var searchText = ""
    private(set) var isLoading = false
    /// Bumped whenever favorites, recents or the channel lineup change, for pages that list them.
    private(set) var libraryVersion = 0
    /// Now/next per EPG reference, filled lazily for rows on screen.
    private(set) var nowNext: [EPGRef: NowNext] = [:]
    /// Whether the preview pane plays the selected channel.
    var previewEnabled = true {
        didSet {
            if !previewEnabled { Task { await hub.stopPreview() } } else { selectionChanged() }
        }
    }

    var selectedGroup: ChannelGroup? { groups.first { $0.id == selectedGroupID } }
    var selectedChannel: ChannelListItem? { channels.first { $0.id == selectedChannelID } }

    var visibleChannels: [ChannelListItem] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return channels }
        return channels.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.number.map(String.init) == query }
    }

    weak var state: AppState?
    @ObservationIgnored let environment: AppEnvironment
    @ObservationIgnored let catalog: LiveCatalog
    @ObservationIgnored let guide: GuideRepository
    @ObservationIgnored let library: LibraryRepository
    @ObservationIgnored let hub: PlayerHub
    @ObservationIgnored private var observation: AnyDatabaseCancellable?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var channelTask: Task<Void, Never>?
    @ObservationIgnored private var pendingNowNext: Set<EPGRef> = []
    @ObservationIgnored private var nowNextTask: Task<Void, Never>?
    @ObservationIgnored private var nowNextLoadedAt: [EPGRef: Date] = [:]

    init(environment: AppEnvironment, catalog: LiveCatalog, guide: GuideRepository, library: LibraryRepository, hub: PlayerHub) {
        self.environment = environment
        self.catalog = catalog
        self.guide = guide
        self.library = library
        self.hub = hub
    }

    func start() {
        reloadGroups()
        // Reload when anything that affects the lists changes (sync, edits, matching).
        let region = DatabaseRegionObservation(tracking: [
            Table("channel"), Table("category"), Table("channelOverride"), Table("categoryOverride"),
            Table("favorite"), Table("recentItem"), Table("customGroup"), Table("customGroupMember"),
            Table("logicalChannelMember"), Table("provider"), Table("logicalEPGOverride"), Table("epgMappingOverride"),
            Table("setting"), // hidden regions
        ])
        observation = region.start(in: environment.database.writer, onError: { error in
            Log.app.error("Live TV observation failed: \(String(describing: error), privacy: .public)")
        }, onChange: { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
        })
        // Programme data changes after guide imports: refresh now/next.
        let guideRegion = DatabaseRegionObservation(tracking: Table("programme"))
        guideObservation = guideRegion.start(in: environment.database.writer, onError: { _ in }, onChange: { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.nowNextLoadedAt.removeAll()
                }
            }
        })
    }

    @ObservationIgnored private var guideObservation: AnyDatabaseCancellable?

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.libraryVersion += 1
            self?.reloadGroups()
        }
    }

    func reloadGroups() {
        let catalog = self.catalog
        let filter = self.filter
        let includeHidden = showHidden
        Task {
            guard let loaded = try? await catalog.groups(filter: filter, includeHidden: includeHidden) else { return }
            groups = loaded
            if selectedGroupID == nil || !loaded.contains(where: { $0.id == selectedGroupID }) {
                selectedGroupID = "all"
            }
            reloadChannels()
        }
    }

    func reloadChannels() {
        guard let group = selectedGroup else {
            channels = []
            return
        }
        channelTask?.cancel()
        isLoading = channels.isEmpty
        let catalog = self.catalog
        let filter = self.filter
        let includeHidden = showHidden
        channelTask = Task {
            let loaded = (try? await catalog.channels(in: group, filter: filter, includeHidden: includeHidden)) ?? []
            guard !Task.isCancelled else { return }
            channels = loaded
            isLoading = false
            if let selected = selectedChannelID, !loaded.contains(where: { $0.id == selected }) {
                selectedChannelID = nil
            }
        }
    }

    // MARK: Now / next

    /// Called by rows as they appear; requests are batched.
    func needNowNext(for ref: EPGRef?) {
        guard let ref else { return }
        if let loaded = nowNextLoadedAt[ref], Date().timeIntervalSince(loaded) < 60,
           (nowNext[ref]?.now?.stop ?? .distantFuture) > Date() {
            return
        }
        pendingNowNext.insert(ref)
        guard nowNextTask == nil else { return }
        nowNextTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            await self?.flushNowNext()
        }
    }

    private func flushNowNext() async {
        let refs = Array(pendingNowNext)
        pendingNowNext.removeAll()
        nowNextTask = nil
        guard !refs.isEmpty, let result = try? await guide.nowNext(for: refs) else { return }
        let now = Date()
        for ref in refs {
            nowNext[ref] = result[ref] ?? NowNext(now: nil, next: nil)
            nowNextLoadedAt[ref] = now
        }
    }

    // MARK: Selection and preview

    private func selectionChanged() {
        guard previewEnabled, let channel = selectedChannel,
              state?.isPlayerPresented != true,
              let item = try? environment.items.liveItem(providerID: channel.providerID, streamID: channel.streamID)
        else { return }
        hub.playPreview(item)
    }

    func watchSelected() {
        guard let channel = selectedChannel else { return }
        state?.watch(channel, in: visibleChannels)
    }

    func watch(_ channel: ChannelListItem) {
        selectedChannelID = channel.id
        state?.watch(channel, in: visibleChannels)
    }

    // MARK: Management

    func toggleFavorite(_ channel: ChannelListItem) {
        Task { try? await library.toggleFavorite(channel) }
    }

    func removeRecent(_ channel: ChannelListItem) {
        Task { try? await library.removeRecent(channel) }
    }

    func setHidden(_ hidden: Bool, _ channel: ChannelListItem) {
        Task { try? await library.setHidden(hidden, channel: channel) }
    }

    func rename(_ channel: ChannelListItem, to name: String?) {
        Task { try? await library.rename(channel, to: name) }
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard let group = selectedGroup, searchText.isEmpty else { return }
        var reordered = channels
        reordered.move(fromOffsets: source, toOffset: destination)
        channels = reordered
        Task { try? await library.reorder(reordered, in: group) }
    }

    func moveGroups(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = groups
        reordered.move(fromOffsets: source, toOffset: destination)
        groups = reordered
        Task { try? await library.reorderGroups(reordered) }
    }

    func setHidden(_ hidden: Bool, group: ChannelGroup) {
        Task { try? await library.setHidden(hidden, group: group) }
    }

    func rename(_ group: ChannelGroup, to name: String?) {
        Task { try? await library.rename(group, to: name) }
    }

    func deleteGroup(_ group: ChannelGroup) {
        Task { try? await library.deleteGroup(group) }
    }

    func createGroup(named name: String, adding channel: ChannelListItem?) {
        Task {
            guard let group = try? await library.createGroup(named: name) else { return }
            if let channel { try? await library.add(channel, toGroup: group.id) }
        }
    }

    func add(_ channel: ChannelListItem, toGroup id: String) {
        Task { try? await library.add(channel, toGroup: id) }
    }

    func remove(_ channel: ChannelListItem, fromGroup group: ChannelGroup) {
        guard group.kind == .custom else { return }
        Task { try? await library.remove(channel, fromGroup: String(group.id.dropFirst("custom:".count))) }
    }

    func setEngine(_ engine: EngineKind?, format: StreamFormat?, for channel: ChannelListItem) {
        Task { try? await library.setEngine(engine, format: format, for: channel) }
    }

    /// Manual EPG match. Refreshes the matched provider's guide so the programmes get imported.
    func setEPG(_ guideChannel: EPGChannel?, for channel: ChannelListItem) {
        let sync = environment.sync
        Task {
            try? await library.setEPG(guideChannel, for: channel)
            if let provider = guideChannel?.providerID {
                Task.detached(priority: .utility) { await sync.refresh(provider, parts: .guide) }
            }
        }
    }

    /// Unlink a provider's channel from the merged channel, or link it into another one.
    func setLink(_ action: ChannelLinkOverride.Action?, providerID: ProviderID, streamID: Int, target: String? = nil) {
        let store = environment.logicalChannels
        Task.detached {
            let override = action.map { ChannelLinkOverride(providerID: providerID, streamID: streamID, action: $0, targetLogicalChannelID: target) }
            try? store.setOverride(override, providerID: providerID, streamID: streamID)
        }
    }

    func sources(of channel: ChannelListItem) -> [Channel] {
        (try? environment.logicalChannels.sources(of: channel.id)) ?? []
    }

    func providerName(_ id: ProviderID) -> String {
        state?.providers.providers.first { $0.id == id }?.name ?? id.rawValue
    }
}
