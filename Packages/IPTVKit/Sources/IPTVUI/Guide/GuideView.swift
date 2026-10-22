import AppKit
import SwiftUI
import IPTVCore

/// Which channels a guide page shows: any group (the Guide window and the player overlay, with a
/// group picker), the group selected in Live TV (its Guide view), or a fixed list.
enum GuideScope: Equatable {
    case all
    case liveTV
    case recents
    case favorites

    /// The group shown, for the fixed scopes.
    var fixedGroup: ChannelGroup? {
        switch self {
        case .all, .liveTV: nil
        case .recents: ChannelGroup(id: "recents", name: "Recently Watched", kind: .recents)
        case .favorites: ChannelGroup(id: "favorites", name: "Favorites", kind: .favorites)
        }
    }
}

/// Guide data for the grid: channels of the chosen group, and programmes loaded in one-day blocks
/// for the rows on screen.
@MainActor
@Observable
final class GuideModel: GuideGridDataSource {
    var groupID: ChannelGroup.ID = "all" {
        didSet { if groupID != oldValue { reloadChannels() } }
    }
    private(set) var channels: [ChannelListItem] = []
    /// True once the first channel list has loaded (so an empty list means "none", not "loading").
    private(set) var loaded = false
    let scope: GuideScope
    private(set) var selectedChannel: ChannelListItem?
    private(set) var selectedProgramme: Programme?

    /// Timeline origin: start of yesterday (the EPG keeps one day of history).
    let origin: Date = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
    let days = 8

    @ObservationIgnored weak var grid: GuideGridView?
    @ObservationIgnored private let state: AppState
    @ObservationIgnored private var blocks: [EPGRef: [Int: [Programme]]] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var pending: [(EPGRef, Int)] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    init(state: AppState, scope: GuideScope = .all) {
        self.state = state
        self.scope = scope
        groupID = scope.fixedGroup?.id ?? state.live.selectedGroupID ?? "all"
    }

    var groups: [ChannelGroup] { state.live.groups }

    func reloadChannels() {
        // Fixed lists don't wait for the group list to load (Recents is the first page shown).
        let group = scope.fixedGroup
            ?? state.live.groups.first { $0.id == groupID }
            ?? ChannelGroup(id: "all", name: "All", kind: .all, isHidden: false, categories: [])
        let catalog = state.liveCatalog
        // Recents and Favorites always list every provider's channels.
        let filter = scope.fixedGroup == nil ? state.live.filter : .all
        Task {
            let list = (try? await catalog.channels(in: group, filter: filter)) ?? []
            show(list)
        }
    }

    /// Shows a new channel list, keeping the highlighted channel highlighted wherever it moved.
    private func show(_ list: [ChannelListItem]) {
        channels = list
        loaded = true
        grid?.channels = list
        let row = selectedChannel.flatMap { selected in list.firstIndex { $0.id == selected.id } }
        if row == nil { selectedChannel = nil }
        grid?.restoreSelection(row: row, programme: row == nil ? nil : selectedProgramme)
        grid?.requestVisibleData()
    }

    // MARK: Organising (Recents and Favorites)

    /// Drag-to-reorder in Favorites.
    func moveChannel(from source: Int, to destination: Int) {
        guard scope == .favorites, let group = scope.fixedGroup, channels.indices.contains(source) else { return }
        var reordered = channels
        reordered.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
        show(reordered)
        let library = state.library
        Task { try? await library.reorder(reordered, in: group) }
    }

