import SwiftUI
import IPTVCore

/// Where to navigate inside Movies / Series.
enum VODRoute: Hashable {
    case category(IPTVCore.Category)
    case movie(VODItem)
    case series(VODItem)
}

/// Movies or Series: home rows (Continue Watching, Recently Added, categories) and category grids.
struct VODHomeView: View {
    let state: AppState
    let kind: ContentKind
    @State private var path: [VODRoute] = []
    @State private var categories: [IPTVCore.Category] = []
    @State private var rows: [(IPTVCore.Category, [VODItem])] = []
    @State private var recent: [VODItem] = []
    @State private var recents: [ContinueItem] = []
    @State private var filter: ProviderFilter = .all
    @State private var search = ""
    @State private var searchResults: [VODItem] = []
    @State private var loaded = false

    private var vodKind: VODItem.Kind { kind == .movie ? .movie : .series }
    private var title: String { kind == .movie ? "Movies" : "Series" }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if loaded && categories.isEmpty && recent.isEmpty {
                    EmptyState("No \(title)", systemImage: kind == .movie ? "film" : "play.rectangle.on.rectangle",
                               message: "Your providers haven't listed any \(title.lowercased()) yet, or they're still syncing.")
                } else if !search.isEmpty {
                    PosterGrid(items: searchResults, state: state) { open($0) }
                } else {
                    home
                }
            }
            .navigationTitle(title)
            .searchable(text: $search, placement: .toolbar, prompt: "Search \(title.lowercased())")
            .toolbar {
                ToolbarItem {
                    ProviderFilterPicker(filter: $filter, providers: state.providers.providers)
                }
            }
            .navigationDestination(for: VODRoute.self) { route in
                switch route {
                case .category(let category):
                    CategoryGridView(state: state, kind: vodKind, category: category, filter: filter) { open($0) }
                case .movie(let item):
                    MovieDetailView(state: state, item: item)
                case .series(let item):
                    SeriesDetailView(state: state, item: item)
                }
            }
        }
        .task(id: "\(filter)") { await load() }
        .task(id: search) {
            guard !search.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(250))
            searchResults = (try? await state.vod.items(vodKind, filter: filter, search: search, limit: 300)) ?? []
        }
        .onChange(of: state.vodProgressVersion) { Task { await loadRecents() } }
        .onChange(of: state.providers.syncing.isEmpty) { _, idle in if idle { Task { await load() } } }
    }

    private var home: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !recents.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        ShelfHeader(title: "Recently Watched")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(recents) { item in
                                    RecentCard(item: item) { item.canResume ? resume(item) : showDetails(item) }
                                        .contextMenu { recentMenu(item) }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 6) // room for the hover lift
                        }
                    }
                }
                if !recent.isEmpty {
                    PosterShelf(title: "Recently Added", items: recent, state: state, open: open)
                }
                ForEach(rows, id: \.0.categoryID) { category, items in
                    PosterShelf(title: category.name, items: items, state: state, open: open) {
                        path.append(.category(category))
                    }
                    .contextMenu {
                        Button("Hide Category") { hide(category) }
                    }
                }
                if categories.count > rows.count {
                    ShelfHeader(title: "All Categories")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(categories, id: \.self) { category in
                            Button { path.append(.category(category)) } label: {
                                HStack {
                                    Text(category.name).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                            }
                            .buttonStyle(TileButtonStyle())
                            .contextMenu {
                                Button("Hide Category") { hide(category) }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 20)
        }
    }

    private func load() async {
        categories = (try? await state.vod.categories(vodKind, filter: filter)) ?? []
        recent = (try? await state.vod.items(vodKind, filter: filter, recent: true, limit: 30)) ?? []
        var loadedRows: [(IPTVCore.Category, [VODItem])] = []
        for category in categories.prefix(8) {
            let items = (try? await state.vod.items(vodKind, category: category, filter: filter, limit: 24)) ?? []
            if !items.isEmpty { loadedRows.append((category, items)) }
        }
        rows = loadedRows
        await loadRecents()
        loaded = true
    }

    private func loadRecents() async {
        recents = (try? await state.vod.recentlyWatched(vodKind)) ?? []
    }

    // MARK: Recently Watched

    @ViewBuilder
    private func recentMenu(_ item: ContinueItem) -> some View {
        if item.canResume {
            Button("Resume") { resume(item) }
            Button("Play from the Beginning") { startOver(item) }
        } else {
            Button("Play") { startOver(item) }
        }
        Button(kind == .movie ? "Show Movie Details" : "Show Series") { showDetails(item) }
        Divider()
        Button("Remove from Recently Watched") { removeRecent(item) }
        Button("Clear Recently Watched") { clearRecents() }
    }

    /// Opens the movie, or the episode's series.
    private func showDetails(_ item: ContinueItem) {
        let id = item.kind == .movie ? Int(item.itemID) : item.seriesID
        guard let id else { return }
        Task {
            guard let found = try? await state.vod.items(vodKind, keys: [(item.providerID, id)], includeHidden: true).first else { return }
            open(found)
        }
    }

    private func startOver(_ item: ContinueItem) {
        var fromStart = item
        fromStart.position = 0
        resume(fromStart)
    }

    private func removeRecent(_ item: ContinueItem) {
        let library = state.library
        let itemID = item.kind == .movie ? item.itemID : String(item.seriesID ?? -1)
        recents.removeAll { $0.id == item.id }
        Task {
            try? await library.removeRecent(kind: item.kind == .movie ? .movie : .series, providerID: item.providerID, itemID: itemID)
            await loadRecents()
        }
    }

    private func clearRecents() {
        let library = state.library
        let kinds: [LibraryItemKind] = kind == .movie ? [.movie] : [.series, .episode]
        recents = []
        Task { try? await library.clearRecents(kinds) }
    }

    private func hide(_ category: IPTVCore.Category) {
        Task {
            try? await state.library.setCategoryHidden(true, providerID: category.providerID, kind: category.kind,
                                                       categoryID: category.categoryID)
            await load()
        }
    }

    private func open(_ item: VODItem) {
        path.append(item.kind == .movie ? .movie(item) : .series(item))
    }

    private func resume(_ item: ContinueItem) {
        let builder = state.environment.items
        if item.kind == .movie, let streamID = Int(item.itemID),
           let playable = try? builder.movieItem(providerID: item.providerID, streamID: streamID, startPosition: item.position) {
            state.playVOD(playable, kind: .movie, providerID: item.providerID, itemID: item.itemID)
        } else if item.kind == .episode,
                  let playable = try? builder.episodeItem(providerID: item.providerID, episodeID: item.itemID, startPosition: item.position) {
            state.playVOD(playable, kind: .episode, providerID: item.providerID, itemID: item.itemID)
        }
    }
}

