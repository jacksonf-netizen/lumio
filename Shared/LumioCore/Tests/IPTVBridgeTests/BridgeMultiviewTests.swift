import Foundation
import Testing
@testable import IPTVBridge
import GRDB
import IPTVCore

// Inside the playback suite so the two never run at once: engines are registered by player name
// ("main", "tile0"…) in one shared table.
extension BridgePlayerTests {
    /// Multiview through the bridge, with fake engines: tiles spread across providers, the warning when
    /// no provider has a free connection, and a device without a free decoder.
    @Suite("Bridge: multiview")
    @MainActor
    struct Multiview {
        /// Records every player's commands.
        final class FakeEngines: @unchecked Sendable {
            var commands: [[String: Any]] = []
            func handle(_ json: String) -> String? {
                let command = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
                commands.append(command)
                if command["command"] as? String == "metrics" {
                    let count = commands.count
                    return #"{"result":{"position":\#(count),"bytesReceived":\#(count * 1000),"bufferSeconds":4}}"#
                }
                return #"{"result":null}"#
            }
            func loads(_ player: String) -> [[String: Any]] {
                commands.filter { $0["command"] as? String == "load" && $0["player"] as? String == player }
            }
            func host(_ player: String) -> String? {
                (loads(player).last?["url"] as? String).flatMap { URL(string: $0)?.host }
            }
        }

        /// Providers A and B, one connection each, both carrying "Seven"; only A has "Eight".
        private func makeBridge() async throws -> (BridgeCore, FakeEngines, EventLog) {
            let engines = FakeEngines()
            let log = EventLog()
            let environment = AppEnvironment.preview()
            for (name, channels) in [("A", [(7, "Seven"), (8, "Eight")]), ("B", [(70, "Seven")])] {
                let provider = try await environment.providers.addProvider(
                    name: name, servers: "http://\(name.lowercased()).example",
                    credentials: ProviderCredentials(username: "viewer", password: "pw"))
                await environment.connections.setLimit(1, for: provider.id)
                try await environment.database.writer.write { db in
                    try Category(providerID: provider.id, kind: .live, categoryID: "1", name: "News", sortIndex: 0).insert(db)
                    for (n, channel) in channels.enumerated() {
                        try Channel(providerID: provider.id, streamID: channel.0, number: 101 + n, name: channel.1,
                                    categoryID: "1", sortIndex: n).insert(db)
                    }
                }
            }
            try environment.logicalChannels.rebuild()
            let bridge = BridgeCore(environment: environment, playerCommands: { engines.handle($0) }, events: { log.append($0) })
            await bridge.start(backgroundWork: false)
            return (bridge, engines, log)
        }

