import Foundation

// Wire formats for `player_api.php`. Every decoder is lossy (see LossyDecoding.swift). These types
// stay internal to the Xtream implementation and are mapped to app models by XtreamSourceProvider.

// MARK: - Account

struct XtreamAuthResponse: Decodable {
    let userInfo: XtreamUserInfo?
    let serverInfo: XtreamServerInfo?

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
        case serverInfo = "server_info"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userInfo = c.lossyObject(XtreamUserInfo.self, .userInfo)
        serverInfo = c.lossyObject(XtreamServerInfo.self, .serverInfo)
    }
}

struct XtreamUserInfo: Decodable {
    let auth: Bool
    let status: String?
    let message: String?
    let expiresAt: Date?
    let isTrial: Bool
    let activeConnections: Int?
    let maxConnections: Int?
    let createdAt: Date?
    let allowedOutputFormats: [String]

    enum CodingKeys: String, CodingKey {
        case auth, status, message
        case expDate = "exp_date"
        case isTrial = "is_trial"
        case activeCons = "active_cons"
        case maxConnections = "max_connections"
        case createdAt = "created_at"
        case allowedOutputFormats = "allowed_output_formats"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Some panels omit `auth` on success; treat a present status as authenticated.
        auth = c.lossyBool(.auth) ?? (c.lossyNonEmptyString(.status) != nil)
        status = c.lossyNonEmptyString(.status)
        message = c.lossyNonEmptyString(.message)
        expiresAt = c.lossyUnixDate(.expDate)
        isTrial = c.lossyBool(.isTrial) ?? false
        activeConnections = c.lossyInt(.activeCons)
        maxConnections = c.lossyInt(.maxConnections)
        createdAt = c.lossyUnixDate(.createdAt)
        allowedOutputFormats = c.lossyStringArray(.allowedOutputFormats).map { $0.lowercased() }
    }
}

struct XtreamServerInfo: Decodable {
    let url: String?
    let port: String?
    let httpsPort: String?
    let serverProtocol: String?
    let timezone: String?
    let timestampNow: Date?

    enum CodingKeys: String, CodingKey {
        case url, port, timezone
        case httpsPort = "https_port"
        case serverProtocol = "server_protocol"
        case timestampNow = "timestamp_now"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.lossyNonEmptyString(.url)
        port = c.lossyNonEmptyString(.port)
        httpsPort = c.lossyNonEmptyString(.httpsPort)
        serverProtocol = c.lossyNonEmptyString(.serverProtocol)
        timezone = c.lossyNonEmptyString(.timezone)
        timestampNow = c.lossyUnixDate(.timestampNow)
    }
}

// MARK: - Catalog

struct XtreamCategory: Decodable {
    let id: String
    let name: String
    let parentID: String?

    enum CodingKeys: String, CodingKey {
        case id = "category_id"
        case name = "category_name"
        case parentID = "parent_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.lossyNonEmptyString(.id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "missing category_id"))
        }
        self.id = id
        name = c.lossyNonEmptyString(.name) ?? "Unnamed"
        parentID = c.lossyNonEmptyString(.parentID).flatMap { $0 == "0" ? nil : $0 }
    }
}

struct XtreamLiveStream: Decodable {
    let streamID: Int
    let number: Int?
    let name: String
    let icon: URL?
    let epgChannelID: String?
    let categoryID: String?
    let added: Date?
    let isAdult: Bool
    let tvArchive: Bool
    let tvArchiveDuration: Int
    let directSource: String?

    enum CodingKeys: String, CodingKey {
        case num, name
        case streamID = "stream_id"
        case icon = "stream_icon"
        case epgChannelID = "epg_channel_id"
        case categoryID = "category_id"
        case categoryIDs = "category_ids"
        case added
        case isAdult = "is_adult"
        case tvArchive = "tv_archive"
        case tvArchiveDuration = "tv_archive_duration"
        case directSource = "direct_source"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let streamID = c.lossyInt(.streamID) else {
            throw DecodingError.keyNotFound(CodingKeys.streamID, .init(codingPath: c.codingPath, debugDescription: "missing stream_id"))
        }
        self.streamID = streamID
        number = c.lossyInt(.num)
        name = c.lossyNonEmptyString(.name) ?? "Channel \(streamID)"
        icon = c.lossyURL(.icon)
        epgChannelID = c.lossyNonEmptyString(.epgChannelID)
        categoryID = c.lossyNonEmptyString(.categoryID) ?? c.lossyStringArray(.categoryIDs).first
        added = c.lossyUnixDate(.added)
        isAdult = c.lossyBool(.isAdult) ?? false
        tvArchive = c.lossyBool(.tvArchive) ?? false
        tvArchiveDuration = c.lossyInt(.tvArchiveDuration) ?? 0
        directSource = c.lossyNonEmptyString(.directSource)
    }
}