// MARK: - Shelves and cards

/// Artwork stand-in: a soft gradient with the title, so missing posters still look intentional.
struct PosterPlaceholder: View {
    let title: String
    let systemImage: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.primary.opacity(0.10), Color.primary.opacity(0.04)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .padding(12)
        }
    }
}

struct ShelfHeader: View {
    let title: String
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.title2.bold())
            Spacer()
            if let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text("See All")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 20)
    }
}

struct PosterShelf: View {
    let title: String
    let items: [VODItem]
    let state: AppState
    let open: (VODItem) -> Void
    var seeAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: title, action: seeAll)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        PosterCard(item: item, width: 150) { open(item) }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct PosterCard: View {
    let item: VODItem
    var width: CGFloat = 150
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottom) {
                    PosterPlaceholder(title: item.displayName, systemImage: item.kind == .movie ? "film" : "play.rectangle.on.rectangle")
                    RemoteImage(url: item.posterURL, maxPixelSize: 400, contentMode: .fill, placeholder: nil)
                    if let progress = item.progress, progress > 0 {
                        GeometryReader { geometry in
                            VStack {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.black.opacity(0.5))
                                    Rectangle().fill(progress >= 1 ? Color.green : Color.accentColor)
                                        .frame(width: geometry.size.width * min(1, progress))
                                }
                                .frame(height: 4)
                            }
                        }
                    }
                }
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(hovering ? 0.9 : 0), lineWidth: 2))
                .scaleEffect(hovering ? 1.04 : 1)
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 10 : 3, y: hovering ? 6 : 2)

                Text(item.displayName).font(.callout.weight(.medium)).lineLimit(2).frame(width: width, alignment: .leading)
                HStack(spacing: 6) {
                    if let year = item.year { Text(String(year)) }
                    if let rating = item.rating { Label(String(format: "%.1f", rating), systemImage: "star.fill") }
                    if item.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.pink) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// A Recently Watched entry: artwork, progress, and what playing it will do.
struct RecentCard: View {
    let item: ContinueItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    PosterPlaceholder(title: item.displayTitle, systemImage: item.kind == .movie ? "film" : "play.rectangle.on.rectangle")
                    RemoteImage(url: item.imageURL, maxPixelSize: 500, contentMode: .fill, placeholder: nil)
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
                    Image(systemName: item.canResume ? "play.circle.fill" : "info.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.white)
                        .opacity(hovering || item.canResume ? 1 : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if item.isWatched {
                        Label("Watched", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                    if item.canResume, let progress = item.progress {
                        GeometryReader { geometry in
                            VStack {
                                Spacer()
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.black.opacity(0.5))
                                    Rectangle().fill(Color.accentColor).frame(width: geometry.size.width * progress)
                                }
                                .frame(height: 4)
                            }
                        }
                    }
                }
                .frame(width: 260, height: 146)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor.opacity(hovering ? 0.9 : 0), lineWidth: 2))
                .scaleEffect(hovering ? 1.03 : 1)
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 10 : 3, y: hovering ? 6 : 2)
                Text(item.displayTitle).font(.callout.weight(.medium)).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 260, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(item.canResume ? "Resume" : "Show details")
    }

    private var detail: String {
        [item.subtitle, status].compactMap { $0 }.joined(separator: " · ")
    }

    private var status: String? {
        guard item.canResume else { return nil }
        guard let duration = item.duration else { return "Resume at \(VODScrubber.format(item.position))" }
        return "\(max(1, Int(max(0, duration - item.position) / 60))) min left"
    }
}

struct PosterGrid: View {
    let items: [VODItem]
    let state: AppState
    let open: (VODItem) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 18, alignment: .top)], spacing: 22) {
                ForEach(items) { item in
                    PosterCard(item: item, width: 150) { open(item) }
                }
            }
            .padding(20)
        }
    }
}

struct CategoryGridView: View {
    let state: AppState
    let kind: VODItem.Kind
    let category: IPTVCore.Category
    let filter: ProviderFilter
    let open: (VODItem) -> Void
    @State private var items: [VODItem] = []
    @State private var sortRecent = false

    var body: some View {
        PosterGrid(items: items, state: state, open: open)
            .navigationTitle(category.name)
            .toolbar {
                Picker("Sort", selection: $sortRecent) {
                    Text("Provider order").tag(false)
                    Text("Recently added").tag(true)
                }
                .pickerStyle(.menu)
            }
            .task(id: sortRecent) {
                items = (try? await state.vod.items(kind, category: category, filter: filter, recent: sortRecent)) ?? []
            }
    }
}
