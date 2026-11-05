import Foundation
import Testing
@testable import IPTVBridge
import IPTVCore

@Suite("Bridge: the JSON door the Android TV app uses")
struct BridgeCoreTests {
    /// A bridge on an in-memory database with no network, collecting the events it sends.
    private func makeBridge() async -> (BridgeCore, EventLog) {
        let log = EventLog()
        let bridge = BridgeCore(environment: .preview(), events: { log.append($0) })
        await bridge.start(backgroundWork: false)
        return (bridge, log)
    }

    private func call(_ bridge: BridgeCore, _ method: String, _ params: [String: Any] = [:]) async throws -> Any {
        let request = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        let reply = await bridge.handle(String(decoding: request, as: UTF8.self))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        if let error = object["error"] as? String { throw Failure(message: error) }
        return try #require(object["result"])
    }

    private func addHarness(_ bridge: BridgeCore) async throws -> String {
        let added = try await call(bridge, "providers.add", [
            "name": "Harness", "servers": "http://a.example:8080\nhttp://b.example:8080",
            "username": "viewer", "password": "s3cret-pass",
        ]) as? [String: Any]
        return try #require(added?["id"] as? String)
    }

    @Test func addingAProviderListsItWithItsLinksAndNeverThePassword() async throws {
        let (bridge, _) = await makeBridge()
        let id = try await addHarness(bridge)

        let request = try JSONSerialization.data(withJSONObject: ["method": "providers.list"])
        let reply = await bridge.handle(String(decoding: request, as: UTF8.self))
        #expect(!reply.contains("s3cret-pass"))
        let list = try JSONDecoder().decode([String: [ProviderDTO]].self, from: Data(reply.utf8))["result"] ?? []
        let provider = try #require(list.first)
        #expect(provider.id == id)
        #expect(provider.name == "Harness")
        #expect(provider.enabled)
        #expect(provider.links.map(\.url) == ["http://a.example:8080", "http://b.example:8080"])
        #expect(provider.links.first?.inUse == true)

        let editor = try await call(bridge, "providers.editor", ["id": id]) as? [String: Any]
        #expect(editor?["username"] as? String == "viewer")
        #expect(editor?["servers"] as? String == "http://a.example:8080\nhttp://b.example:8080")
        #expect(editor?["password"] == nil)
    }

    @Test func savingWithAnEmptyPasswordKeepsTheSavedOne() async throws {
        let (bridge, _) = await makeBridge()
        let id = try await addHarness(bridge)
        _ = try await call(bridge, "providers.save", [
            "id": id, "name": "Renamed", "servers": "http://c.example", "username": "", "password": "",
        ])
        let credentials = try await bridge.environment.providers.credentials(for: ProviderID(id))
        #expect(credentials == ProviderCredentials(username: "viewer", password: "s3cret-pass"))
        let list = try await bridge.environment.providers.repository.all()
        #expect(list.first?.name == "Renamed")
        #expect(list.first?.serverURL.absoluteString == "http://c.example")
    }

    @Test func removingAndSwitchingOffProviders() async throws {
        let (bridge, _) = await makeBridge()
        let id = try await addHarness(bridge)
        _ = try await call(bridge, "providers.setEnabled", ["id": id, "enabled": false])
        #expect(try bridge.environment.providers.repository.all().first?.isEnabled == false)
        _ = try await call(bridge, "providers.remove", ["id": id])
        #expect(try bridge.environment.providers.repository.all().isEmpty)
        #expect(try bridge.environment.providers.credentials(for: ProviderID(id)) == nil)
    }

