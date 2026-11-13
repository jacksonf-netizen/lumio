import Foundation
import Testing
@testable import IPTVBridge
import GRDB
import IPTVCore

/// The core's PlaybackController driven through the bridge, with a fake engine in place of
/// ExoPlayer: commands are recorded, events are pushed back the way the Android app pushes them.
@Suite("Bridge: playback", .serialized)
@MainActor
struct BridgePlayerTests {
    /// Stands in for the app's engine: records commands, reports growing position and bytes.
    final class FakeEngine: @unchecked Sendable {
        var commands: [[String: Any]] = []
        var position = 0.0
        func handle(_ json: String) -> String? {
            let command = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
            commands.append(command)
            if command["command"] as? String == "metrics" {
                position += 1
                return #"{"result":{"position":\#(position),"bytesReceived":\#(Int(position) * 1000),"bufferSeconds":4}}"#
            }
            return #"{"result":null}"#
        }
        var loads: [[String: Any]] { commands.filter { $0["command"] as? String == "load" } }
    }

    private func makeBridge() async throws -> (BridgeCore, FakeEngine, EventLog) {
        let engine = FakeEngine()
        let log = EventLog()
        let environment = AppEnvironment.preview()
        let provider = try await environment.providers.addProvider(
            name: "A", servers: "http://a.example", credentials: ProviderCredentials(username: "viewer", password: "pw"))
        try await environment.database.writer.write { db in
            try Category(providerID: provider.id, kind: .live, categoryID: "1", name: "News", sortIndex: 0).insert(db)
            for (n, name) in [(7, "Seven"), (8, "Eight"), (9, "Nine")].enumerated() {
                try Channel(providerID: provider.id, streamID: name.0, number: 101 + n, name: name.1, categoryID: "1", sortIndex: n).insert(db)
            }
        }
        try await environment.database.writer.write { db in
            try Category(providerID: provider.id, kind: .movie, categoryID: "m1", name: "Films", sortIndex: 0).insert(db)
            try Movie(providerID: provider.id, streamID: 42, name: "The Test Film", categoryID: "m1", containerExtension: "mkv").insert(db)
        }
        try environment.logicalChannels.rebuild()
        let bridge = BridgeCore(environment: environment, playerCommands: { engine.handle($0) }, events: { log.append($0) })
        await bridge.start(backgroundWork: false)
        return (bridge, engine, log)
    }

    private func call(_ bridge: BridgeCore, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let request = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
        let reply = await bridge.handle(String(decoding: request, as: UTF8.self))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
        if let error = object["error"] as? String { Issue.record("\(method): \(error)") }
        return object["result"] as? [String: Any] ?? [:]
    }