        private func call(_ bridge: BridgeCore, _ method: String, _ params: [String: Any] = [:],
                          expectError: Bool = false) async throws -> [String: Any] {
            let request = try JSONSerialization.data(withJSONObject: ["method": method, "params": params])
            let reply = await bridge.handle(String(decoding: request, as: UTF8.self))
            let object = try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
            let error = object["error"] as? String
            if expectError { #expect(error != nil, "\(method) should fail") } else if let error { Issue.record("\(method): \(error)") }
            return object["result"] as? [String: Any] ?? [:]
        }

        private func channel(_ bridge: BridgeCore, _ name: String) async throws -> (id: String, group: String) {
            let catalog = LiveCatalog(database: bridge.environment.database)
            let groups = try await catalog.groups()
            let news = try #require(groups.first { $0.name == "News" })
            let found = try #require(try await catalog.channels(in: news).first { $0.name == name })
            return (found.id, news.id)
        }

        private func waitFor(_ condition: () -> Bool) async {
            for _ in 0..<250 where !condition() { try? await Task.sleep(for: .milliseconds(20)) }
        }

        private func deliver(_ engines: FakeEngines, _ player: String, _ type: String, _ extra: String = "") {
            let loadID = engines.loads(player).last?["loadID"] as? Int ?? 0
            EngineEvents.shared.deliver(#"{"player":"\#(player)","loadID":\#(loadID),"type":"\#(type)"\#(extra)}"#)
        }

        private func tiles(_ state: [String: Any]) -> [[String: Any]] { state["tiles"] as? [[String: Any]] ?? [] }

        @Test func tilesSpreadAcrossProvidersAndWarnWhenNoneIsFree() async throws {
            let (bridge, engines, log) = try await makeBridge()
            let seven = try await channel(bridge, "Seven")
            let eight = try await channel(bridge, "Eight")

            // The full-screen player is watching; multiview stops it first.
            _ = try await call(bridge, "player.watch", ["channel": seven.id, "group": seven.group])
            await waitFor { !engines.loads("main").isEmpty }
            var state = try await call(bridge, "multiview.start", ["layout": 2, "channel": seven.id, "group": seven.group])
            #expect(state["active"] as? Bool == true)
            #expect(tiles(state).count == 2)
            #expect((tiles(state)[0]["channel"] as? [String: Any])?["name"] as? String == "Seven")
            #expect(tiles(state)[0]["group"] as? String == seven.group)
            await waitFor { !engines.loads("tile0").isEmpty }
            #expect(engines.commands.contains { $0["player"] as? String == "main" && $0["command"] as? String == "stop" })

            // The same channel in the second tile: one connection each, so it plays from the other provider.
            _ = try await call(bridge, "multiview.setChannel", ["tile": 1, "channel": seven.id, "group": seven.group])
            await waitFor { !engines.loads("tile1").isEmpty }
            #expect(Set([engines.host("tile0"), engines.host("tile1")]) == ["a.example", "b.example"])
            state = try await call(bridge, "multiview.state")
            #expect(Set(tiles(state).compactMap { $0["providerID"] as? String }).count == 2)
            #expect((tiles(state)[1]["providers"] as? [[String: Any]])?.compactMap { $0["name"] as? String }.sorted() == ["A", "B"])
            #expect(state["warning"] == nil)

            // A third tile has no free connection anywhere.
            _ = try await call(bridge, "multiview.layout", ["layout": 3])
            _ = try await call(bridge, "multiview.setChannel", ["tile": 2, "channel": eight.id])
            try await log.waitFor { $0.contains(#""type":"multiview""#) && $0.contains("free connection") }
            state = try await call(bridge, "multiview.state")
            #expect((state["warning"] as? String)?.contains("free connection") == true)

            // Audio follows the chosen tile; the others are muted.
            _ = try await call(bridge, "multiview.focusAudio", ["tile": 1])
            let volumes = engines.commands.filter { $0["command"] as? String == "volume" }
            #expect(volumes.last { $0["player"] as? String == "tile1" }?["muted"] as? Bool == false)
            #expect(volumes.last { $0["player"] as? String == "tile0" }?["muted"] as? Bool == true)

            // Checks.
            _ = try await call(bridge, "multiview.layout", ["layout": 5], expectError: true)
            _ = try await call(bridge, "multiview.clearTile", ["tile": 3], expectError: true)
            _ = try await call(bridge, "multiview.pinProvider", ["tile": 2, "provider": "nobody"], expectError: true)

            // Stopping closes every stream and frees every connection.
            state = try await call(bridge, "multiview.stop")
            #expect(state["active"] as? Bool == false)
            #expect(await bridge.environment.connections.totalInUse == 0)
        }

        @Test func aNewTileWaitsRatherThanStoppingOneThatPlays() async throws {
            let (bridge, engines, log) = try await makeBridge()
            let seven = try await channel(bridge, "Seven")
            let eight = try await channel(bridge, "Eight")
            // Tile 2 plays Eight (only on A), tile 3 plays Seven: one connection each, both used.
            _ = try await call(bridge, "multiview.start", ["layout": 3])
            _ = try await call(bridge, "multiview.setChannel", ["tile": 1, "channel": eight.id])
            _ = try await call(bridge, "multiview.setChannel", ["tile": 2, "channel": seven.id])
            await waitFor { !engines.loads("tile1").isEmpty && !engines.loads("tile2").isEmpty }
            for tile in ["tile1", "tile2"] { deliver(engines, tile, "playing") }
            try await log.waitFor { $0.contains(#""type":"multiview""#) && $0.components(separatedBy: #""phase":"playing""#).count > 2 }
            let loads = engines.loads("tile1").count + engines.loads("tile2").count

            // Filling tile 1 can't fit. The two playing tiles carry on; the warning is about the new one.
            _ = try await call(bridge, "multiview.setChannel", ["tile": 0, "channel": seven.id])
            try await log.waitFor { $0.contains("free connection") }
            let state = try await call(bridge, "multiview.state")
            #expect((state["warning"] as? String)?.contains("Seven") == true)
            #expect(tiles(state)[0]["providerID"] == nil)
            #expect(engines.loads("tile1").count + engines.loads("tile2").count == loads)
            #expect(!engines.commands.contains { ["tile1", "tile2"].contains($0["player"] as? String) && $0["command"] as? String == "stop" })
            _ = try await call(bridge, "multiview.stop")
        }

        @Test func noFreeDecoderStopsTheTileWithoutTryingOtherSources() async throws {
            let (bridge, engines, log) = try await makeBridge()
            let seven = try await channel(bridge, "Seven")
            _ = try await call(bridge, "multiview.start", ["layout": 2, "channel": seven.id, "group": seven.group])
            await waitFor { !engines.loads("tile0").isEmpty }
            deliver(engines, "tile0", "failed", #","kind":"noFreeDecoder""#)
            try await log.waitFor { $0.contains(#""phase":"failed""#) && $0.contains("another video") }
            // No other format or provider was tried.
            #expect(engines.loads("tile0").count == 1)
            let state = try await call(bridge, "multiview.state")
            #expect((tiles(state)[0]["message"] as? String)?.contains("another video") == true)
            _ = try await call(bridge, "multiview.stop")
            #expect(await bridge.environment.connections.totalInUse == 0)
        }
    }
}
