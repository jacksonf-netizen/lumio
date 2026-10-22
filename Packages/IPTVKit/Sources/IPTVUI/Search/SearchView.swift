import SwiftUI
import IPTVCore

/// Global search across channels, guide programmes, movies and series.
struct SearchView: View {
    let state: AppState
    @State private var query = ""
    @State private var results = SearchResults()
    @State private var searching = false
    @State private var path: [VODRoute] = []
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search channels, programmes, movies and series", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                    if searching {
                        ProgressView().controlSize(.small)
                    } else if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Clear search")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 2))
                .animation(.easeOut(duration: 0.15), value: focused)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    EmptyState("Search", systemImage: "magnifyingglass",
                               message: "Type part of a name. \"sky spo\" finds Sky Sports; accents and case don't matter.")
                } else if results.isEmpty && !searching {
                    EmptyState("No Results", systemImage: "magnifyingglass", message: "Nothing matches “\(query)”.")
                } else {
                    resultsList
                }
            }
            .navigationTitle("Search")
            .navigationDestination(for: VODRoute.self) { route in
                switch route {
                case .movie(let item): MovieDetailView(state: state, item: item)
                case .series(let item): SeriesDetailView(state: state, item: item)
                case .category(let category):
                    CategoryGridView(state: state, kind: category.kind == .movie ? .movie : .series, category: category, filter: .all) { item in
                        path.append(item.kind == .movie ? .movie(item) : .series(item))
                    }
                }
            }
        }
        .onAppear { focused = true }
        .task(id: query) {
            let text = query
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                results = SearchResults()
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            searching = true
            let found = (try? await SearchRepository(database: state.environment.database).search(text)) ?? SearchResults()
            guard !Task.isCancelled else { return }
            results = found
            searching = false
        }
    }

    /// With more than one provider, results are grouped under each provider (in priority order).
    private var providerGroups: [(provider: ProviderID, results: SearchResults)]? {
        let enabled = state.providers.providers.filter(\.isEnabled)
        guard enabled.count > 1 else { return nil }
        let groups = results.grouped(by: enabled.map(\.id))
        return groups.count > 1 ? groups : nil
    }

    private var resultsList: some View {
        ScrollView {
            if let groups = providerGroups {
                LazyVStack(alignment: .leading, spacing: 32) {
                    ForEach(groups, id: \.provider) { group in
                        VStack(alignment: .leading, spacing: 18) {
                            ProviderHeader(name: state.live.providerName(group.provider), count: group.results.count)
                            sections(group.results)
                        }
                    }
                }
                .padding(.bottom, 20)
            } else {
                LazyVStack(alignment: .leading, spacing: 24) {
                    sections(results)
                }
                .padding(.bottom, 20)
            }
        }
    }

    @ViewBuilder
    private func sections(_ results: SearchResults) -> some View {
        if !results.channels.isEmpty {
            section("Channels") {
                ForEach(results.channels) { channel in
                    HStack(spacing: 4) {
                        Button { state.watch(channel, in: results.channels) } label: {
                            ChannelRow(channel: channel, nowNext: channel.epg.flatMap { state.live.nowNext[$0] })
                        }
                        .buttonStyle(RowButtonStyle())
                        FavoriteButton(isOn: channel.isFavorite) { toggleFavorite(channel) }
                    }
                    .contextMenu { channelMenu(channel, in: results.channels) }
                    .onAppear { state.live.needNowNext(for: channel.epg) }
                }
            }
        }
        if !results.programmes.isEmpty {
            section("Programmes") {
                ForEach(results.programmes) { hit in
                    ProgrammeHitRow(hit: hit) {
                        if let channel = hit.channel { state.watch(channel) }
                    }
                    .contextMenu {
                        if let channel = hit.channel { channelMenu(channel, in: [channel]) }
                    }
                }
            }
        }
        if !results.movies.isEmpty {
            PosterShelf(title: "Movies", items: results.movies, state: state) { path.append(.movie($0)) }
        }
        if !results.series.isEmpty {
            PosterShelf(title: "Series", items: results.series, state: state) { path.append(.series($0)) }
        }
    }

    @ViewBuilder
    private func channelMenu(_ channel: ChannelListItem, in list: [ChannelListItem]) -> some View {
        Button("Watch \(channel.name)") { state.watch(channel, in: list) }
        Button(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites") { toggleFavorite(channel) }
    }

    /// Adds or removes the channel, and updates the star in the results straight away.
    private func toggleFavorite(_ channel: ChannelListItem) {
        Task {
            guard let on = try? await state.library.toggleFavorite(channel) else { return }
            for index in results.channels.indices where results.channels[index].id == channel.id {
                results.channels[index].isFavorite = on
            }
            for index in results.programmes.indices where results.programmes[index].channel?.id == channel.id {
                results.programmes[index].channel?.isFavorite = on
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ShelfHeader(title: title)
            VStack(alignment: .leading, spacing: 2) { content() }.padding(.horizontal, 16)
        }
    }
}

/// Star next to a channel result: filled when it's a favorite.
private struct FavoriteButton: View {
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "star.fill" : "star")
                .font(.body)
                .foregroundStyle(isOn ? AnyShapeStyle(.yellow) : AnyShapeStyle(hovering ? .secondary : .tertiary))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isOn ? "Remove from Favorites" : "Add to Favorites")
        .accessibilityLabel(isOn ? "Remove from Favorites" : "Add to Favorites")
    }
}

/// Provider name above its group of results.
private struct ProviderHeader: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(name).font(.title.bold())
            Text("\(count) result\(count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .overlay(alignment: .bottom) {
            Divider().padding(.horizontal, 20).offset(y: 8)
        }
    }
}

private struct ProgrammeHitRow: View {
    let hit: ProgrammeHit
    let watch: () -> Void

    var body: some View {
        let now = Date()
        let isOn = hit.programme.start <= now && hit.programme.stop > now
        HStack(spacing: 12) {
            VStack(alignment: .trailing) {
                Text(hit.programme.start.formatted(.dateTime.weekday(.abbreviated)))
                Text(hit.programme.start.formatted(date: .omitted, time: .shortened))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 64, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(hit.programme.title).font(.body.weight(.medium))
                    if isOn {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(0.5)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .foregroundStyle(.white)
                    }
                }
                Text([hit.channel?.name, hit.programme.subtitle ?? hit.programme.episodeNumber].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isOn, hit.channel != nil {
                Button("Watch", action: watch).controlSize(.small)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}
