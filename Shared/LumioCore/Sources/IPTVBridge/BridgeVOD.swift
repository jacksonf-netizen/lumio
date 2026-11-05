import Foundation
import IPTVCore

// Movies and Series over the bridge: `vod.*` requests. The rules are the core's (`VODCatalog`,
// `VODActions.swift`); this translates. Kotlin has a class for each type (BridgeModels.kt), and the
// fixtures in Tests/IPTVBridgeTests/Fixtures (vod_home.json, movie.json, series.json) keep both
// sides in step.

public struct VODItemDTO: Codable, Equatable, Sendable {
    /// movie or series.
    public var kind: String
    public var provider: String
    public var id: Int
    public var name: String
    public var poster: String?
    public var rating: Double?
    public var year: Int?
    /// 0–1 watched (movies), 1 when finished.
    public var progress: Double?
    public var favorite: Bool
}

/// A movie or episode in Recently Watched.
public struct ContinueDTO: Codable, Equatable, Sendable {
    /// movie or episode.
    public var kind: String
    public var provider: String
    /// The stream id (movie) or episode id.
    public var id: String
    public var title: String
    /// "S1 E3 · Title", for episodes.
    public var subtitle: String?
    public var image: String?
    public var position: Double
    public var duration: Double?
    public var series: Int?
    public var watched: Bool
    /// Play resumes from `position`.
    public var canResume: Bool
}

public struct VODCategoryDTO: Codable, Equatable, Sendable {
    public var provider: String
    public var id: String
    public var name: String
}

public struct VODShelfDTO: Codable, Equatable, Sendable {
    public var category: VODCategoryDTO
    public var items: [VODItemDTO]
}

public struct VODHomeDTO: Codable, Equatable, Sendable {
    public var recentlyWatched: [ContinueDTO]
    public var recentlyAdded: [VODItemDTO]
    public var shelves: [VODShelfDTO]
    public var categories: [VODCategoryDTO]
}

public struct ProgressDTO: Codable, Equatable, Sendable {
    public var position: Double
    public var duration: Double?
    public var watched: Bool
    public var canResume: Bool
}

public struct MovieDTO: Codable, Equatable, Sendable {
    public var provider: String
    public var providerName: String
    public var id: Int
    public var name: String
    public var poster: String?
    public var backdrop: String?
    public var year: Int?
    public var duration: Int?
    public var genre: String?
    public var rating: Double?
    public var plot: String?
    public var director: String?
    public var cast: String?
    public var favorite: Bool
    public var progress: ProgressDTO?
    /// Why the provider's full details couldn't be loaded (what the catalog has is shown).
    public var detailsError: String?
}

public struct SeasonDTO: Codable, Equatable, Sendable {
    public var number: Int
    public var name: String
}

public struct EpisodeDTO: Codable, Equatable, Sendable {
    public var id: String
    public var season: Int
    public var number: Int
    public var title: String
    public var duration: Int?
    public var plot: String?
    public var image: String?
    public var progress: ProgressDTO?
}

public struct SeriesDTO: Codable, Equatable, Sendable {
    public var provider: String
    public var providerName: String
    public var id: Int
    public var name: String
    public var cover: String?
    public var year: Int?
    public var rating: Double?
    public var plot: String?
    public var favorite: Bool
    public var seasons: [SeasonDTO]
    public var episodes: [EpisodeDTO]
    /// The episode Play offers: in progress, else the next unwatched.
    public var next: String?
    public var detailsError: String?
}

/// Search results across channels, guide programmes, movies and series (the core's SearchRepository).
public struct SearchDTO: Codable, Equatable, Sendable {
    public var channels: [ChannelDTO]
    public var programmes: [ProgrammeHitDTO]
    public var movies: [VODItemDTO]
    public var series: [VODItemDTO]
}

/// A programme that matched, with a channel showing it (when one does).
public struct ProgrammeHitDTO: Codable, Equatable, Sendable {
    public var programme: ProgrammeDTO
    public var channel: ChannelDTO?
}

// MARK: Conversions

extension VODItemDTO {
    init(_ item: VODItem) {
        kind = item.kind.rawValue
        provider = item.providerID.rawValue
        id = item.itemID
        name = item.displayName
        poster = item.posterURL.map { ServerAliases.shared.rewrite($0).absoluteString }
        rating = item.rating
        year = item.year
        progress = item.progress
        favorite = item.isFavorite
    }
}

extension ContinueDTO {
    init(_ item: ContinueItem) {
        kind = item.kind.rawValue
        provider = item.providerID.rawValue
        id = item.itemID
        title = VODItem.displayName(item.title)
        subtitle = item.subtitle
        image = item.imageURL.map { ServerAliases.shared.rewrite($0).absoluteString }
        position = item.position
        duration = item.duration
        series = item.seriesID
        watched = item.isWatched
        canResume = item.canResume
    }
}