    @Test func liveGroupsAndChannelsComeFromTheSharedCatalog() async throws {
        let (bridge, _) = await makeBridge()
        let database = bridge.environment.database
        let provider = Provider(name: "A", serverURL: URL(string: "http://a.example")!)
        try await database.writer.write { db in
            try provider.insert(db)
            try Category(providerID: provider.id, kind: .live, categoryID: "1", name: "News", sortIndex: 0).insert(db)
            try Channel(providerID: provider.id, streamID: 7, number: 101, name: "Channel Seven", epgChannelID: "seven.uk",
                        categoryID: "1", sortIndex: 0).insert(db)
        }
        try bridge.environment.logicalChannels.rebuild()

        let groupData = try JSONSerialization.data(withJSONObject: try await call(bridge, "live.groups"))
        let groups = try JSONDecoder().decode([GroupDTO].self, from: groupData)
        #expect(groups.contains { $0.kind == "all" })
        let news = try #require(groups.first { $0.name == "News" })

        let channelData = try JSONSerialization.data(withJSONObject: try await call(bridge, "live.channels", ["group": news.id]))
        let channels = try JSONDecoder().decode([ChannelDTO].self, from: channelData)
        #expect(channels.map(\.name) == ["Channel Seven"])
        #expect(channels.first?.number == 101)
        #expect(channels.first?.streamID == 7)
        #expect(channels.first?.epg?.id == "seven.uk")
    }

    /// One provider with three channels in a News category and a guide for the first.
    private func seedChannels(_ bridge: BridgeCore) async throws -> [ChannelDTO] {
        let database = bridge.environment.database
        let provider = Provider(name: "A", serverURL: URL(string: "http://a.example")!)
        let start = Date(timeIntervalSince1970: 1_793_815_200)
        try await database.writer.write { db in
            try provider.insert(db)
            try Category(providerID: provider.id, kind: .live, categoryID: "1", name: "News", sortIndex: 0).insert(db)
            for (index, name) in ["One", "Two", "Three"].enumerated() {
                try Channel(providerID: provider.id, streamID: index + 1, number: index + 1, name: "Channel \(name)",
                            epgChannelID: "ch\(index + 1).uk", categoryID: "1", sortIndex: index).insert(db)
            }
            for hour in 0..<30 {
                var programme = Programme(providerID: provider.id, epgID: "ch1.uk", start: start.addingTimeInterval(Double(hour) * 3600),
                                          stop: start.addingTimeInterval(Double(hour + 1) * 3600), title: "Show \(hour)",
                                          category: "News", episodeNumber: hour == 1 ? "S1 E2" : nil)
                try programme.insert(db)
            }
        }
        try bridge.environment.logicalChannels.rebuild()
        let groups = try JSONDecoder().decode([GroupDTO].self, from: try JSONSerialization.data(withJSONObject: try await call(bridge, "live.groups")))
        let news = try #require(groups.first { $0.name == "News" })
        let data = try JSONSerialization.data(withJSONObject: try await call(bridge, "live.channels", ["group": news.id]))
        return try JSONDecoder().decode([ChannelDTO].self, from: data)
    }

    private func names(_ bridge: BridgeCore, in group: String) async throws -> [String] {
        let data = try JSONSerialization.data(withJSONObject: try await call(bridge, "live.channels", ["group": group]))
        return try JSONDecoder().decode([ChannelDTO].self, from: data).map(\.name)
    }

