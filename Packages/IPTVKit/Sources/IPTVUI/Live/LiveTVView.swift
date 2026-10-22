import SwiftUI
import IPTVCore

/// How a page shows its channels: a list with a preview, or the guide's timeline.
enum ChannelLayout: String {
    case list, guide
}

/// The List / Guide switch at the top of Live TV and Favorites.
struct ChannelLayoutPicker: View {
    @Binding var layout: ChannelLayout

    var body: some View {
        Picker("View", selection: $layout) {
            Text("List").tag(ChannelLayout.list)
            Text("Guide").tag(ChannelLayout.guide)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .help("Show channels as a list with a preview, or as a guide of what's on later")
    }
}

/// Live TV: groups → channels → live preview, or groups → guide. Double-click or Return plays
/// full screen.
struct LiveTVView: View {
    @Bindable var model: LiveTVModel
    let state: AppState
    @State private var sheet: ManagementSheet?
    @AppStorage("liveTVLayout") private var layout: ChannelLayout = .list

    var body: some View {
        // Columns share the width so the page always fits the window. (HSplitView kept its column
        // widths when the window got narrower and spilled past both edges.)
        GeometryReader { geometry in
            let width = geometry.size.width
            HStack(spacing: 0) {
                GroupList(model: model, sheet: $sheet)
                    .frame(width: min(240, max(150, width * 0.2)))
                Divider()
                switch layout {
                case .list:
                    ChannelList(model: model, sheet: $sheet)
                        .frame(maxWidth: .infinity)
                    Divider()
                    PreviewPane(model: model, state: state)
                        .frame(width: min(560, max(260, width * 0.38)))
                case .guide:
                    GuideView(state: state, scope: .liveTV)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Live TV")
        .toolbar {
            ToolbarItem(placement: .principal) {
                ChannelLayoutPicker(layout: $layout)
            }
            ToolbarItemGroup {
                ProviderFilterPicker(filter: $model.filter, providers: state.providers.providers)
                Toggle(isOn: $model.showHidden) {
                    Label("Show Hidden", systemImage: model.showHidden ? "eye" : "eye.slash")
                }
                .help("Show hidden channels and groups so you can unhide them")
                Toggle(isOn: $model.previewEnabled) {
                    Label("Preview", systemImage: model.previewEnabled ? "play.rectangle.fill" : "play.rectangle")
                }
                .help("Play the selected channel in the preview pane")
            }
        }
        .sheet(item: $sheet) { sheet in
            ManagementSheetView(sheet: sheet, model: model)
        }
    }
}

struct ProviderFilterPicker: View {
    @Binding var filter: ProviderFilter
    let providers: [Provider]

    var body: some View {
        Picker("Providers", selection: $filter) {
            Text("All Providers").tag(ProviderFilter.all)
            if !providers.isEmpty { Divider() }
            ForEach(providers.filter(\.isEnabled)) { provider in
                Text(provider.name).tag(ProviderFilter.only(provider.id))
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Show all providers merged, or just one")
    }
}

/// Favorite channels as a list with a preview (Favorites → Channels → List).
struct FavoriteChannelList: View {
    let state: AppState
    @State private var sheet: ManagementSheet?

    var body: some View {
        let model = state.favoritesList
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ChannelList(model: model, sheet: $sheet)
                    .frame(maxWidth: .infinity)
                Divider()
                PreviewPane(model: model, state: state)
                    .frame(width: min(560, max(260, geometry.size.width * 0.42)))
            }
        }
        .onAppear { model.startIfNeeded() }
        .sheet(item: $sheet) { sheet in
            ManagementSheetView(sheet: sheet, model: model)
        }
    }
}

// MARK: - Groups

private struct GroupList: View {
    @Bindable var model: LiveTVModel
    @Binding var sheet: ManagementSheet?

    var body: some View {
        List(selection: $model.selectedGroupID) {
            ForEach(model.groups) { group in
                Label(group.name, systemImage: icon(for: group))
                    .foregroundStyle(group.isHidden ? .secondary : .primary)
                    .tag(group.id)
                    .contextMenu { menu(for: group) }
            }
            .onMove { source, destination in
                model.moveGroups(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button {
                sheet = .newGroup(adding: nil)
            } label: {
                Label("New Group", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func icon(for group: ChannelGroup) -> String {
        switch group.kind {
        case .favorites: "star.fill"
        case .recents: "clock"
        case .all: "square.grid.3x3"
        case .custom: "folder"
        case .category: group.isHidden ? "eye.slash" : "list.bullet"
        }
    }

    @ViewBuilder
    private func menu(for group: ChannelGroup) -> some View {
        if group.kind == .category || group.kind == .custom {
            Button("Rename…") { sheet = .renameGroup(group) }
        }
        if group.kind == .category {
            Button(group.isHidden ? "Unhide Group" : "Hide Group") { model.setHidden(!group.isHidden, group: group) }
        }
        if group.kind == .custom {
            Button("Delete Group", role: .destructive) { model.deleteGroup(group) }
        }
    }
}

// MARK: - Channels

private struct ChannelList: View {
    @Bindable var model: LiveTVModel
    @Binding var sheet: ManagementSheet?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter channels", text: $model.searchText)
                    .textFieldStyle(.plain)
                if !model.searchText.isEmpty {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear filter")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()

            if model.isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleChannels.isEmpty {
                EmptyState(emptyTitle, systemImage: emptyIcon, message: emptyMessage)
            } else {
                ChannelTableView(
                    channels: model.visibleChannels,
                    nowNext: model.nowNext,
                    selection: $model.selectedChannelID,
                    allowsReordering: model.searchText.isEmpty,
                    onActivate: { model.watch($0) },
                    onRowVisible: { model.needNowNext(for: $0.epg) },
                    onMove: { model.move(fromOffsets: $0, toOffset: $1) },
                    makeMenu: { channel in ChannelMenuBuilder.menu(for: channel, model: model) { sheet = $0 } })
            }
        }
    }

    private var emptyTitle: String {
        if !model.searchText.isEmpty { return "No Matches" }
        switch model.selectedGroup?.kind {
        case .favorites: return "No Favorites Yet"
        case .recents: return "Nothing Watched Yet"
        default: return "No Channels"
        }
    }

    private var emptyIcon: String {
        if !model.searchText.isEmpty { return "magnifyingglass" }
        switch model.selectedGroup?.kind {
        case .favorites: return "star"
        case .recents: return "clock"
        default: return "tv"
        }
    }

    private var emptyMessage: String? {
        if !model.searchText.isEmpty { return "No channel in this group matches “\(model.searchText)”." }
        switch model.selectedGroup?.kind {
        case .favorites: return "Right-click a channel and choose Add to Favorites."
        case .recents: return "Channels you watch will appear here."
        default: return nil
        }
    }
}

struct ChannelRow: View {
    let channel: ChannelListItem
    let nowNext: NowNext?

    var body: some View {
        HStack(spacing: 10) {
            Text(channel.number.map(String.init) ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            ChannelLogo(name: channel.name, url: channel.logoURL, maxPixelSize: 96)
                .frame(width: 50, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(channel.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(channel.isHidden ? .secondary : .primary)
                    if channel.isFavorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    if channel.sourceProviders.count > 1 {
                        Text("\(channel.sourceProviders.count)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 4)
                            .background(.quaternary, in: Capsule())
                            .help("Available from \(channel.sourceProviders.count) providers")
                    }
                    if channel.isHidden {
                        Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let now = nowNext?.now {
                    Text(now.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ProgressView(value: nowNext?.progress() ?? 0)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .frame(maxWidth: 160)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Preview

private struct PreviewPane: View {
    let model: LiveTVModel
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PlayerView(controller: state.hub.preview, compact: true)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    if !model.previewEnabled || state.hub.preview.item == nil {
                        VStack(spacing: 8) {
                            Image(systemName: model.previewEnabled ? "play.tv" : "play.slash")
                                .font(.system(size: 26, weight: .light))
                            Text(model.previewEnabled ? "Select a channel to preview it" : "Preview is off")
                                .font(.callout)
                        }
                        .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                .onTapGesture(count: 2) { model.watchSelected() }

            if let channel = model.selectedChannel {
                ChannelDetails(channel: channel, nowNext: channel.epg.flatMap { model.nowNext[$0] }, model: model)
            }
            Spacer()
        }
        .padding()
    }
}

private struct ChannelDetails: View {
    let channel: ChannelListItem
    let nowNext: NowNext?
    let model: LiveTVModel

    private var logo: some View {
        ChannelLogo(name: channel.name, url: channel.logoURL).frame(width: 64, height: 44)
    }

    private var titles: some View {
        VStack(alignment: .leading) {
            Text(channel.name).font(.title3.bold()).lineLimit(2)
            Text(channel.sourceProviders.map(model.providerName).joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { model.toggleFavorite(channel) } label: {
                Image(systemName: channel.isFavorite ? "star.fill" : "star")
            }
            .help(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites")
            Button("Watch") { model.watch(channel) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Buttons move under the name when the column is too narrow for one row.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    logo
                    titles
                    Spacer(minLength: 8)
                    actions
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        logo
                        titles
                    }
                    actions
                }
            }
            if let now = nowNext?.now {
                ProgrammeSummary(label: "Now", programme: now, progress: nowNext?.progress())
            }
            if let next = nowNext?.next {
                ProgrammeSummary(label: "Next", programme: next, progress: nil)
            }
            if nowNext?.now == nil && nowNext?.next == nil {
                Text(channel.epg == nil ? "No guide data for this channel. Right-click it to match a guide." : "No programme information right now.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { model.needNowNext(for: channel.epg) }
    }
}

struct ProgrammeSummary: View {
    let label: String
    let programme: Programme
    let progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Text("\(programme.start.formatted(date: .omitted, time: .shortened)) – \(programme.stop.formatted(date: .omitted, time: .shortened))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(programme.title).font(.headline)
            if let subtitle = programme.subtitle ?? programme.episodeNumber {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            if let progress {
                ProgressView(value: progress).controlSize(.small)
            }
            if let summary = programme.summary {
                Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(4)
            }
        }
    }
}
