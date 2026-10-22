import SwiftUI
import IPTVCore

/// Movie page: artwork, details, Play / Resume, favorite, watched.
struct MovieDetailView: View {
    let state: AppState
    let item: VODItem
    @State private var movie: Movie?
    @State private var details: MovieDetails?
    @State private var progress: WatchProgress?
    @State private var isFavorite = false
    @State private var askResume = false
    @State private var loadError: String?

    var body: some View {
        DetailScaffold(backdrop: details?.backdropURL ?? item.posterURL, poster: details?.posterURL ?? item.posterURL) {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.displayName).font(.largeTitle.bold())
                metaLine
                if let progress, !progress.isWatched, progress.positionSeconds >= 30 {
                    ProgressView(value: progress.positionSeconds, total: max(progress.durationSeconds ?? 1, progress.positionSeconds))
                        .frame(maxWidth: 360)
                }
                HStack(spacing: 10) {
                    Button { play() } label: {
                        Label(resumeLabel, systemImage: "play.fill").frame(minWidth: 120)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
                    if canResume {
                        Button("Start Over") { start(at: nil) }.controlSize(.large)
                    }
                    Button { toggleFavorite() } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                    }
                    .controlSize(.large)
                    .help(isFavorite ? "Remove from Favorites" : "Add to Favorites")
                    Button { toggleWatched() } label: {
                        Image(systemName: progress?.isWatched == true ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .controlSize(.large)
                    .help(progress?.isWatched == true ? "Mark as unwatched" : "Mark as watched")
                }
                if let plot = details?.plot ?? movie?.plot {
                    Text(plot).font(.body).foregroundStyle(.secondary).frame(maxWidth: 640, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let director = details?.director { LabeledLine(label: "Director", value: director) }
                    if let cast = details?.cast { LabeledLine(label: "Cast", value: cast) }
                }
                if let loadError {
                    Text(loadError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(item.displayName)
        .confirmationDialog("Resume watching?", isPresented: $askResume) {
            Button("Resume from \(VODScrubber.format(progress?.positionSeconds ?? 0))") { start(at: progress?.positionSeconds) }
            Button("Start from the Beginning") { start(at: nil) }
        }
        .task { await load() }
        .onChange(of: state.vodProgressVersion) { Task { await loadProgress() } }
    }

    private var canResume: Bool {
        guard let progress else { return false }
        return !progress.isWatched && progress.positionSeconds >= 30
    }

    private var resumeLabel: String { canResume ? "Resume" : "Play" }

    @ViewBuilder
    private var metaLine: some View {
        let duration = details?.durationSeconds ?? movie?.durationSeconds
        HStack(spacing: 10) {
            if let year = item.year { Text(String(year)) }
            if let duration { Text("\(duration / 3600 > 0 ? "\(duration / 3600) h " : "")\(duration / 60 % 60) min") }
            if let genre = details?.genre { Text(genre).lineLimit(1) }
            if let rating = details?.rating ?? item.rating { Label(String(format: "%.1f", rating), systemImage: "star.fill") }
            Text(state.live.providerName(item.providerID))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func load() async {
        movie = try? await state.vod.movie(providerID: item.providerID, streamID: item.itemID)
        isFavorite = (try? await state.library.isFavorite(kind: .movie, providerID: item.providerID, itemID: String(item.itemID))) ?? false
        await loadProgress()
        // Details come from the provider; show what we have meanwhile and cache the result.
        do {
            guard let provider = try state.environment.providers.repository.provider(id: item.providerID) else { return }
            let source = try state.environment.sources.source(for: provider)
            let fetched = try await source.fetchMovieDetails(streamID: item.itemID)
            details = fetched
            try? state.environment.catalog.updateMovieDetails(fetched, providerID: item.providerID, streamID: item.itemID)
        } catch {
            loadError = "Couldn't load full details: \(CredentialRedactor.redact((error as? LocalizedError)?.errorDescription ?? String(describing: error)))"
        }
    }

    private func loadProgress() async {
        progress = try? await state.vod.progress(kind: .movie, providerID: item.providerID, itemID: String(item.itemID))
    }

    private func play() {
        if canResume { askResume = true } else { start(at: nil) }
    }

    private func start(at position: Double?) {
        guard let playable = try? state.environment.items.movieItem(providerID: item.providerID, streamID: item.itemID, startPosition: position)
        else { return }
        state.playVOD(playable, kind: .movie, providerID: item.providerID, itemID: String(item.itemID))
    }

    private func toggleFavorite() {
        isFavorite.toggle()
        let on = isFavorite
        Task { try? await state.library.setFavorite(on, kind: .movie, providerID: item.providerID, itemID: String(item.itemID)) }
    }

    private func toggleWatched() {
        let watched = !(progress?.isWatched ?? false)
        Task {
            try? await state.library.setWatched(watched, kind: .movie, providerID: item.providerID, itemID: String(item.itemID))
            await loadProgress()
        }
    }
}

/// Series page: seasons and episodes with progress, Play next / Resume.
struct SeriesDetailView: View {
    let state: AppState
    let item: VODItem
    @State private var series: Series?
    @State private var seasons: [Season] = []
    @State private var episodes: [Episode] = []
    @State private var progress: [String: WatchProgress] = [:]
    @State private var season = 1
    @State private var next: (Episode, WatchProgress?)?
    @State private var isFavorite = false
    @State private var loading = true
    @State private var loadError: String?
    @State private var resumeTarget: Episode?

    var body: some View {
        DetailScaffold(backdrop: item.posterURL, poster: series?.coverURL ?? item.posterURL) {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.displayName).font(.largeTitle.bold())
                HStack(spacing: 10) {
                    if let year = item.year { Text(String(year)) }
                    Text("\(seasons.count) season\(seasons.count == 1 ? "" : "s")")
                    if let rating = item.rating { Label(String(format: "%.1f", rating), systemImage: "star.fill") }
                    Text(state.live.providerName(item.providerID))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if let next {
                        Button { play(next.0, resumeFrom: next.1) } label: {
                            Label(nextLabel(next), systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                    Button { toggleFavorite() } label: { Image(systemName: isFavorite ? "heart.fill" : "heart") }
                        .controlSize(.large)
                }
                if let plot = series?.plot {
                    Text(plot).foregroundStyle(.secondary).frame(maxWidth: 640, alignment: .leading)
                }
                if let loadError { Text(loadError).font(.caption).foregroundStyle(.orange) }
            }
        } below: {
            VStack(alignment: .leading, spacing: 12) {
                if seasons.count > 1 {
                    Picker("Season", selection: $season) {
                        ForEach(seasons, id: \.seasonNumber) { season in
                            Text(season.name ?? "Season \(season.seasonNumber)").tag(season.seasonNumber)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 600)
                }
                if loading && episodes.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                }
                ForEach(episodes.filter { $0.seasonNumber == season }, id: \.episodeID) { episode in
                    EpisodeRow(episode: episode, progress: progress[episode.episodeID],
                               play: { play(episode, resumeFrom: progress[episode.episodeID]) },
                               toggleWatched: { toggleWatched(episode) })
                }
            }
        }
        .navigationTitle(item.displayName)
        .confirmationDialog("Resume watching?", isPresented: Binding(get: { resumeTarget != nil }, set: { if !$0 { resumeTarget = nil } })) {
            if let episode = resumeTarget {
                Button("Resume from \(VODScrubber.format(progress[episode.episodeID]?.positionSeconds ?? 0))") {
                    start(episode, at: progress[episode.episodeID]?.positionSeconds)
                }
                Button("Start from the Beginning") { start(episode, at: nil) }
            }
        }
        .task { await load() }
        .onChange(of: state.vodProgressVersion) { Task { await loadProgress() } }
    }

    private func nextLabel(_ next: (Episode, WatchProgress?)) -> String {
        let code = "S\(next.0.seasonNumber) E\(next.0.episodeNumber)"
        if let progress = next.1, !progress.isWatched, progress.positionSeconds >= 30 { return "Resume \(code)" }
        return "Play \(code)"
    }

    private func load() async {
        series = try? await state.vod.series(providerID: item.providerID, seriesID: item.itemID)
        isFavorite = (try? await state.library.isFavorite(kind: .series, providerID: item.providerID, itemID: String(item.itemID))) ?? false
        await loadCached()
        do {
            guard let provider = try state.environment.providers.repository.provider(id: item.providerID) else { return }
            let source = try state.environment.sources.source(for: provider)
            let details = try await source.fetchSeriesDetails(seriesID: item.itemID)
            try state.environment.catalog.replaceSeriesDetails(details, providerID: item.providerID, seriesID: item.itemID)
            await loadCached()
        } catch {
            loadError = "Couldn't refresh episodes: \(CredentialRedactor.redact((error as? LocalizedError)?.errorDescription ?? String(describing: error)))"
        }
        loading = false
    }

    private func loadCached() async {
        seasons = (try? await state.vod.seasons(providerID: item.providerID, seriesID: item.itemID)) ?? []
        episodes = (try? await state.vod.episodes(providerID: item.providerID, seriesID: item.itemID)) ?? []
        series = (try? await state.vod.series(providerID: item.providerID, seriesID: item.itemID)) ?? series
        await loadProgress()
        if !seasons.contains(where: { $0.seasonNumber == season }), let first = seasons.first {
            season = next?.0.seasonNumber ?? first.seasonNumber
        }
    }

    private func loadProgress() async {
        progress = (try? await state.vod.episodeProgress(providerID: item.providerID, seriesID: item.itemID)) ?? [:]
        next = try? await state.vod.nextEpisode(providerID: item.providerID, seriesID: item.itemID)
    }

    private func play(_ episode: Episode, resumeFrom progress: WatchProgress?) {
        if let progress, !progress.isWatched, progress.positionSeconds >= 30 {
            resumeTarget = episode
        } else {
            start(episode, at: nil)
        }
    }

    private func start(_ episode: Episode, at position: Double?) {
        guard let playable = try? state.environment.items.episodeItem(providerID: item.providerID, episodeID: episode.episodeID,
                                                                       startPosition: position)
        else { return }
        state.playVOD(playable, kind: .episode, providerID: item.providerID, itemID: episode.episodeID)
    }

    private func toggleWatched(_ episode: Episode) {
        let watched = !(progress[episode.episodeID]?.isWatched ?? false)
        Task {
            try? await state.library.setWatched(watched, kind: .episode, providerID: item.providerID, itemID: episode.episodeID)
            await loadProgress()
        }
    }

    private func toggleFavorite() {
        isFavorite.toggle()
        let on = isFavorite
        Task { try? await state.library.setFavorite(on, kind: .series, providerID: item.providerID, itemID: String(item.itemID)) }
    }
}

private struct EpisodeRow: View {
    let episode: Episode
    let progress: WatchProgress?
    let play: () -> Void
    let toggleWatched: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5))
                RemoteImage(url: episode.imageURL, maxPixelSize: 320, contentMode: .fill, placeholder: "play.rectangle")
                if hovering { Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white) }
            }
            .frame(width: 170, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) {
                if let progress, progress.positionSeconds > 0, let duration = progress.durationSeconds, duration > 0 {
                    GeometryReader { geometry in
                        VStack {
                            Spacer()
                            Rectangle().fill(progress.isWatched ? Color.green : Color.accentColor)
                                .frame(width: geometry.size.width * (progress.isWatched ? 1 : min(1, progress.positionSeconds / duration)), height: 4)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(episode.episodeNumber). \(episode.title)").font(.headline).lineLimit(1)
                    if progress?.isWatched == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                }
                HStack(spacing: 8) {
                    if let duration = episode.durationSeconds { Text("\(duration / 60) min") }
                    if let date = episode.airDate { Text(date) }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let plot = episode.plot { Text(plot).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
            }
            Spacer()
        }
        .padding(8)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: play)
        .contextMenu {
            Button("Play", action: play)
            Button(progress?.isWatched == true ? "Mark as Unwatched" : "Mark as Watched", action: toggleWatched)
        }
    }
}

/// Backdrop + poster + content layout shared by detail pages.
struct DetailScaffold<Content: View, Below: View>: View {
    let backdrop: URL?
    let poster: URL?
    @ViewBuilder let content: Content
    @ViewBuilder let below: Below

    init(backdrop: URL?, poster: URL?, @ViewBuilder content: () -> Content, @ViewBuilder below: () -> Below = { EmptyView() }) {
        self.backdrop = backdrop
        self.poster = poster
        self.content = content()
        self.below = below()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: backdrop, maxPixelSize: 1200, contentMode: .fill, placeholder: "film")
                        .frame(height: 360)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .blur(radius: 30)
                        .opacity(0.45)
                    LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor)], startPoint: .top, endPoint: .bottom)
                    HStack(alignment: .bottom, spacing: 24) {
                        RemoteImage(url: poster, maxPixelSize: 600, contentMode: .fill, placeholder: "film")
                            .frame(width: 200, height: 300)
                            .background(.quaternary.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(radius: 12, y: 6)
                        content
                    }
                    .padding(24)
                }
                below.padding(.horizontal, 24)
            }
            .padding(.bottom, 24)
        }
    }
}

private struct LabeledLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value).lineLimit(3)
        }
        .font(.callout)
        .frame(maxWidth: 640, alignment: .leading)
    }
}