    private func channels(_ bridge: BridgeCore) async throws -> (group: String, ids: [String]) {
        let groups = try await LiveCatalog(database: bridge.environment.database).groups()
        let news = try #require(groups.first { $0.name == "News" })
        let list = try await LiveCatalog(database: bridge.environment.database).channels(in: news)
        return (news.id, list.map(\.id))
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func deliver(_ engine: FakeEngine, _ type: String, _ extra: String = "") {
        let loadID = engine.loads.last?["loadID"] as? Int ?? 0
        EngineEvents.shared.deliver(#"{"player":"main","loadID":\#(loadID),"type":"\#(type)"\#(extra)}"#)
    }

    @Test func watchingAChannelLoadsItsStreamAndReportsPlaying() async throws {
        let (bridge, engine, log) = try await makeBridge()
        let (group, ids) = try await channels(bridge)
        let state = try await call(bridge, "player.watch", ["channel": ids[0], "group": group])
        #expect((state["channel"] as? [String: Any])?["name"] as? String == "Seven")

        await waitFor { !engine.loads.isEmpty }
        let url = try #require(engine.loads.first?["url"] as? String)
        #expect(url == "http://a.example/live/viewer/pw/7.ts")
        #expect(engine.loads.first?["live"] as? Bool == true)

        deliver(engine, "playing")
        try await log.waitFor { $0.contains(#""phase":"playing""#) }
        _ = await bridge.handle(#"{"method":"player.stop"}"#)
        #expect(engine.commands.contains { $0["command"] as? String == "stop" })
    }

    @Test func aMovieResumesAndSavesItsPositionWhenStopped() async throws {
        let (bridge, engine, log) = try await makeBridge()
        let providerID = try #require(try bridge.environment.providers.repository.all().first?.id)
        let state = try await call(bridge, "vod.play", [
            "kind": "movie", "provider": providerID.rawValue, "id": "42", "position": 120, "title": "The Test Film",
        ])
        #expect((state["vod"] as? [String: Any])?["title"] as? String == "The Test Film")
        #expect(state["channel"] == nil)

        await waitFor { !engine.loads.isEmpty }
        let load = try #require(engine.loads.first)
        #expect(load["url"] as? String == "http://a.example/movie/viewer/pw/42.mkv")
        #expect(load["live"] as? Bool == false)
        #expect(load["startPosition"] as? Double == 120)

        deliver(engine, "playing")
        try await log.waitFor { $0.contains(#""phase":"playing""#) }
        // Zapping does nothing during a movie.
        _ = try await call(bridge, "player.zap", ["by": 1])
        #expect(engine.loads.count == 1)
        // The watchdog reads the position; stopping saves it.
        await waitFor { engine.commands.contains { $0["command"] as? String == "metrics" } }
        try await Task.sleep(for: .milliseconds(1500)) // the tracker reads the position once a second
        _ = try await call(bridge, "player.stop")
        let vod = VODCatalog(database: bridge.environment.database)
        var saved: WatchProgress?
        for _ in 0..<100 {
            saved = try await vod.progress(kind: .movie, providerID: providerID, itemID: "42")
            if saved != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect((saved?.positionSeconds ?? 0) > 0)
        try await log.waitFor { $0.contains(#""type":"vod""#) }
        // And it's in Recently Watched.
        #expect(try await vod.recentlyWatched(.movie).map(\.itemID) == ["42"])
    }

    @Test func pauseResumeAndSeekReachTheEngine() async throws {
        let (bridge, engine, _) = try await makeBridge()
        let providerID = try #require(try bridge.environment.providers.repository.all().first?.id)
        _ = try await call(bridge, "vod.play", ["kind": "movie", "provider": providerID.rawValue, "id": "42", "title": "Film"])
        await waitFor { !engine.loads.isEmpty }
        #expect(engine.loads.first?["startPosition"] == nil)
        deliver(engine, "playing")
        _ = try await call(bridge, "player.pause")
        _ = try await call(bridge, "player.seek", ["position": 300])
        _ = try await call(bridge, "player.resume")
        let names = engine.commands.compactMap { $0["command"] as? String }
        #expect(names.contains("pause"))
        #expect(names.contains("play"))
        #expect(engine.commands.contains { $0["command"] as? String == "seek" && $0["position"] as? Double == 300 })
        _ = try await call(bridge, "player.stop")
    }

    @Test func aRefusedStreamMovesToTheNextFormat() async throws {
        let (bridge, engine, _) = try await makeBridge()
        let (group, ids) = try await channels(bridge)
        _ = try await call(bridge, "player.watch", ["channel": ids[0], "group": group])
        await waitFor { !engine.loads.isEmpty }
        deliver(engine, "failed", #","kind":"http","status":404"#)
        await waitFor { engine.loads.count >= 2 }
        #expect(engine.loads.last?["url"] as? String == "http://a.example/live/viewer/pw/7.m3u8")
        _ = await bridge.handle(#"{"method":"player.stop"}"#)
    }

    @Test func zappingNumbersAndPrevious() async throws {
        let (bridge, _, _) = try await makeBridge()
        let (group, ids) = try await channels(bridge)
        _ = try await call(bridge, "player.watch", ["channel": ids[0], "group": group])
        var state = try await call(bridge, "player.zap", ["by": 1])
        #expect((state["channel"] as? [String: Any])?["name"] as? String == "Eight")
        state = try await call(bridge, "player.zap", ["by": -2])
        #expect((state["channel"] as? [String: Any])?["name"] as? String == "Nine")
        state = try await call(bridge, "player.number", ["number": 101])
        #expect((state["channel"] as? [String: Any])?["name"] as? String == "Seven")
        state = try await call(bridge, "player.previous")
        #expect((state["channel"] as? [String: Any])?["name"] as? String == "Nine")
        #expect(state["hasPrevious"] as? Bool == true)
        _ = await bridge.handle(#"{"method":"player.stop"}"#)
    }

    @Test func watchingIsRecordedInRecents() async throws {
        let (bridge, _, _) = try await makeBridge()
        let (group, ids) = try await channels(bridge)
        _ = try await call(bridge, "player.watch", ["channel": ids[1], "group": group])
        let database = bridge.environment.database
        func recents() async throws -> [RecentItem] { try await database.reader.read { try RecentItem.fetchAll($0) } }
        for _ in 0..<100 {
            if try await !recents().isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await recents().map(\.itemID) == ["8"])
        _ = await bridge.handle(#"{"method":"player.stop"}"#)
    }

    @Test func aPreviewIsntRecordedAndGoingFullScreenDoesntReopenIt() async throws {
        let (bridge, engine, _) = try await makeBridge()
        let (group, ids) = try await channels(bridge)
        _ = try await call(bridge, "player.watch", ["channel": ids[1], "group": group, "preview": true])
        await waitFor { !engine.loads.isEmpty }
        let database = bridge.environment.database
        func recents() async throws -> [RecentItem] { try await database.reader.read { try RecentItem.fetchAll($0) } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await recents().isEmpty)

        // Full screen: the same channel carries on, and now counts as watched.
        _ = try await call(bridge, "player.watch", ["channel": ids[1], "group": group])
        for _ in 0..<100 {
            if try await !recents().isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await recents().map(\.itemID) == ["8"])
        #expect(engine.loads.count == 1)
        _ = await bridge.handle(#"{"method":"player.stop"}"#)
    }
}