extension VODCategoryDTO {
    init(_ category: IPTVCore.Category) {
        provider = category.providerID.rawValue
        id = category.categoryID
        name = category.name
    }
}

extension ProgressDTO {
    init(_ progress: WatchProgress) {
        position = progress.positionSeconds
        duration = progress.durationSeconds
        watched = progress.isWatched
        canResume = progress.canResume
    }
}

// MARK: Requests

extension BridgeCore {
    func vodRequest(_ method: String, _ params: Params) async throws -> any Encodable {
        let vod = VODCatalog(database: environment.database)
        let library = LibraryRepository(database: environment.database)
        switch method {
        case "vod.home":
            struct P: Decodable { var kind: String }
            let home = try await vod.home(try itemKind(try params.decode(P.self).kind))
            return VODHomeDTO(
                recentlyWatched: home.recentlyWatched.map(ContinueDTO.init),
                recentlyAdded: home.recentlyAdded.map(VODItemDTO.init),
                shelves: home.shelves.map { VODShelfDTO(category: VODCategoryDTO($0.category), items: $0.items.map(VODItemDTO.init)) },
                categories: home.categories.map(VODCategoryDTO.init))

        case "vod.category":
            // A page of a category: `offset` and `limit` (at most 500), in the provider's order.
            struct P: Decodable { var kind: String; var provider: String; var category: String; var offset: Int?; var limit: Int? }
            let p = try params.decode(P.self)
            let kind = try itemKind(p.kind)
            let category = try await vod.categories(kind).first { $0.providerID.rawValue == p.provider && $0.categoryID == p.category }
            guard let category else { return [VODItemDTO]() }
            return try await vod.items(kind, category: category, limit: min(p.limit ?? 200, 500), offset: p.offset ?? 0)
                .map(VODItemDTO.init)

        case "vod.search":
            struct P: Decodable { var kind: String; var query: String; var limit: Int? }
            let p = try params.decode(P.self)
            return try await vod.items(try itemKind(p.kind), search: p.query, limit: min(p.limit ?? 100, 300)).map(VODItemDTO.init)

        case "search.query":
            // Word prefixes, ignoring case and accents ("sky spo" finds Sky Sports), as on the Mac.
            struct P: Decodable { var text: String; var limit: Int? }
            let p = try params.decode(P.self)
            let found = try await SearchRepository(database: environment.database).search(p.text, limit: min(p.limit ?? 40, 100))
            return SearchDTO(
                channels: found.channels.map(ChannelDTO.init),
                programmes: found.programmes.map { ProgrammeHitDTO(programme: ProgrammeDTO($0.programme), channel: $0.channel.map(ChannelDTO.init)) },
                movies: found.movies.map(VODItemDTO.init),
                series: found.series.map(VODItemDTO.init))

        case "vod.movie":
            // What the catalog has; with `fetch`, the provider's full details first.
            struct P: Decodable { var provider: String; var id: Int; var fetch: Bool? }
            let p = try params.decode(P.self)
            let providerID = ProviderID(p.provider)
            var details: MovieDetails?
            var detailsError: String?
            if p.fetch == true {
                do {
                    details = try await environment.fetchMovieDetails(providerID: providerID, streamID: p.id)
                } catch {
                    detailsError = AppEnvironment.userMessage(for: error)
                }
            }
            guard let movie = try await vod.movie(providerID: providerID, streamID: p.id) else {
                throw BridgeError("That movie is no longer in the catalog.")
            }
            let progress = try await vod.progress(kind: .movie, providerID: providerID, itemID: String(p.id))
            let alias = { (url: URL?) in url.map { ServerAliases.shared.rewrite($0).absoluteString } }
            return MovieDTO(
                provider: p.provider, providerName: providerName(providerID), id: p.id, name: VODItem.displayName(movie.name),
                poster: alias(details?.posterURL ?? movie.posterURL), backdrop: alias(details?.backdropURL),
                year: movie.year, duration: details?.durationSeconds ?? movie.durationSeconds, genre: details?.genre,
                rating: details?.rating ?? movie.rating, plot: details?.plot ?? movie.plot, director: details?.director,
                cast: details?.cast,
                favorite: try await library.isFavorite(kind: .movie, providerID: providerID, itemID: String(p.id)),
                progress: progress.map(ProgressDTO.init), detailsError: detailsError)

        case "vod.series":
            struct P: Decodable { var provider: String; var id: Int; var fetch: Bool? }
            let p = try params.decode(P.self)
            let providerID = ProviderID(p.provider)
            var detailsError: String?
            if p.fetch == true {
                do {
                    try await environment.refreshSeriesDetails(providerID: providerID, seriesID: p.id)
                } catch {
                    detailsError = AppEnvironment.userMessage(for: error)
                }
            }
            guard let series = try await vod.series(providerID: providerID, seriesID: p.id) else {
                throw BridgeError("That series is no longer in the catalog.")
            }
            let progress = try await vod.episodeProgress(providerID: providerID, seriesID: p.id)
            let seasons = try await vod.seasons(providerID: providerID, seriesID: p.id)
            let episodes = try await vod.episodes(providerID: providerID, seriesID: p.id)
            // Seasons the provider didn't list on their own still show, from their episodes.
            var numbers = seasons.map(\.seasonNumber)
            for number in Set(episodes.map(\.seasonNumber)) where !numbers.contains(number) { numbers.append(number) }
            let names = Dictionary(seasons.map { ($0.seasonNumber, $0.name) }, uniquingKeysWith: { first, _ in first })
            let year = series.releaseDate.flatMap { Int($0.prefix(4)) }
            return SeriesDTO(
                provider: p.provider, providerName: providerName(providerID), id: p.id, name: VODItem.displayName(series.name),
                cover: series.coverURL.map { ServerAliases.shared.rewrite($0).absoluteString },
                year: (year ?? 0) > 1800 ? year : nil, rating: series.rating, plot: series.plot,
                favorite: try await library.isFavorite(kind: .series, providerID: providerID, itemID: String(p.id)),
                seasons: numbers.sorted().map { SeasonDTO(number: $0, name: (names[$0] ?? nil) ?? "Season \($0)") },
                episodes: episodes.map { episode in
                    EpisodeDTO(id: episode.episodeID, season: episode.seasonNumber, number: episode.episodeNumber,
                               title: episode.title, duration: episode.durationSeconds, plot: episode.plot,
                               image: episode.imageURL.map { ServerAliases.shared.rewrite($0).absoluteString },
                               progress: progress[episode.episodeID].map(ProgressDTO.init))
                },
                next: try await vod.nextEpisode(providerID: providerID, seriesID: p.id)?.0.episodeID,
                detailsError: detailsError)

        case "vod.play":
            // A movie (`id` its stream id) or an episode (`id` its episode id), from `position`
            // seconds, or the start. `title` and `subtitle` are what the player's banner shows.
            struct P: Decodable {
                var player: String?; var kind: String; var provider: String; var id: String
                var position: Double?; var title: String; var subtitle: String?
            }
            let p = try params.decode(P.self)
            guard let kind = LibraryItemKind(rawValue: p.kind), kind == .movie || kind == .episode else {
                throw BridgeError("Only movies and episodes can be played.")
            }
            let player = try await players.player(p.player)
            try await player.playVOD(kind: kind, providerID: ProviderID(p.provider), itemID: p.id, position: p.position,
                                     title: p.title, subtitle: p.subtitle)
            return await player.state

        case "vod.setFavorite":
            struct P: Decodable { var kind: String; var provider: String; var id: String; var favorite: Bool }
            let p = try params.decode(P.self)
            guard let kind = LibraryItemKind(rawValue: p.kind), kind == .movie || kind == .series else {
                throw BridgeError("Only movies and series can be favorites here.")
            }
            try await library.setFavorite(p.favorite, kind: kind, providerID: ProviderID(p.provider), itemID: p.id)
            return Empty()

        case "vod.setWatched":
            struct P: Decodable { var kind: String; var provider: String; var id: String; var watched: Bool }
            let p = try params.decode(P.self)
            guard let kind = LibraryItemKind(rawValue: p.kind), kind == .movie || kind == .episode else {
                throw BridgeError("Only movies and episodes can be marked watched.")
            }
            try await library.setWatched(p.watched, kind: kind, providerID: ProviderID(p.provider), itemID: p.id)
            emitVODChange()
            return Empty()

        case "vod.removeRecent":
            // A movie (its stream id) or a whole series (its series id).
            struct P: Decodable { var kind: String; var provider: String; var id: String }
            let p = try params.decode(P.self)
            guard let kind = LibraryItemKind(rawValue: p.kind), kind == .movie || kind == .series else {
                throw BridgeError("Only movies and series are in Recently Watched.")
            }
            try await library.removeRecent(kind: kind, providerID: ProviderID(p.provider), itemID: p.id)
            emitVODChange()
            return Empty()

        case "vod.clearRecents":
            struct P: Decodable { var kind: String }
            let kinds: [LibraryItemKind] = try itemKind(try params.decode(P.self).kind) == .movie ? [.movie] : [.series, .episode]
            try await library.clearRecents(kinds)
            emitVODChange()
            return Empty()

        default:
            throw BridgeError("Unknown request \(method).")
        }
    }

    private func itemKind(_ text: String) throws -> VODItem.Kind {
        guard let kind = VODItem.Kind(rawValue: text) else { throw BridgeError("Unknown kind \(text).") }
        return kind
    }

    private func providerName(_ id: ProviderID) -> String {
        (try? environment.providers.repository.provider(id: id))?.name ?? ""
    }
}
