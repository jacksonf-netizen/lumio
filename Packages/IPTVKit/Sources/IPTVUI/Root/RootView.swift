import SwiftUI
import IPTVCore

public enum SidebarItem: String, CaseIterable, Identifiable, Hashable, Sendable {
    case recents, liveTV, guide, movies, series, favorites, search, settings

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .recents: "Recents"
        case .liveTV: "Live TV"
        case .guide: "Guide"
        case .movies: "Movies"
        case .series: "Series"
        case .favorites: "Favorites"
        case .search: "Search"
        case .settings: "Settings"
        }
    }

    /// Pages that show a live preview of the selected channel.
    static let withPreview: Set<SidebarItem> = [.recents, .liveTV, .guide, .favorites]

    var systemImage: String {
        switch self {
        case .recents: "clock.arrow.circlepath"
        case .liveTV: "tv"
        case .guide: "calendar.day.timeline.left"
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
    public static var secondsSinceLaunch: Double { Date().timeIntervalSince(ProcessInfo.processInfo.launchDate) }

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        ZStack {
            NavigationSplitView {
                List(selection: $state.section) {
                    Section {
                        ForEach([SidebarItem.recents, .liveTV, .guide, .movies, .series]) { item in
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
            } detail: {
                detail(for: state.section)
            }
            .toolbar {
                ToolbarItem(placement: .status) {
                    SyncActivityIndicator(model: state.providers)
                }
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
            case .guide:
                GuideView(state: state)
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
    @State private var movies: [VODItem] = []
    @State private var series: [VODItem] = []
    @State private var path: [VODRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch tab {
                case .channels:
                    GuideView(state: state, scope: .favorites)
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

/// Subtle toolbar indicator while providers refresh in the background.
struct SyncActivityIndicator: View {
    let model: ProvidersViewModel

    var body: some View {
        if model.isSyncing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(model.syncSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("Updating in the background. Everything stays usable.")
            .transition(.opacity)
        }
    }
}

struct NoProvidersView: View {
    let openSettings: () -> Void

    var body: some View {
        EmptyState("No Providers", systemImage: "antenna.radiowaves.left.and.right",
                   message: "Add your Xtream Codes account to get started.") {
            Button("Add Provider…", action: openSettings)
                .buttonStyle(.borderedProminent)
        }
    }
}
