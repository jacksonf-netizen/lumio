import Foundation

/// Account status reported by a source.
public struct AccountInfo: Hashable, Sendable {
    public var status: String?
    public var expiresAt: Date?
    public var isTrial: Bool
    public var maxConnections: Int?
    public var activeConnections: Int?
    public var allowedOutputFormats: [String]
    public var createdAt: Date?
    public var serverTimezone: String?
    public var message: String?

    public init(status: String? = nil, expiresAt: Date? = nil, isTrial: Bool = false, maxConnections: Int? = nil,
                activeConnections: Int? = nil, allowedOutputFormats: [String] = [], createdAt: Date? = nil,
                serverTimezone: String? = nil, message: String? = nil) {
        self.status = status
        self.expiresAt = expiresAt
        self.isTrial = isTrial
        self.maxConnections = maxConnections
        self.activeConnections = activeConnections
        self.allowedOutputFormats = allowedOutputFormats
        self.createdAt = createdAt
        self.serverTimezone = serverTimezone
        self.message = message
    }
}

/// Extra movie information fetched on demand for the detail page.
public struct MovieDetails: Hashable, Sendable {
    public var plot: String?
    public var durationSeconds: Int?
    public var genre: String?
    public var cast: String?
    public var director: String?
    public var releaseDate: String?
    public var rating: Double?
    public var posterURL: URL?
    public var backdropURL: URL?
    public var containerExtension: String?

    public init(plot: String? = nil, durationSeconds: Int? = nil, genre: String? = nil, cast: String? = nil,
                director: String? = nil, releaseDate: String? = nil, rating: Double? = nil,
                posterURL: URL? = nil, backdropURL: URL? = nil, containerExtension: String? = nil) {
        self.plot = plot
        self.durationSeconds = durationSeconds
        self.genre = genre
        self.cast = cast
        self.director = director
        self.releaseDate = releaseDate
        self.rating = rating
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.containerExtension = containerExtension
    }
}

/// Seasons and episodes for a series, fetched on demand.
public struct SeriesDetails: Hashable, Sendable {
    public var plot: String?
    public var genre: String?
    public var cast: String?
    public var backdropURL: URL?
    public var seasons: [Season]
    public var episodes: [Episode]

    public init(plot: String? = nil, genre: String? = nil, cast: String? = nil, backdropURL: URL? = nil,
                seasons: [Season], episodes: [Episode]) {
        self.plot = plot
        self.genre = genre
        self.cast = cast
        self.backdropURL = backdropURL
        self.seasons = seasons
        self.episodes = episodes
    }
}

/// A source of channels, VOD and EPG for one provider account. Xtream Codes is the only v1
/// implementation; M3U and Stalker portals would be new conformances.
public protocol SourceProvider: Sendable {
    var providerID: ProviderID { get }

    func fetchAccount() async throws -> AccountInfo
    func fetchCategories(_ kind: ContentKind) async throws -> [Category]
    func fetchChannels() async throws -> [Channel]
    func fetchMovies() async throws -> [Movie]
    func fetchSeries() async throws -> [Series]
    func fetchMovieDetails(streamID: Int) async throws -> MovieDetails
    func fetchSeriesDetails(seriesID: Int) async throws -> SeriesDetails
    /// Now/next for one channel, straight from the provider (used when the XMLTV guide has nothing).
    func fetchShortEPG(streamID: Int, limit: Int) async throws -> [Programme]
    /// Downloads the full XMLTV guide to a temporary file the caller deletes. Nil if unsupported.
    func downloadGuide() async throws -> URL?

    func liveStreamURL(streamID: Int, format: StreamFormat) -> URL
    func movieURL(streamID: Int, containerExtension: String?) -> URL
    func episodeURL(episodeID: String, containerExtension: String?) -> URL

    /// Credentials of this source, for redacting them from logs and messages.
    var redactionCredentials: [ProviderCredentials] { get }
}