struct XtreamVODStream: Decodable {
    let streamID: Int
    let name: String
    let icon: URL?
    let rating: Double?
    let categoryID: String?
    let added: Date?
    let containerExtension: String?
    let tmdbID: String?
    let year: Int?

    enum CodingKeys: String, CodingKey {
        case name, rating, added, year
        case streamID = "stream_id"
        case icon = "stream_icon"
        case categoryID = "category_id"
        case categoryIDs = "category_ids"
        case containerExtension = "container_extension"
        case tmdb, tmdbID = "tmdb_id"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let streamID = c.lossyInt(.streamID) else {
            throw DecodingError.keyNotFound(CodingKeys.streamID, .init(codingPath: c.codingPath, debugDescription: "missing stream_id"))
        }
        self.streamID = streamID
        name = c.lossyNonEmptyString(.name) ?? "Movie \(streamID)"
        icon = c.lossyURL(.icon)
        rating = c.lossyDouble(.rating).flatMap { $0 > 0 ? $0 : nil }
        categoryID = c.lossyNonEmptyString(.categoryID) ?? c.lossyStringArray(.categoryIDs).first
        added = c.lossyUnixDate(.added)
        containerExtension = c.lossyNonEmptyString(.containerExtension)
        tmdbID = c.lossyNonEmptyString(.tmdbID) ?? c.lossyNonEmptyString(.tmdb)
        year = c.lossyInt(.year).flatMap { $0 > 1800 ? $0 : nil }
    }
}

struct XtreamSeries: Decodable {
    let seriesID: Int
    let name: String
    let cover: URL?
    let plot: String?
    let rating: Double?
    let categoryID: String?
    let releaseDate: String?
    let lastModified: Date?

    enum CodingKeys: String, CodingKey {
        case name, cover, plot, rating
        case seriesID = "series_id"
        case categoryID = "category_id"
        case categoryIDs = "category_ids"
        case releaseDate, releaseDateSnake = "release_date"
        case lastModified = "last_modified"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let seriesID = c.lossyInt(.seriesID) else {
            throw DecodingError.keyNotFound(CodingKeys.seriesID, .init(codingPath: c.codingPath, debugDescription: "missing series_id"))
        }
        self.seriesID = seriesID
        name = c.lossyNonEmptyString(.name) ?? "Series \(seriesID)"
        cover = c.lossyURL(.cover)
        plot = c.lossyNonEmptyString(.plot)
        rating = c.lossyDouble(.rating).flatMap { $0 > 0 ? $0 : nil }
        categoryID = c.lossyNonEmptyString(.categoryID) ?? c.lossyStringArray(.categoryIDs).first
        releaseDate = c.lossyNonEmptyString(.releaseDate) ?? c.lossyNonEmptyString(.releaseDateSnake)
        lastModified = c.lossyUnixDate(.lastModified)
    }
}

// MARK: - Details

struct XtreamVODInfo: Decodable {
    let info: Info?
    let movieData: MovieData?

    struct Info: Decodable {
        let plot: String?
        let durationSeconds: Int?
        let tmdbID: String?
        let rating: Double?
        let releaseDate: String?
        let genre: String?
        let cast: String?
        let director: String?
        let image: URL?
        let backdrop: URL?

