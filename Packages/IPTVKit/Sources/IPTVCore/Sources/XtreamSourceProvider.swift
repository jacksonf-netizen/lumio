import Foundation

/// `SourceProvider` backed by an Xtream Codes account.
public struct XtreamSourceProvider: SourceProvider {
    public let providerID: ProviderID
    public let client: XtreamClient
    private let credentials: ProviderCredentials

    public init(provider: Provider, credentials: ProviderCredentials, transport: any HTTPTransport,
                userAgent: String = XtreamClient.defaultUserAgent) {
        providerID = provider.id
        self.credentials = credentials
        client = XtreamClient(serverURL: provider.serverURL, credentials: credentials, transport: transport,
                              userAgent: provider.userAgentOverride ?? userAgent)
    }

    public var redactionCredentials: [ProviderCredentials] { [credentials] }

    public func fetchAccount() async throws -> AccountInfo {
        let response = try await client.authenticate()
        let user = response.userInfo
        return AccountInfo(
            status: user?.status,
            expiresAt: user?.expiresAt,
            isTrial: user?.isTrial ?? false,
            maxConnections: user?.maxConnections,
            activeConnections: user?.activeConnections,
            allowedOutputFormats: user?.allowedOutputFormats ?? [],
            createdAt: user?.createdAt,
            serverTimezone: response.serverInfo?.timezone,
            message: user?.message)
    }

    public func fetchCategories(_ kind: ContentKind) async throws -> [Category] {
        let raw: [XtreamCategory]
        switch kind {
        case .live: raw = try await client.liveCategories()
        case .movie: raw = try await client.vodCategories()
        case .series: raw = try await client.seriesCategories()
        }
        return Self.unique(raw.enumerated().map { index, item in
            Category(providerID: providerID, kind: kind, categoryID: item.id, name: item.name,
                     parentID: item.parentID, sortIndex: index)
        }, by: \.categoryID)
    }

    public func fetchChannels() async throws -> [Channel] {
        let raw = try await client.liveStreams()
        return Self.unique(raw.enumerated().map { index, item in
            Channel(providerID: providerID, streamID: item.streamID, number: item.number, name: item.name,
                    logoURL: item.icon, epgChannelID: item.epgChannelID.map(EPGKey.normalize), categoryID: item.categoryID,
                    tvArchive: item.tvArchive, tvArchiveDuration: item.tvArchiveDuration, addedAt: item.added,
                    isAdult: item.isAdult, directSource: item.directSource, sortIndex: index)
        }, by: \.streamID)
    }

    public func fetchMovies() async throws -> [Movie] {
        let raw = try await client.vodStreams()
        return Self.unique(raw.enumerated().map { index, item in
            Movie(providerID: providerID, streamID: item.streamID, name: item.name, categoryID: item.categoryID,
                  posterURL: item.icon, rating: item.rating, year: item.year ?? Self.year(fromTitle: item.name),
                  tmdbID: item.tmdbID, containerExtension: item.containerExtension, addedAt: item.added,
                  sortIndex: index)
        }, by: \.streamID)
    }

    public func fetchSeries() async throws -> [Series] {
        let raw = try await client.series()
        return Self.unique(raw.enumerated().map { index, item in
            Series(providerID: providerID, seriesID: item.seriesID, name: item.name, categoryID: item.categoryID,
                   coverURL: item.cover, plot: item.plot, rating: item.rating, releaseDate: item.releaseDate,
                   lastModified: item.lastModified, sortIndex: index)
        }, by: \.seriesID)
    }

    public func fetchMovieDetails(streamID: Int) async throws -> MovieDetails {
        let raw = try await client.vodInfo(streamID: streamID)
        return MovieDetails(
            plot: raw.info?.plot, durationSeconds: raw.info?.durationSeconds, genre: raw.info?.genre,
            cast: raw.info?.cast, director: raw.info?.director, releaseDate: raw.info?.releaseDate,
            rating: raw.info?.rating, posterURL: raw.info?.image, backdropURL: raw.info?.backdrop,
            containerExtension: raw.movieData?.containerExtension)
    }

    public func fetchSeriesDetails(seriesID: Int) async throws -> SeriesDetails {
        let raw = try await client.seriesInfo(seriesID: seriesID)
        var seasons = raw.seasons.map { season in
            Season(providerID: providerID, seriesID: seriesID, seasonNumber: season.seasonNumber,
                   name: season.name, coverURL: season.cover, airDate: season.airDate)
        }
        let episodes = Self.unique(raw.episodes.map { episode in
            Episode(providerID: providerID, episodeID: episode.id, seriesID: seriesID,
                    seasonNumber: episode.season ?? 1, episodeNumber: episode.episodeNumber ?? 0,
                    title: episode.title ?? "Episode \(episode.episodeNumber ?? 0)",
                    containerExtension: episode.containerExtension, durationSeconds: episode.durationSeconds,
                    plot: episode.plot, imageURL: episode.image, airDate: episode.airDate)
        }, by: \.episodeID)
        .sorted { ($0.seasonNumber, $0.episodeNumber) < ($1.seasonNumber, $1.episodeNumber) }

        // Panels often list episodes for seasons missing from `seasons`.
        let known = Set(seasons.map(\.seasonNumber))
        for number in Set(episodes.map(\.seasonNumber)).subtracting(known).sorted() {
            seasons.append(Season(providerID: providerID, seriesID: seriesID, seasonNumber: number))
        }
        seasons = Self.unique(seasons, by: \.seasonNumber).sorted { $0.seasonNumber < $1.seasonNumber }

        return SeriesDetails(plot: raw.info?.plot, genre: raw.info?.genre, cast: raw.info?.cast,
                             backdropURL: raw.info?.backdrop, seasons: seasons, episodes: episodes)
    }

    public func fetchShortEPG(streamID: Int, limit: Int) async throws -> [Programme] {
        let raw = try await client.shortEPG(streamID: streamID, limit: limit)
        return raw.listings.map { listing in
            Programme(providerID: providerID, epgID: listing.epgID ?? "stream:\(streamID)", start: listing.start,
                      stop: listing.stop, title: listing.title, summary: listing.description)
        }
    }

    public func downloadGuide() async throws -> URL? {
        try await client.downloadXMLTV()
    }

    public func liveStreamURL(streamID: Int, format: StreamFormat) -> URL {
        client.liveURL(streamID: streamID, format: format)
    }

    public func movieURL(streamID: Int, containerExtension: String?) -> URL {
        client.movieURL(streamID: streamID, containerExtension: containerExtension)
    }

    public func episodeURL(episodeID: String, containerExtension: String?) -> URL {
        client.episodeURL(episodeID: episodeID, containerExtension: containerExtension)
    }

    // MARK: Helpers

    /// Keeps the first occurrence of each id (panels occasionally list an item twice).
    static func unique<T, ID: Hashable>(_ items: [T], by id: KeyPath<T, ID>) -> [T] {
        var seen = Set<ID>()
        return items.filter { seen.insert($0[keyPath: id]).inserted }
    }

    /// "Film Title (2019)" → 2019
    static func year(fromTitle title: String) -> Int? {
        guard let match = title.firstMatch(of: /\((19|20)\d{2}\)/) else { return nil }
        return Int(title[match.range].dropFirst().dropLast())
    }
}
