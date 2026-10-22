import Foundation
import Testing
@testable import IPTVCore

@Suite("Xtream decoding (messy real-world JSON)")
struct XtreamDecodingTests {
    let provider = TestData.provider()

    func source(_ routes: [String: String]) -> XtreamSourceProvider {
        XtreamSourceProvider(provider: provider, credentials: ProviderCredentials(username: "user", password: "pass"),
                             transport: StubTransport(routes))
    }

    @Test func accountWithStringNumbers() async throws {
        let account = try await source(["auth": "xtream/auth_ok.json"]).fetchAccount()
        #expect(account.status == "Active")
        #expect(account.maxConnections == 2)
        #expect(account.activeConnections == 1)
        #expect(account.expiresAt == Date(timeIntervalSince1970: 1_924_992_000))
        #expect(account.allowedOutputFormats == ["m3u8", "ts", "rtmp"])
        #expect(account.serverTimezone == "Europe/London")
    }

    @Test func accountWithRealNumbersCommaFormatsAndArrayServerInfo() async throws {
        let account = try await source(["auth": "xtream/auth_numbers.json"]).fetchAccount()
        #expect(account.maxConnections == 4)
        #expect(account.expiresAt == nil)
        #expect(account.allowedOutputFormats == ["ts", "m3u8"])
        #expect(account.serverTimezone == nil)
    }

    @Test(arguments: [
        ("xtream/auth_failed.json", XtreamError.unauthorized),
        ("xtream/auth_expired.json", XtreamError.accountExpired(Date(timeIntervalSince1970: 1_500_000_000))),
        ("xtream/auth_disabled.json", XtreamError.accountNotActive(status: "Disabled")),
    ])
    func accountProblems(fixture: String, expected: XtreamError) async {
        await #expect(throws: expected) { try await source(["auth": fixture]).fetchAccount() }
    }

    @Test func categoriesToleratesMixedTypesAndSkipsBadRows() async throws {
        let categories = try await source(["get_live_categories": "xtream/live_categories.json"]).fetchCategories(.live)
        #expect(categories.map(\.categoryID) == ["1", "2", "3"])
        #expect(categories[2].name == "Unnamed")
        #expect(categories[2].parentID == "1")
        #expect(categories[0].parentID == nil)
        #expect(categories.map(\.sortIndex) == [0, 1, 2])
    }

    @Test func liveStreamsToleratesMessyFields() async throws {
        let channels = try await source(["get_live_streams": "xtream/live_streams.json"]).fetchChannels()
        #expect(channels.map(\.streamID) == [101, 102, 103, 104, 107])

        let bbc = channels[0]
        #expect(bbc.name == "UK: BBC One HD")
        #expect(bbc.epgChannelID == "bbcone.uk") // normalised
        #expect(bbc.logoURL?.absoluteString == "http://logos.test/bbc%20one.png")
        #expect(bbc.tvArchive)
        #expect(bbc.tvArchiveDuration == 7)
        #expect(bbc.addedAt == Date(timeIntervalSince1970: 1_600_000_000))

        let sd = channels[1]
        #expect(sd.number == 2)
        #expect(sd.logoURL == nil)
        #expect(sd.categoryID == "1")
        #expect(sd.addedAt == nil)

        let itv = channels[2]
        #expect(itv.number == nil)
        #expect(itv.epgChannelID == nil)
        #expect(itv.categoryID == "2") // from category_ids

        #expect(channels[3].name == "Channel 104")
        #expect(channels[3].epgChannelID == nil)
        #expect(channels[4].isAdult)
    }

    @Test func vodAndSeriesLists() async throws {
        let s = source(["get_vod_streams": "xtream/vod_streams.json", "get_series": "xtream/series.json"])
        let movies = try await s.fetchMovies()
        #expect(movies.map(\.streamID) == [501, 502, 503])
        #expect(movies[0].rating == 7.5)
        #expect(movies[0].year == 2019)
        #expect(movies[0].containerExtension == "mkv")
        #expect(movies[1].rating == nil)
        #expect(movies[1].tmdbID == "12345")
        #expect(movies[2].rating == 6)

        let series = try await s.fetchSeries()
        #expect(series.map(\.seriesID) == [701, 702])
        #expect(series[0].releaseDate == "2020-01-01")
        #expect(series[1].releaseDate == "2021")
        #expect(series[1].rating == nil)
        #expect(series[1].lastModified == nil)
    }

    @Test func seriesInfoWithEpisodesKeyedBySeason() async throws {
        let details = try await source(["get_series_info": "xtream/series_info.json"]).fetchSeriesDetails(seriesID: 701)
        #expect(details.plot == "Full plot.")
        #expect(details.seasons.map(\.seasonNumber) == [1, 2]) // season 2 inferred from episodes
        #expect(details.episodes.map(\.episodeID) == ["9001", "9002", "9003"])
        #expect(details.episodes[0].durationSeconds == 2700)
        #expect(details.episodes[1].episodeNumber == 2)
        #expect(details.episodes[1].plot == nil) // info was []
        #expect(details.episodes[2].seasonNumber == 2) // season from the dictionary key
    }

    @Test func seriesInfoWithEpisodesAsNestedArrays() async throws {
        let details = try await source(["get_series_info": "xtream/series_info_array.json"]).fetchSeriesDetails(seriesID: 1)
        #expect(details.episodes.map(\.episodeID) == ["8001", "8002"])
        #expect(details.seasons.map(\.seasonNumber) == [1, 2])
        #expect(details.plot == nil)
    }

    @Test func vodInfoWithFullAndEmptyInfo() async throws {
        let full = try await source(["get_vod_info": "xtream/vod_info.json"]).fetchMovieDetails(streamID: 501)
        #expect(full.durationSeconds == 6300)
        #expect(full.rating == 7.2)
        #expect(full.backdropURL?.absoluteString == "http://img.test/bd.jpg")
        let empty = try await source(["get_vod_info": "xtream/vod_info_empty.json"]).fetchMovieDetails(streamID: 502)
        #expect(empty.plot == nil)
        #expect(empty.containerExtension == "mp4")
    }

    @Test func shortEPGDecodesBase64AndSkipsBadRows() async throws {
        let programmes = try await source(["get_short_epg": "xtream/short_epg.json"]).fetchShortEPG(streamID: 101, limit: 4)
        #expect(programmes.map(\.title) == ["News at Six", "Plain Title"])
        #expect(programmes[0].summary == "Headlines & weather.")
        #expect(programmes[0].start == Date(timeIntervalSince1970: 1_792_260_000))
        // Falls back to parsing the "start"/"end" strings when timestamps are missing.
        #expect(programmes[1].start == XMLTVDate.parse("20261017183000 +0000"))
    }

    @Test(arguments: ["", "[]", "{}", "null", "  \n", "\"\""])
    func emptyListBodiesMeanNoItems(body: String) async throws {
        let transport = StubTransport()
        transport.set("get_live_streams", body: body)
        let s = XtreamSourceProvider(provider: provider, credentials: ProviderCredentials(username: "u", password: "p"),
                                     transport: transport)
        #expect(try await s.fetchChannels().isEmpty)
    }

    @Test func listsSentAsNumberedObjects() async throws {
        let transport = StubTransport()
        transport.set("get_live_categories", body: #"{"1":{"category_id":"5","category_name":"B"},"0":{"category_id":"4","category_name":"A"}}"#)
        let s = XtreamSourceProvider(provider: provider, credentials: ProviderCredentials(username: "u", password: "p"),
                                     transport: transport)
        #expect(try await s.fetchCategories(.live).map(\.name) == ["A", "B"])
    }
}
