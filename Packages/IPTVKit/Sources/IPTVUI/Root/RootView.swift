import SwiftUI
import IPTVCore

public enum SidebarItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    case recents, liveTV, movies, series, favorites, search, settings

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .recents: "Recents"
        case .liveTV: "Live TV"
        case .movies: "Movies"
        case .series: "Series"
        case .favorites: "Favorites"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    /// Pages that show a live preview of the selected channel.
    static let withPreview: Set<SidebarItem> = [.recents, .liveTV, .favorites]

    var systemImage: String {
        switch self {
        case .recents: "clock.arrow.circlepath"
        case .liveTV: "tv"
        case .movies: "film"
        case .series: "play.rectangle.on.rectangle"
        case .favorites: "star"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

/// Main window: sidebar + detail, with the player as a full-window overlay.
public struct RootView: View {
    @Bindable private var state: AppState
    /// Seconds from process start to the main window's first appearance (launch performance).
    nonisolated(unsafe) public static var firstAppearance: Double?
    nonisolated public static var secondsSinceLaunch: Double { Date().timeIntervalSince(ProcessInfo.processInfo.launchDate) }

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        ZStack {
            NavigationSplitView {
                List(selection: $state.section) {
                    Section {
                        ForEach([SidebarItem.recents, .liveTV, .movies, .series]) { item in
                            Label(item.title, systemImage: item.systemImage).tag(item)
                        }
                    }
                    Section {
                        ForEach([SidebarItem.favorites, .search]) { item in
                            Label(item.title, systemImage: item.systemImage).tag(item)
                        }
                    }
                    Section {
                        Label(SidebarItem.settings.title, systemImage: SidebarItem.settings.systemImage)
                            .tag(SidebarItem.settings)
                    }
                }
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
                // Background refreshes show at the foot of the sidebar, like Mail's activity. (In
                // the toolbar it took the space Settings needs for its tabs.)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    SyncActivityIndicator(model: state.providers)
                        .animation(.easeInOut(duration: 0.2), value: state.providers.isSyncing)
                }
            } detail: {
                detail(for: state.section)
            }
            // The split view can end up wider than the window (its columns don't always shrink with
            // it). Report the window's size here so the player on top is sized to the window, not
            // to the split view.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)

            if state.isPlayerPresented {
                PlayerScreen(state: state)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(1)
            }
            // Multiview takes over the window like the player, from a playing stream.
            if state.isMultiviewPresented {
                MultiviewScreen(model: state.multiview, state: state)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.isPlayerPresented)
        .animation(.easeInOut(duration: 0.2), value: state.isMultiviewPresented)
        .onAppear {
            if RootView.firstAppearance == nil {
                RootView.firstAppearance = RootView.secondsSinceLaunch
                if ProcessInfo.processInfo.environment["IPTV_TRACE_LAUNCH"] != nil {
                    print(String(format: "LAUNCH %6.0f ms  RootView appeared", (RootView.firstAppearance ?? 0) * 1000)); fflush(stdout)
                }
                Log.app.info("First window content after \(RootView.firstAppearance ?? 0, format: .fixed(precision: 3)) s")
            }
        }
        .onChange(of: state.section) { old, new in
            // Leaving the pages with a live preview stops it so it doesn't hold a connection.
            if SidebarItem.withPreview.contains(old) && !SidebarItem.withPreview.contains(new) {
                Task { await state.hub.stopPreview() }
            }
        }
    }

    @ViewBuilder
    private func detail(for item: SidebarItem) -> some View {
        if item != .settings, state.providers.loaded, state.providers.providers.isEmpty {
            NoProvidersView { state.section = .settings }
        } else {
            switch item {
            case .recents:
                GuideView(state: state, scope: .recents)
            case .liveTV:
                LiveTVView(model: state.live, state: state)
            case .favorites:
                FavoritesView(state: state)
            case .settings:
                SettingsView(state: state)
            case .movies:
                VODHomeView(state: state, kind: .movie)
            case .series:
                VODHomeView(state: state, kind: .series)
            case .search:
                SearchView(state: state)
            }
        }
    }
}

/// Favorites: channels as a reorderable guide, plus favorite movies and series.
struct FavoritesView: View {
    enum Tab: String, CaseIterable {
        case channels = "Channels", movies = "Movies", series = "Series"
    }

    let state: AppState
    @State private var tab: Tab = .channels
    /// Guide until the user picks List; remembered after that.
    @AppStorage("favoritesLayout") private var layout: ChannelLayout = .guide
    @State private var movies: [VODItem] = []
    @State private var series: [VODItem] = []
    @State private var path: [VODRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch tab {
                case .channels:
                    switch layout {
                    case .guide: GuideView(state: state, scope: .favorites)
                    case .list: FavoriteChannelList(state: state)
                    }
                case .movies:
                    posters(movies, kind: "Movies", icon: "film")
                case .series:
                    posters(series, kind: "Series", icon: "play.rectangle.on.rectangle")
                }
            }
            .navigationTitle("Favorites")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: $tab) {
                        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if tab == .channels {
                    ToolbarItem(placement: .primaryAction) {
                        ChannelLayoutPicker(layout: $layout)
                    }
                }
            }
            .navigationDestination(for: VODRoute.self) { route in
                switch route {
                case .movie(let item): MovieDetailView(state: state, item: item)
                case .series(let item): SeriesDetailView(state: state, item: item)
                case .category: EmptyView()
                }
            }
        }
        .task { await load() }
        .onChange(of: path.isEmpty) { _, empty in if empty { Task { await load() } } }
    }

    @ViewBuilder
    private func posters(_ items: [VODItem], kind: String, icon: String) -> some View {
        if items.isEmpty {
            EmptyState("No Favorite \(kind)", systemImage: icon,
                       message: "Use the heart on a \(kind == "Movies" ? "movie" : "series") page to add it here.")
        } else {
            PosterGrid(items: items, state: state) { item in
                path.append(item.kind == .movie ? .movie(item) : .series(item))
            }
        }
    }

    private func load() async {
        movies = (try? await state.vod.favorites(.movie)) ?? []
        series = (try? await state.vod.favorites(.series)) ?? []
    }
}

/// Small activity row at the bottom of the sidebar while providers refresh in the background.
struct SyncActivityIndicator: View {
    let model: ProvidersViewModel

    var body: some View {
        if model.isSyncing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.syncTitle).font(.caption.weight(.medium))
                    if let detail = model.syncDetail {
                        Text(detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .help("Updating channels, movies and the guide in the background. Everything stays usable.")
            .transition(.opacity)
        }
    }
}

struct NoProvidersView: View {
    let openSettings: () -> Void

    var body: some View {
        EmptyState("No Providers", systemImage: "antenna.radiowaves.left.and.right",
                   message: "Lumio doesn't include any channels. Add the Xtream Codes login (server address, username and password) from your own IPTV provider to get started.") {
            Button("Add Provider…", action: openSettings)
                .buttonStyle(.borderedProminent)
        }
    }
}