        enum CodingKeys: String, CodingKey {
            case plot, description, genre, cast, director, rating
            case durationSecs = "duration_secs"
            case tmdbID = "tmdb_id"
            case releaseDate = "releasedate"
            case releaseDateSnake = "release_date"
            case movieImage = "movie_image"
            case coverBig = "cover_big"
            case backdropPath = "backdrop_path"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            plot = c.lossyNonEmptyString(.plot) ?? c.lossyNonEmptyString(.description)
            durationSeconds = c.lossyInt(.durationSecs).flatMap { $0 > 0 ? $0 : nil }
            tmdbID = c.lossyNonEmptyString(.tmdbID)
            rating = c.lossyDouble(.rating).flatMap { $0 > 0 ? $0 : nil }
            releaseDate = c.lossyNonEmptyString(.releaseDate) ?? c.lossyNonEmptyString(.releaseDateSnake)
            genre = c.lossyNonEmptyString(.genre)
            cast = c.lossyNonEmptyString(.cast)
            director = c.lossyNonEmptyString(.director)
            image = c.lossyURL(.movieImage) ?? c.lossyURL(.coverBig)
            // backdrop_path is usually an array of URLs, sometimes a single string.
            backdrop = c.lossyStringArray(.backdropPath).first.flatMap(URL.init(string:))
        }
    }

    struct MovieData: Decodable {
        let streamID: Int?
        let containerExtension: String?

        enum CodingKeys: String, CodingKey {
            case streamID = "stream_id"
            case containerExtension = "container_extension"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            streamID = c.lossyInt(.streamID)
            containerExtension = c.lossyNonEmptyString(.containerExtension)
        }
    }

    enum CodingKeys: String, CodingKey {
        case info
        case movieData = "movie_data"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        info = c.lossyObject(Info.self, .info)
        movieData = c.lossyObject(MovieData.self, .movieData)
    }
}

struct XtreamSeriesInfo: Decodable {
    let seasons: [Season]
    let info: XtreamSeriesInfoDetails?
    let episodes: [Episode]

    struct Season: Decodable {
        let seasonNumber: Int
        let name: String?
        let cover: URL?
        let airDate: String?

        enum CodingKeys: String, CodingKey {
            case name, cover
            case coverBig = "cover_big"
            case seasonNumber = "season_number"
            case airDate = "air_date"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let number = c.lossyInt(.seasonNumber) else {
                throw DecodingError.keyNotFound(CodingKeys.seasonNumber, .init(codingPath: c.codingPath, debugDescription: "missing season_number"))
            }
            seasonNumber = number
            name = c.lossyNonEmptyString(.name)
            cover = c.lossyURL(.coverBig) ?? c.lossyURL(.cover)
            airDate = c.lossyNonEmptyString(.airDate)
        }
    }

    struct Episode: Decodable {
        let id: String
        let episodeNumber: Int?
        let season: Int?
        let title: String?
        let containerExtension: String?
        let durationSeconds: Int?
        let plot: String?
        let image: URL?
        let airDate: String?

        enum CodingKeys: String, CodingKey {
            case id, title, season, info
            case episodeNum = "episode_num"
            case containerExtension = "container_extension"
        }

        enum InfoKeys: String, CodingKey {
            case plot
            case durationSecs = "duration_secs"
            case movieImage = "movie_image"
            case releaseDate = "releasedate"
            case airDate = "air_date"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.lossyNonEmptyString(.id) else {
                throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: c.codingPath, debugDescription: "missing id"))
            }
            self.id = id
            episodeNumber = c.lossyInt(.episodeNum)
            season = c.lossyInt(.season)
            title = c.lossyNonEmptyString(.title)
            containerExtension = c.lossyNonEmptyString(.containerExtension)
            // `info` is an object, or `[]` when empty.
            if let info = try? c.nestedContainer(keyedBy: InfoKeys.self, forKey: .info) {
                durationSeconds = info.lossyInt(.durationSecs).flatMap { $0 > 0 ? $0 : nil }
                plot = info.lossyNonEmptyString(.plot)
                image = info.lossyURL(.movieImage)
                airDate = info.lossyNonEmptyString(.releaseDate) ?? info.lossyNonEmptyString(.airDate)
            } else {
                durationSeconds = nil
                plot = nil
                image = nil
                airDate = nil
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case seasons, info, episodes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasons = c.lossyArray(Season.self, .seasons)
        info = c.lossyObject(XtreamSeriesInfoDetails.self, .info)

        // `episodes` is normally {"1": [...], "2": [...]} but some panels send [[...], [...]] or a flat array.
        var episodes: [Episode] = []
        if let bySeason = try? c.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .episodes) {
            for key in bySeason.allKeys {
                let list = bySeason.lossyArray(Episode.self, key)
                let seasonFromKey = Int(key.stringValue)
                episodes += list.map { $0.withSeason(fallback: seasonFromKey) }
            }
        } else if let nested = try? c.decode([[FailableDecodable<Episode>]].self, forKey: .episodes) {
            episodes = nested.flatMap { $0.compactMap(\.value) }
        } else {
            episodes = c.lossyArray(Episode.self, .episodes)
        }
        self.episodes = episodes
    }
}