    func moveToEdge(_ channel: ChannelListItem, top: Bool) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        moveChannel(from: index, to: top ? 0 : channels.count)
    }

    func removeFromList(_ channel: ChannelListItem) {
        let library = state.library
        switch scope {
        case .recents: Task { try? await library.removeRecent(channel) }
        case .favorites: Task { if channel.isFavorite { _ = try? await library.toggleFavorite(channel) } }
        case .all, .liveTV: break
        }
    }

    func clearRecents() {
        let alert = NSAlert()
        alert.messageText = "Clear Recently Watched?"
        alert.informativeText = "This empties the list of channels you've watched. Favorites aren't affected."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let library = state.library
        Task { try? await library.clearRecents([.channel]) }
    }

    /// Right-click menu for a channel row.
    func menu(for channel: ChannelListItem) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Watch") { [weak self] in self?.activate(channel, programme: nil) })
        let library = state.library
        switch scope {
        case .recents:
            menu.addItem(ClosureMenuItem(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                Task { try? await library.toggleFavorite(channel) }
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Remove from Recently Watched") { [weak self] in self?.removeFromList(channel) })
            menu.addItem(ClosureMenuItem("Clear Recently Watched…") { [weak self] in self?.clearRecents() })
        case .favorites:
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Move to Top") { [weak self] in self?.moveToEdge(channel, top: true) })
            menu.addItem(ClosureMenuItem("Move to Bottom") { [weak self] in self?.moveToEdge(channel, top: false) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Remove from Favorites") { [weak self] in self?.removeFromList(channel) })
        case .all, .liveTV:
            menu.addItem(ClosureMenuItem(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                Task { try? await library.toggleFavorite(channel) }
            })
        }
        return menu
    }

    /// Drops cached programmes (after a guide import).
    func invalidate() {
        blocks.removeAll()
        loading.removeAll()
        grid?.requestVisibleData()
        grid?.dataDidChange()
    }

    // MARK: GuideGridDataSource

    func programmes(for ref: EPGRef, day: Int) -> [Programme]? {
        blocks[ref]?[day]
    }

    func request(_ wanted: [(EPGRef, Int)]) {
        for (ref, day) in wanted {
            let key = "\(ref.epgID)|\(ref.providers.map(\.rawValue).joined(separator: ","))|\(day)"
            guard loading.insert(key).inserted else { continue }
            pending.append((ref, day))
        }
        guard flushTask == nil, !pending.isEmpty else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            await self?.flush()
        }
    }

    private func flush() async {
        let batch = pending
        pending.removeAll()
        flushTask = nil
        // One query per day touched, covering every requested channel.
        let byDay = Dictionary(grouping: batch, by: \.1)
        for (day, items) in byDay {
            let start = origin.addingTimeInterval(Double(day) * 86_400)
            let window = DateInterval(start: start, duration: 86_400)
            let refs = items.map(\.0)
            let result = (try? await state.guide.programmes(for: refs, in: window)) ?? [:]
            for ref in refs {
                blocks[ref, default: [:]][day] = result[ref] ?? []
            }
        }
        grid?.dataDidChange()
        if !pending.isEmpty { request([]) }
    }

    // MARK: Interaction

    func select(_ channel: ChannelListItem, programme: Programme?, preview: Bool) {
        selectedChannel = channel
        selectedProgramme = programme
        guard preview, scope != .liveTV || state.live.previewEnabled else { return }
        previewTask?.cancel()
        previewTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled,
                  let item = try? state.environment.items.liveItem(providerID: channel.providerID, streamID: channel.streamID)
            else { return }
            state.hub.playPreview(item)
        }
    }

    /// Playing a programme that's on now (or any row) plays the channel.
    func activate(_ channel: ChannelListItem, programme: Programme?) {
        if let programme, programme.start > Date() { return } // future programmes just show details
        previewTask?.cancel()
        state.watch(channel, in: channels)
    }

    func jumpToNow() {
        grid?.scroll(to: Date(), animated: true)
    }
}

/// The full EPG guide. In `compact` mode (the G overlay in the player) there's no preview pane.
struct GuideView: View {
    let state: AppState
    var compact = false
    var scope: GuideScope = .all
    /// In the player overlay: closes it (the ✕ button, Esc or G).
    var onClose: (() -> Void)? = nil
    @State private var model: GuideModel?

    var body: some View {
        Group {
            if let model {
                GuideContent(model: model, state: state, compact: compact, onClose: onClose)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if model == nil { model = GuideModel(state: state, scope: scope) }
        }
    }
}

private struct GuideContent: View {
    @Bindable var model: GuideModel
    let state: AppState
    let compact: Bool
    let onClose: (() -> Void)?

    private var title: String {
        switch model.scope {
        case .all: "Guide"
        case .liveTV: "Live TV"
        case .recents: "Recents"
        case .favorites: "Favorites"
        }
    }

    var body: some View {
        Group {
            if model.scope.fixedGroup != nil, model.loaded, model.channels.isEmpty {
                emptyList
            } else {
                content
            }
        }
        .navigationTitle(compact ? "" : title)
        .onChange(of: state.live.groups) { model.reloadChannels() }
        .onChange(of: state.live.selectedGroupID) { _, id in
            if model.scope == .liveTV { model.groupID = id ?? "all" }
        }
        .onChange(of: state.live.filter) { model.reloadChannels() }
        .onChange(of: state.live.libraryVersion) { model.reloadChannels() }
        .onChange(of: state.providers.syncing.isEmpty) { _, idle in if idle { model.invalidate() } }
    }

