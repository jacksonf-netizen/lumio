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
    func waitFor(_ predicate: (String) -> Bool) async throws {
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