extension XtreamSeriesInfo.Episode {
    fileprivate func withSeason(fallback: Int?) -> Self {
        guard season == nil, let fallback else { return self }
        return Self(id: id, episodeNumber: episodeNumber, season: fallback, title: title,
                    containerExtension: containerExtension, durationSeconds: durationSeconds, plot: plot,
                    image: image, airDate: airDate)
    }

    fileprivate init(id: String, episodeNumber: Int?, season: Int?, title: String?, containerExtension: String?,
                     durationSeconds: Int?, plot: String?, image: URL?, airDate: String?) {
        self.id = id
        self.episodeNumber = episodeNumber
        self.season = season
        self.title = title
        self.containerExtension = containerExtension
        self.durationSeconds = durationSeconds
        self.plot = plot
        self.image = image
        self.airDate = airDate
    }
}

struct XtreamSeriesInfoDetails: Decodable {
    let name: String?
    let plot: String?
    let cover: URL?
    let genre: String?
    let cast: String?
    let rating: Double?
    let releaseDate: String?
    let backdrop: URL?

    enum CodingKeys: String, CodingKey {
        case name, plot, cover, genre, cast, rating
        case releaseDate, releaseDateSnake = "release_date"
        case backdropPath = "backdrop_path"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lossyNonEmptyString(.name)
        plot = c.lossyNonEmptyString(.plot)
        cover = c.lossyURL(.cover)
        genre = c.lossyNonEmptyString(.genre)
        cast = c.lossyNonEmptyString(.cast)
        rating = c.lossyDouble(.rating).flatMap { $0 > 0 ? $0 : nil }
        releaseDate = c.lossyNonEmptyString(.releaseDate) ?? c.lossyNonEmptyString(.releaseDateSnake)
        backdrop = c.lossyStringArray(.backdropPath).first.flatMap(URL.init(string:))
    }
}

// MARK: - Short EPG

struct XtreamShortEPG: Decodable {
    let listings: [Listing]

    struct Listing: Decodable {
        let epgID: String?
        let title: String
        let description: String?
        let start: Date
        let stop: Date

        enum CodingKeys: String, CodingKey {
            case title, description, start, end
            case epgID = "epg_id"
            case channelID = "channel_id"
            case startTimestamp = "start_timestamp"
            case stopTimestamp = "stop_timestamp"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            epgID = c.lossyNonEmptyString(.channelID) ?? c.lossyNonEmptyString(.epgID)
            title = Self.decodeBase64(c.lossyString(.title)) ?? "No information"
            description = Self.decodeBase64(c.lossyString(.description))
            // Prefer the Unix timestamps; the "start"/"end" strings are in the server's local time zone.
            guard let start = c.lossyUnixDate(.startTimestamp) ?? Self.parseUTC(c.lossyString(.start)),
                  let stop = c.lossyUnixDate(.stopTimestamp) ?? Self.parseUTC(c.lossyString(.end)),
                  stop > start
            else {
                throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "bad times"))
            }
            self.start = start
            self.stop = stop
        }

        /// Titles are base64 in most panels, plain text in a few.
        static func decodeBase64(_ string: String?) -> String? {
            guard let string, !string.isEmpty else { return nil }
            if let data = Data(base64Encoded: string, options: .ignoreUnknownCharacters),
               let decoded = String(data: data, encoding: .utf8), !decoded.isEmpty,
               !decoded.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && !"\n\r\t".unicodeScalars.contains($0) }) {
                return decoded
            }
            return string
        }

        static func parseUTC(_ string: String?) -> Date? {
            guard let string else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.date(from: string)
        }
    }

    enum CodingKeys: String, CodingKey {
        case listings = "epg_listings"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        listings = c.lossyArray(Listing.self, .listings)
    }
}