    @Test func guideRowsCoverTheWindowAskedForAndNoMore() async throws {
        let (bridge, _) = await makeBridge()
        let channels = try await seedChannels(bridge)
        let refs = try channels.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode(try #require($0.epg))) }
        let start = 1_793_815_200.0 + 3600 + 1800 // halfway through Show 1
        let data = try JSONSerialization.data(withJSONObject: try await call(bridge, "guide.programmes", [
            "epg": refs, "start": start, "end": start + 2 * 3600,
        ]))
        let rows = try JSONDecoder().decode([GuideRowDTO].self, from: data)
        #expect(rows.map(\.epg.id) == ["ch1.uk", "ch2.uk", "ch3.uk"])
        #expect(rows[0].programmes.map(\.title) == ["Show 1", "Show 2", "Show 3"])
        #expect(rows[0].programmes[0].episode == "S1 E2")
        #expect(rows[0].programmes[0].category == "News")
        #expect(rows[1].programmes.isEmpty)

        // A request for a week is cut to two days.
        let long = try JSONSerialization.data(withJSONObject: try await call(bridge, "guide.programmes", [
            "epg": [refs[0]], "start": 1_793_815_200.0, "end": 1_793_815_200.0 + 7 * 86_400,
        ]))
        #expect(try JSONDecoder().decode([GuideRowDTO].self, from: long)[0].programmes.count == 30)
    }

    @Test func favoritesToggleAndMove() async throws {
        let (bridge, _) = await makeBridge()
        let channels = try await seedChannels(bridge)
        for channel in channels {
            let reply = try await call(bridge, "library.toggleFavorite", ["channel": channel.id]) as? [String: Any]
            #expect(reply?["favorite"] as? Bool == true)
        }
        #expect(try await names(bridge, in: "favorites") == ["Channel One", "Channel Two", "Channel Three"])

        _ = try await call(bridge, "library.moveFavorite", ["channel": channels[2].id, "to": 0])
        #expect(try await names(bridge, in: "favorites") == ["Channel Three", "Channel One", "Channel Two"])
        _ = try await call(bridge, "library.moveFavorite", ["channel": channels[2].id, "to": 99])
        #expect(try await names(bridge, in: "favorites") == ["Channel One", "Channel Two", "Channel Three"])

        let off = try await call(bridge, "library.toggleFavorite", ["channel": channels[1].id]) as? [String: Any]
        #expect(off?["favorite"] as? Bool == false)
        #expect(try await names(bridge, in: "favorites") == ["Channel One", "Channel Three"])
        await #expect(throws: Failure.self) { try await call(bridge, "library.moveFavorite", ["channel": channels[1].id, "to": 0]) }
        await #expect(throws: Failure.self) { try await call(bridge, "library.toggleFavorite", ["channel": "nope"]) }
    }

    @Test func recentsRemoveAndClear() async throws {
        let (bridge, _) = await makeBridge()
        let channels = try await seedChannels(bridge)
        let library = LibraryRepository(database: bridge.environment.database)
        for channel in channels {
            try await library.recordPlayed(providerID: ProviderID(channel.providerID), kind: .channel, itemID: String(channel.streamID))
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try await names(bridge, in: "recents") == ["Channel Three", "Channel Two", "Channel One"])
        _ = try await call(bridge, "library.removeRecent", ["channel": channels[1].id])
        #expect(try await names(bridge, in: "recents") == ["Channel Three", "Channel One"])
        _ = try await call(bridge, "library.clearRecents")
        #expect(try await names(bridge, in: "recents").isEmpty)
    }

    /// One provider with a movie category (two films) and a series with two seasons.
    private func seedVOD(_ bridge: BridgeCore) async throws -> String {
        let database = bridge.environment.database
        let provider = Provider(name: "A", serverURL: URL(string: "http://a.example")!)
        try await database.writer.write { db in
            try provider.insert(db)
            try Category(providerID: provider.id, kind: .movie, categoryID: "m1", name: "Films", sortIndex: 0).insert(db)
            try Movie(providerID: provider.id, streamID: 1, name: "First Film", categoryID: "m1", year: 2001, plot: "One.",
                      durationSeconds: 5400, addedAt: Date(timeIntervalSince1970: 100), sortIndex: 0).insert(db)
            try Movie(providerID: provider.id, streamID: 2, name: "Second Film", categoryID: "m1",
                      addedAt: Date(timeIntervalSince1970: 200), sortIndex: 1).insert(db)
            try Category(providerID: provider.id, kind: .series, categoryID: "s1", name: "Drama", sortIndex: 0).insert(db)
            try Series(providerID: provider.id, seriesID: 9, name: "A Show", categoryID: "s1", releaseDate: "2019-03-01").insert(db)
            try Season(providerID: provider.id, seriesID: 9, seasonNumber: 1, name: "Season One").insert(db)
            for (season, number) in [(1, 1), (1, 2), (2, 1)] {
                try Episode(providerID: provider.id, episodeID: "e\(season)\(number)", seriesID: 9, seasonNumber: season,
                            episodeNumber: number, title: "Episode \(number)").insert(db)
            }
        }
        return provider.id.rawValue
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any) throws -> T {
        try JSONDecoder().decode(type, from: try JSONSerialization.data(withJSONObject: value))
    }

    @Test func moviesHomeCategoryAndDetails() async throws {
        let (bridge, _) = await makeBridge()
        let provider = try await seedVOD(bridge)
        let home = try decode(VODHomeDTO.self, try await call(bridge, "vod.home", ["kind": "movie"]))
        #expect(home.recentlyAdded.map(\.name) == ["Second Film", "First Film"])
        #expect(home.shelves.first?.category.name == "Films")
        #expect(home.shelves.first?.items.count == 2)

        let page = try decode([VODItemDTO].self, try await call(bridge, "vod.category", [
            "kind": "movie", "provider": provider, "category": "m1", "offset": 1, "limit": 5,
        ]))
        #expect(page.map(\.name) == ["Second Film"])

        let movie = try decode(MovieDTO.self, try await call(bridge, "vod.movie", ["provider": provider, "id": 1]))
        #expect(movie.name == "First Film")
        #expect(movie.duration == 5400)
        #expect(movie.plot == "One.")
        #expect(movie.providerName == "A")
        #expect(movie.progress == nil)
        #expect(!movie.favorite)

        _ = try await call(bridge, "vod.setFavorite", ["kind": "movie", "provider": provider, "id": "1", "favorite": true])
        _ = try await call(bridge, "vod.setWatched", ["kind": "movie", "provider": provider, "id": "1", "watched": true])
        let marked = try decode(MovieDTO.self, try await call(bridge, "vod.movie", ["provider": provider, "id": 1]))
        #expect(marked.favorite)
        #expect(marked.progress?.watched == true)
        #expect(marked.progress?.canResume == false)

        // Fetching details from a provider that can't be reached still shows the catalog's.
        let fetched = try decode(MovieDTO.self, try await call(bridge, "vod.movie", ["provider": provider, "id": 1, "fetch": true]))
        #expect(fetched.name == "First Film")
        #expect(fetched.detailsError != nil)
    }

    @Test func seriesSeasonsEpisodesAndNext() async throws {
        let (bridge, _) = await makeBridge()
        let provider = try await seedVOD(bridge)
        let library = LibraryRepository(database: bridge.environment.database)
        try await library.saveProgress(kind: .episode, providerID: ProviderID(provider), itemID: "e12", position: 300, duration: 2400)
        let series = try decode(SeriesDTO.self, try await call(bridge, "vod.series", ["provider": provider, "id": 9]))
        #expect(series.name == "A Show")
        #expect(series.year == 2019)
        #expect(series.seasons == [SeasonDTO(number: 1, name: "Season One"), SeasonDTO(number: 2, name: "Season 2")])
        #expect(series.episodes.map(\.id) == ["e11", "e12", "e21"])
        #expect(series.episodes[1].progress?.canResume == true)
        #expect(series.next == "e12")

        try await library.recordPlayed(providerID: ProviderID(provider), kind: .episode, itemID: "e12")
        let home = try decode(VODHomeDTO.self, try await call(bridge, "vod.home", ["kind": "series"]))
        #expect(home.recentlyWatched.first?.series == 9)
        #expect(home.recentlyWatched.first?.canResume == true)
        _ = try await call(bridge, "vod.removeRecent", ["kind": "series", "provider": provider, "id": "9"])
        let after = try decode(VODHomeDTO.self, try await call(bridge, "vod.home", ["kind": "series"]))
        #expect(after.recentlyWatched.isEmpty)
    }

    @Test func changesArriveAsEvents() async throws {
        let (bridge, log) = await makeBridge()
        _ = try await addHarness(bridge)
        try await log.waitFor { $0.contains(#""type":"providers""#) }
        try await log.waitFor { $0.contains(#""type":"live""#) }
    }

    @Test func badRequestsGetAMessageNotACrash() async throws {
        let (bridge, _) = await makeBridge()
        await #expect(throws: Failure.self) { try await call(bridge, "providers.nonsense") }
        await #expect(throws: Failure.self) { try await call(bridge, "providers.add", ["name": "No links"]) }
        await #expect(throws: Failure.self) { try await call(bridge, "providers.remove", ["id": 5]) }
        let reply = await bridge.handle("not json")
        #expect(reply.contains("error"))
    }

    @Test func theKotlinFixturesMatchTheseTypes() throws {
        // The Android app's tests read the same files (AndroidTV/app/src/test), so both sides agree
        // on every field name.
        let folder = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        func read(_ name: String) throws -> Data { try Data(contentsOf: folder.appendingPathComponent(name)) }
        let providers = try JSONDecoder().decode([ProviderDTO].self, from: try read("providers.json"))
        #expect(providers.count == 2)
        #expect(providers[1].syncing == "Updating channels…")
        let channels = try JSONDecoder().decode([ChannelDTO].self, from: try read("channels.json"))
        #expect(channels.first?.epg?.providers == ["p1"])
        let groups = try JSONDecoder().decode([GroupDTO].self, from: try read("groups.json"))
        #expect(groups.map(\.kind) == ["favorites", "all", "category"])
        let nowNext = try JSONDecoder().decode([NowNextDTO].self, from: try read("nownext.json"))
        #expect(nowNext.first?.now?.title == "News at Six")
        let home = try JSONDecoder().decode(VODHomeDTO.self, from: try read("vod_home.json"))
        #expect(home.recentlyWatched.first?.canResume == true)
        #expect(home.shelves.first?.items.first?.name == "Arrival")
        let movie = try JSONDecoder().decode(MovieDTO.self, from: try read("movie.json"))
        #expect(movie.progress?.position == 1820)
        let series = try JSONDecoder().decode(SeriesDTO.self, from: try read("series.json"))
        #expect(series.next == "e12")
        let guide = try JSONDecoder().decode([GuideRowDTO].self, from: try read("guide.json"))
        #expect(guide.first?.programmes.map(\.episode) == ["S4 E12", nil])
        let events = try JSONDecoder().decode([BridgeEvent].self, from: try read("events.json"))
        #expect(events.map(\.type) == ["providers", "sync", "sync", "live"])
    }
}

private struct Failure: Error { let message: String }

/// Events the bridge sent, in order.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) { lock.withLock { events.append(event) } }

    /// Waits up to 5 seconds for an event matching `predicate`.
    func waitFor(_ predicate: @Sendable (String) -> Bool) async throws {
        for _ in 0..<100 {
            if lock.withLock({ events.contains(where: predicate) }) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("No matching event; got \(lock.withLock { events })")
    }
}

@Suite("Bridge: system events")
struct BridgeSystemEventTests {
    @Test func networkAndSleepEventsReachTheCore() async throws {
        let bridge = BridgeCore(environment: .preview(), events: { _ in })
        let stream = bridge.systemEvents.events()
        for request in [#"{"method":"system.event","params":{"type":"network","available":false}}"#,
                        #"{"method":"system.event","params":{"type":"network","available":false}}"#,
                        #"{"method":"system.event","params":{"type":"willSleep"}}"#,
                        #"{"method":"system.event","params":{"type":"didWake"}}"#] {
            #expect(!(await bridge.handle(request)).contains("error"))
        }
        var received: [SystemEvent] = []
        for await event in stream {
            received.append(event)
            if received.count == 3 { break }
        }
        // The repeated network state is passed on once.
        #expect(received == [.network(available: false), .willSleep, .didWake])
    }
}