    @ViewBuilder
    private var emptyList: some View {
        if model.scope == .recents {
            EmptyState("Nothing Watched Yet", systemImage: "clock.arrow.circlepath",
                       message: "Channels you watch appear here, most recent first, with what's on now and next.") {
                Button("Browse Live TV") { state.section = .liveTV }.buttonStyle(.borderedProminent)
            }
        } else {
            EmptyState("No Favorite Channels", systemImage: "star",
                       message: "Right-click a channel in Live TV or Recents and choose Add to Favorites.") {
                Button("Browse Live TV") { state.section = .liveTV }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if !compact {
                HStack(alignment: .top, spacing: 16) {
                    PlayerView(controller: state.hub.preview, compact: true)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .frame(height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
                        .onTapGesture(count: 2) {
                            if let channel = model.selectedChannel { model.activate(channel, programme: nil) }
                        }
                    ProgrammeDetail(channel: model.selectedChannel, programme: model.selectedProgramme) {
                        if let channel = model.selectedChannel { model.activate(channel, programme: nil) }
                    }
                    Spacer()
                }
                .padding([.horizontal, .top])
                .padding(.bottom, 8)
            }
            toolbar
            Divider()
            GuideGridRepresentable(model: model, currentChannelID: state.currentChannel?.id, dark: compact, onClose: onClose)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            switch model.scope {
            case .all:
                Picker("Group", selection: $model.groupID) {
                    ForEach(model.groups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
            case .liveTV:
                // The group list beside the guide picks the group.
                Text(model.groups.first { $0.id == model.groupID }?.name ?? "")
                    .font(.headline)
                    .lineLimit(1)
            case .recents:
                Label("Most recent first", systemImage: "clock.arrow.circlepath")
                    .font(.callout).foregroundStyle(.secondary)
                    .help("Right-click a channel to remove it")
            case .favorites:
                Label("Drag channels to reorder", systemImage: "hand.draw")
                    .font(.callout).foregroundStyle(.secondary)
                    .help("Or right-click a channel to move or remove it")
            }

            Spacer()
            Button("Now", systemImage: "clock") { model.jumpToNow() }
                .help("Jump to now")
            if compact, let programme = model.selectedProgramme, let channel = model.selectedChannel {
                Text("\(channel.name): \(programme.title)").font(.callout).lineLimit(1).foregroundStyle(.secondary)
            }
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .help("Close Guide (Esc)")
                .accessibilityLabel("Close Guide")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct ProgrammeDetail: View {
    let channel: ChannelListItem?
    let programme: Programme?
    let watch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let channel {
                HStack {
                    Text(channel.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            if let programme {
                Text(programme.title).font(.title2.bold()).lineLimit(2)
                HStack(spacing: 8) {
                    Text("\(programme.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) – \(programme.stop.formatted(date: .omitted, time: .shortened))")
                    if let episode = programme.episodeNumber { Text(episode) }
                    if let category = programme.category { Text(category) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                if let subtitle = programme.subtitle { Text(subtitle).font(.headline) }
                if let summary = programme.summary {
                    Text(summary).font(.callout).lineLimit(4).foregroundStyle(.secondary)
                }
                if programme.start <= Date(), programme.stop > Date() {
                    Button("Watch Now", action: watch).buttonStyle(.borderedProminent)
                }
            } else if channel != nil {
                Text("No programme selected").foregroundStyle(.secondary)
                Button("Watch Channel", action: watch)
            } else {
                Text("Select a programme in the guide.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

/// Bridges the AppKit grid into SwiftUI.
private struct GuideGridRepresentable: NSViewRepresentable {
    let model: GuideModel
    let currentChannelID: String?
    /// Inside the player the grid is always dark, like the rest of the player.
    var dark = false
    var onClose: (() -> Void)? = nil

    func makeNSView(context: Context) -> GuideContainerView {
        let container = GuideContainerView()
        if dark { container.appearance = NSAppearance(named: .darkAqua) }
        let grid = container.grid
        grid.origin = model.origin
        grid.days = model.days
        grid.dataSource = model
        grid.onSelect = { [weak model] channel, programme in model?.select(channel, programme: programme, preview: true) }
        grid.onActivate = { [weak model] channel, programme in model?.activate(channel, programme: programme) }
        grid.menuForChannel = { [weak model] channel in model?.menu(for: channel) }
        if model.scope == .favorites {
            grid.onMoveChannel = { [weak model] from, to in model?.moveChannel(from: from, to: to) }
        }
        if let onClose {
            // The grid has keyboard focus while the overlay is open, so it passes Esc and G on.
            grid.onOtherKey = { event in
                guard event.keyCode == 53 || event.charactersIgnoringModifiers?.lowercased() == "g" else { return false }
                onClose()
                return true
            }
        }
        model.grid = grid
        grid.channels = model.channels
        model.reloadChannels()
        DispatchQueue.main.async {
            grid.scroll(to: Date())
            grid.window?.makeFirstResponder(grid)
        }
        return container
    }

    func updateNSView(_ container: GuideContainerView, context: Context) {
        container.grid.currentChannelID = currentChannelID
        container.grid.needsDisplay = true
    }
}
