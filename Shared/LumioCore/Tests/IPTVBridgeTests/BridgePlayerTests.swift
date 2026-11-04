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
}
