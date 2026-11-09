import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import Testing
@testable import IPTVCore

/// Answers `player_api.php` per host: listed hosts are up, others can't be reached.
final class LinkTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var up: Set<String>
    private var _offline = false
    private var _wrongPassword = false
    private(set) var hosts: [String] = []

    init(up: Set<String>) { self.up = up }

    var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }
    var wrongPassword: Bool {
        get { lock.withLock { _wrongPassword } }
        set { lock.withLock { _wrongPassword = newValue } }
    }
    /// Hosts that answer "wrong password" whatever the login (an address now used by another panel).
    private var otherPanel: Set<String> = []
    /// Hosts that accept the connection and never answer.
    private var hanging: Set<String> = []
    /// Hosts whose flood protection answers "not found" to their next request.
    private var flooded: Set<String> = []
    private var inFlight = 0
    private(set) var mostAtOnce = 0
    func setUp(_ hosts: Set<String>) { lock.withLock { up = hosts } }
    func setOtherPanel(_ hosts: Set<String>) { lock.withLock { otherPanel = hosts } }
    func setHanging(_ hosts: Set<String>) { lock.withLock { hanging = hosts } }
    func setFlooded(_ hosts: Set<String>) { lock.withLock { flooded = hosts } }
    var mostRequestsAtOnce: Int { lock.withLock { mostAtOnce } }
    var requestedHosts: [String] { lock.withLock { hosts } }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let host = request.url!.host!
        let (isUp, offline, wrong, hangs, flood) = lock.withLock { () -> (Bool, Bool, Bool, Bool, Bool) in
            hosts.append(host)
            inFlight += 1
            mostAtOnce = max(mostAtOnce, inFlight)
            return (up.contains(host), _offline, _wrongPassword || otherPanel.contains(host), hanging.contains(host),
                    flooded.remove(host) != nil)
        }
        defer { lock.withLock { inFlight -= 1 } }
        try await Task.sleep(for: .milliseconds(5))
        if flood {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        if hangs {
            try await Task.sleep(for: .seconds(60))
            throw URLError(.timedOut)
        }
        if offline { throw URLError(.notConnectedToInternet) }
        guard isUp else { throw URLError(.cannotConnectToHost) }
        let body = Fixture.data(wrong ? "xtream/auth_failed.json" : "xtream/auth_ok.json")
        if StubTransport.key(for: request) == "auth" || wrong {
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    /// The guide, from hosts that are up.
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        guard lock.withLock({ up.contains(request.url!.host!) }) else { throw URLError(.cannotConnectToHost) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("links-\(UUID().uuidString)")
        try Fixture.data("xmltv/guide.xml").write(to: file)
        return (file, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@Suite("Server links")
struct ServerLinkTests {
    // MARK: Pasting

    @Test func readsOneLinkPerLineInOrder() throws {
        let list = try ServerURL.parseList("""
            http://one.example.com:8080

            2. two.example.com:8080/
            - http://three.example.com
            URL: http://four.example.com:2095/player_api.php
            http://one.example.com:8080
            203.0.113.7:8000
            """)
        #expect(list.urls.map(\.absoluteString) == [
            "http://one.example.com:8080", "http://two.example.com:8080", "http://three.example.com",
            "http://four.example.com:2095", "http://203.0.113.7:8000",
        ])
        #expect(list.credentials == nil)
    }

    @Test func readsSeveralLinksOnOneLine() throws {
        // What a TV's one-line field gets when a list is pasted into it.
        let list = try ServerURL.parseList(
            "http://one.example.com:8080 https://two.example.com, http://three.example.com:2095/get.php?username=jo&password=x;"
                + "HTTP://four.example.com")
        #expect(list.urls.map(\.absoluteString) == [
            "http://one.example.com:8080", "https://two.example.com", "http://three.example.com:2095", "http://four.example.com",
        ])
        #expect(list.credentials == ProviderCredentials(username: "jo", password: "x"))
        #expect(try ServerURL.parseList("Main: http://a.example.com or backup http://b.example.com").urls.map(\.absoluteString)
            == ["http://a.example.com", "http://b.example.com"])
        #expect(try ServerURL.parseList("a.example.com:8080, b.example.com  203.0.113.7:8000").urls.map(\.absoluteString)
            == ["http://a.example.com:8080", "http://b.example.com", "http://203.0.113.7:8000"])
        // Addresses without http:// next to ones with it; labels and numbers around them don't count.
        #expect(try ServerURL.parseList("URL: http://a.example.com, b.example.com:8080 or 203.0.113.7 (v2.0, 3 links)")
            .urls.map(\.absoluteString) == ["http://a.example.com", "http://b.example.com:8080", "http://203.0.113.7"])
        #expect(throws: ServerURLError.notALink(line: 1)) { try ServerURL.parseList("a.example.com and more") }
    }

    @Test func takesTheLoginOutOfM3ULinks() throws {
        let list = try ServerURL.parseList("""
            http://a.example.com:8080/get.php?username=jo&password=p%2Bss&type=m3u_plus&output=ts
            http://b.example.com/get.php?username=jo&password=p%2Bss&type=m3u_plus
            """)
        #expect(list.urls.map(\.absoluteString) == ["http://a.example.com:8080", "http://b.example.com"])
        #expect(list.credentials == ProviderCredentials(username: "jo", password: "p+ss"))
        // A single address still refuses a login inside it.
        #expect(throws: ServerURLError.containsCredentials) {
            try ServerURL.normalize("http://a.example.com/get.php?username=jo&password=x")
        }
    }

    @Test func refusesWhatIsntAListOfLinks() {
        #expect(throws: ServerURLError.notALink(line: 2)) { try ServerURL.parseList("http://a.example.com\nUsername: jo") }
        #expect(throws: ServerURLError.differentLogins) {
            try ServerURL.parseList("http://a.test/get.php?username=jo&password=1\nhttp://b.test/get.php?username=al&password=2")
        }
        #expect(throws: ServerURLError.empty) { try ServerURL.parseList(" \n\n") }
    }

    @Test func takesTheLoginOutOfStreamLinks() throws {
        let list = try ServerURL.parseList("""
            http://a.example.com:8080/live/jo/p+ss/1234.ts
            http://b.example.com/movie/jo/p+ss/99.mkv
            """)
        #expect(list.urls.map(\.absoluteString) == ["http://a.example.com:8080", "http://b.example.com"])
        #expect(list.credentials == ProviderCredentials(username: "jo", password: "p+ss"))
        #expect(throws: ServerURLError.containsCredentials) {
            try ServerURL.normalize("http://a.example.com/live/jo/x/1.ts")
        }
        // A panel that lives under a path keeps it.
        #expect(try ServerURL.normalize("http://a.example.com/live").absoluteString == "http://a.example.com/live")
    }

    // MARK: Storage

    @Test func addingAndEditingKeepsOrderAndWhatChecksLearnt() async throws {
        let database = try AppDatabase.inMemory()
        let service = ProviderService(database: database, secrets: InMemorySecretStore())
        let provider = try await service.addProvider(name: "P", servers: "a.test\nb.test\nc.test",
                                                     credentials: ProviderCredentials(username: "u", password: "p"))
        let repo = service.repository
        #expect(provider.serverURL.absoluteString == "http://a.test")
        try repo.recordCheck(provider.id, url: URL(string: "http://b.test")!, at: Date(), failure: "down")
        try repo.setActive(URL(string: "http://c.test")!, for: provider.id)

        // Reordered, one removed, one added: b keeps its status, c stays in use.
        try await service.updateProvider(provider, servers: "c.test\nb.test\nd.test")
        let links = try repo.links(for: provider.id)
        #expect(links.map(\.url.host) == ["c.test", "b.test", "d.test"])
        #expect(links.map(\.position) == [0, 1, 2])
        #expect(links[1].isDown)
        #expect(try repo.provider(id: provider.id)?.serverURL.host == "c.test")

        // The address in use was removed: the first link takes over.
        try await service.updateProvider(provider, servers: "d.test")
        #expect(try repo.provider(id: provider.id)?.serverURL.host == "d.test")
        // A link that isn't the provider's can't be made active.
        try repo.setActive(URL(string: "http://elsewhere.test")!, for: provider.id)
        #expect(try repo.provider(id: provider.id)?.serverURL.host == "d.test")
    }

    @Test func upgradingMakesTheCurrentAddressTheFirstLink() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v8-episode-relink")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO provider (id, name, kind, serverURL, createdAt) VALUES ('p', 'P', 'xtream', 'http://p.test:8080', 0);
                INSERT INTO favorite (providerID, itemKind, itemID, addedAt) VALUES ('p', 'channel', '1', 0);
                """)
        }
        try AppDatabase.migrator.migrate(queue)
        let links = try queue.read { db in try ServerLink.fetchAll(db) }
        #expect(links.map(\.url.absoluteString) == ["http://p.test:8080"])
        #expect(links.map(\.position) == [0])
        #expect(try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM favorite") } == 1)
    }

    @Test func providersFromBeforeLinksHaveTheirAddressAsTheOnlyLink() throws {
        let database = try AppDatabase.inMemory()
        let provider = Provider(name: "Old", serverURL: URL(string: "http://old.test")!)
        try database.writer.write { db in try provider.insert(db) }
        let repo = ProviderRepository(database: database)
        #expect(try repo.links(for: provider.id).map(\.url) == [provider.serverURL])
        try repo.recordCheck(provider.id, url: provider.serverURL, at: Date(), failure: "gone")
        #expect(try repo.links(for: provider.id).allDown)
    }

    // MARK: Failover

    struct World {
        let database: AppDatabase
        let service: ProviderService
        let transport: LinkTransport
        let failover: ServerFailover
        let clock: ManualClock
        let id: ProviderID

        init(links: String, up: Set<String>) async throws {
            database = try AppDatabase.inMemory()
            let secrets = InMemorySecretStore()
            service = ProviderService(database: database, secrets: secrets)
            transport = LinkTransport(up: up)
            clock = ManualClock(Date(timeIntervalSince1970: 1_800_000_000))
            failover = ServerFailover(database: database, secrets: secrets, transport: transport, clock: clock, probeTimeout: 1, pacing: 0)
            id = try await service.addProvider(name: "P", servers: links,
                                               credentials: ProviderCredentials(username: "u", password: "p")).id
        }

        var active: String? { (try? service.repository.provider(id: id))?.serverURL.host }
        var links: [ServerLink] { (try? service.repository.links(for: id)) ?? [] }
    }

    @Test func movesToTheFirstLinkInOrderThatAnswers() async throws {
        let world = try await World(links: "a.test\nb.test\nc.test\nd.test", up: ["c.test", "d.test"])
        #expect(await world.failover.ensureWorking(world.id) == .switched(to: URL(string: "http://c.test")!))
        #expect(world.active == "c.test")
        #expect(world.links.map(\.isDown) == [true, true, false, false])
        #expect(world.links[0].lastFailure?.isEmpty == false)
        #expect(!world.links.allDown)
    }

    @Test func staysOnALinkThatAnswers() async throws {
        let world = try await World(links: "a.test\nb.test", up: ["a.test", "b.test"])
        #expect(await world.failover.ensureWorking(world.id) == .working)
        #expect(world.active == "a.test")
        // A stream failing just after the server answered isn't checked again.
        #expect(await world.failover.streamFailed(providerID: world.id) == false)
        #expect(world.transport.requestedHosts.filter { $0 == "a.test" }.count == 1)
    }

    @Test func aStreamFailureOnADeadServerSwitchesLinks() async throws {
        let world = try await World(links: "a.test\nb.test", up: ["a.test", "b.test"])
        #expect(await world.failover.ensureWorking(world.id) == .working)
        world.transport.setUp(["b.test"])
        world.clock.advance(60)
        #expect(await world.failover.streamFailed(providerID: world.id))
        #expect(world.active == "b.test")
    }

    @Test func recheckGoesBackUpWhenAHigherLinkReturns() async throws {
        let world = try await World(links: "a.test\nb.test", up: ["b.test"])
        #expect(await world.failover.recheck(world.id) == .switched(to: URL(string: "http://b.test")!))
        #expect(world.links[0].isDown)
        world.transport.setUp(["a.test", "b.test"])
        // The quick check doesn't look further up while the link in use works...
        #expect(await world.failover.ensureWorking(world.id) == .working)
        #expect(world.active == "b.test")
        // ...the periodic one does.
        #expect(await world.failover.recheck(world.id) == .switched(to: URL(string: "http://a.test")!))
        #expect(world.links.map(\.isDown) == [false, false])
    }

    @Test func reportsWhenEveryLinkIsDown() async throws {
        let world = try await World(links: "a.test\nb.test", up: [])
        #expect(await world.failover.recheck(world.id) == .allDown)
        #expect(world.links.allDown)
        #expect(world.active == "a.test")
        let since = try #require(world.links[0].downSince)
        // Still down later: "down since" keeps the first time.
        world.clock.advance(300)
        await world.failover.recheckAllDown()
        #expect(world.links[0].downSince == since)
        world.transport.setUp(["b.test"])
        await world.failover.recheckAllDown()
        #expect(world.active == "b.test")
        #expect(!world.links.allDown)
    }

    @Test func beingOfflineMarksNothingDown() async throws {
        let world = try await World(links: "a.test\nb.test", up: ["a.test"])
        world.transport.offline = true
        #expect(await world.failover.recheck(world.id) == .offline)
        #expect(world.links.allSatisfy { !$0.isDown && $0.lastCheckedAt == nil })
    }

    @Test func aWrongPasswordIsntAReasonToSwitch() async throws {
        let world = try await World(links: "a.test\nb.test", up: ["a.test", "b.test"])
        world.transport.wrongPassword = true
        #expect(await world.failover.recheck(world.id) == .working)
        #expect(world.active == "a.test")
        #expect(world.links.allSatisfy { !$0.isDown })
    }

    @Test func aLinkDownForADayIsDeadAndNoLongerChecked() async throws {
        let world = try await World(links: "a.test\nb.test", up: ["b.test"])
        func triesOfA() -> Int { world.transport.requestedHosts.filter { $0 == "a.test" }.count }
        await world.failover.recheck(world.id)
        #expect(world.links[0].isDown && !world.links[0].isDead)
        // Down for a few hours isn't dead yet.
        world.clock.advance(6 * 3600)
        await world.failover.recheck(world.id)
        #expect(!world.links[0].isDead)
        world.clock.advance(19 * 3600)
        await world.failover.recheck(world.id)
        #expect(world.links[0].isDead)
        let tries = triesOfA()
        for _ in 0..<4 {
            world.clock.advance(6 * 3600)
            await world.failover.recheck(world.id)
            await world.failover.ensureWorking(world.id)
        }
        #expect(triesOfA() == tries)
        #expect(!world.links.allDown)
        // Refresh in Settings tries it again, and a link that answers is back.
        world.transport.setUp(["a.test", "b.test"])
        #expect(await world.failover.recheck(world.id, includingDead: true) == .switched(to: URL(string: "http://a.test")!))
        #expect(world.links.allSatisfy { !$0.isDown })
    }

    @Test func deadLinksGetOneTryADayWhenNothingElseWorks() async throws {
        let world = try await World(links: "a.test\nb.test", up: [])
        func tries() -> Int { world.transport.requestedHosts.count }
        await world.failover.recheck(world.id)
        world.clock.advance(25 * 3600)
        await world.failover.recheck(world.id)
        #expect(world.links.allSatisfy { $0.isDead })
        let before = tries()
        // The 5-minute checks for a provider that's down leave dead links alone...
        for _ in 0..<12 {
            world.clock.advance(300)
            await world.failover.recheckAllDown()
        }
        #expect(tries() == before)
        #expect(await world.failover.ensureWorking(world.id) == .allDown)
        // ...until a day has passed: the seller's outage is over.
        world.transport.setUp(["b.test"])
        world.clock.advance(24 * 3600)
        await world.failover.recheckAllDown()
        #expect(world.active == "b.test")
        #expect(!world.links.allDown)
    }

    @Test func asksOneLinkAtATimeAndGivesNotFoundASecondChance() async throws {
        // Three addresses of the same panel, whose flood protection says "not found" to a burst.
        let world = try await World(links: "a.test\nb.test\nc.test", up: ["a.test", "b.test", "c.test"])
        world.transport.setFlooded(["b.test", "c.test"])
        #expect(await world.failover.recheck(world.id) == .working)
        #expect(world.links.allSatisfy { !$0.isDown })
        #expect(world.transport.mostRequestsAtOnce == 1)
        #expect(world.transport.requestedHosts == ["a.test", "b.test", "b.test", "c.test", "c.test"])
    }

    @Test func oddRefusalsAreAServerAnswering() {
        let login = ProviderCredentials(username: "u", password: "p")
        // This panel answers 511 without a login and 513 to a wrong one.
        #expect(ServerFailover.classify(.server(statusCode: 513), credentials: login) == .up(loggedIn: false))
        #expect(ServerFailover.classify(.server(statusCode: 511), credentials: login) == .up(loggedIn: false))
        #expect(ServerFailover.classify(.forbidden, credentials: login) == .up(loggedIn: false))
        // Cloudflare can't reach the server behind it.
        #expect(!ServerFailover.classify(.server(statusCode: 521), credentials: login).isUp)
        #expect(!ServerFailover.classify(.notFound, credentials: login).isUp)
    }

    @Test func aLinkThatLogsInBeatsOneThatOnlyAnswers() async throws {
        // a.test is dead; b.test's domain now runs someone else's panel and refuses the login.
        let world = try await World(links: "a.test\nb.test\nc.test", up: ["b.test", "c.test"])
        world.transport.setOtherPanel(["b.test"])
        #expect(await world.failover.ensureWorking(world.id) == .switched(to: URL(string: "http://c.test")!))
        #expect(world.active == "c.test")
    }

    @Test func aServerThatNeverAnswersDoesntHoldUpTheSwitch() async throws {
        let world = try await World(links: "a.test\nb.test\nc.test", up: ["b.test"])
        world.transport.setHanging(["a.test", "c.test"])
        let started = ContinuousClock.now
        #expect(await world.failover.ensureWorking(world.id) == .switched(to: URL(string: "http://b.test")!))
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(world.links[0].isDown)
    }

    @Test func imagesOnADeadLinkLoadFromTheOneInUse() throws {
        let one = ProviderID("one"), two = ProviderID("two")
        let links = [
            ServerLink(providerID: one, position: 0, url: URL(string: "http://dead.test:8080")!, downSince: Date()),
            ServerLink(providerID: one, position: 1, url: URL(string: "http://standby.test")!),
            ServerLink(providerID: one, position: 2, url: URL(string: "http://live.test")!),
            // Another account from the same seller still uses the address that's dead for `one`.
            ServerLink(providerID: two, position: 0, url: URL(string: "http://shared.test")!),
            ServerLink(providerID: one, position: 3, url: URL(string: "http://shared.test")!, downSince: Date()),
        ]
        let aliases = ServerAliases()
        aliases.update(links, active: [one: URL(string: "http://live.test")!, two: URL(string: "http://shared.test")!])
        #expect(aliases.rewrite(URL(string: "http://dead.test:8080/images/logo.png?x=1")!).absoluteString
                == "http://live.test/images/logo.png?x=1")
        #expect(aliases.rewrite(URL(string: "http://standby.test/a.png")!).absoluteString == "http://standby.test/a.png")
        #expect(aliases.rewrite(URL(string: "http://shared.test/a.png")!).absoluteString == "http://shared.test/a.png")
        #expect(aliases.rewrite(URL(string: "http://dead.test:8081/a.png")!).absoluteString == "http://dead.test:8081/a.png")
    }

    @Test func aRefreshThatCantConnectMovesToAWorkingLink() async throws {
        let world = try await World(links: "a.test\nb.test", up: ["b.test"])
        let secrets = InMemorySecretStore()
        try secrets.save(ProviderCredentials(username: "u", password: "p"), for: world.id)
        let sync = CatalogSyncService(database: world.database,
                                      sources: XtreamSourceFactory(secrets: secrets, transport: world.transport),
                                      connections: ConnectionManager(), servers: world.failover, clock: world.clock)
        let report = await sync.refresh(world.id, parts: .account)
        #expect(report.error == nil)
        #expect(report.account != nil)
        #expect(world.active == "b.test")
    }

    @Test func aGuideRefreshThatCantConnectMovesToAWorkingLink() async throws {
        let world = try await World(links: "a.test\nb.test", up: ["b.test"])
        let secrets = InMemorySecretStore()
        try secrets.save(ProviderCredentials(username: "u", password: "p"), for: world.id)
        let sync = CatalogSyncService(database: world.database,
                                      sources: XtreamSourceFactory(secrets: secrets, transport: world.transport),
                                      connections: ConnectionManager(), servers: world.failover, clock: world.clock)
        let report = await sync.refresh(world.id, parts: .guide)
        #expect(report.partErrors[.guide] == nil)
        #expect(report.guide != nil)
        #expect(world.active == "b.test")
        // Moved straight away instead of waiting to ask the dead link again.
        #expect(world.clock.sleeps.isEmpty)
    }
}

/// Says the server moved the first time it's asked.
final class SwitchingServers: ServerHealth, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    func streamFailed(providerID: ProviderID) async -> Bool {
        lock.withLock { calls += 1; return calls == 1 }
    }
}

@Suite("Playback on a new server link")
@MainActor
struct PlaybackServerLinkTests {
    @Test func retriesTheSameStreamAtOnceAfterASwitch() async throws {
        let world = PlaybackWorld()
        let servers = SwitchingServers()
        world.servers = servers
        world.scripts[.mpv] = [.fail(EngineFailure(.network, "Connection refused")), .play]
        let controller = world.makeController()
        controller.play(TestItems.live())
        #expect(await world.run(until: { controller.phase == .playing }, limit: 2))
        #expect(world.engine(.mpv)?.loadedFormats == ["ts", "ts"])
        #expect(servers.calls == 1)
        #expect(controller.notice == "Switched to a backup server link")
        await controller.stop()
    }

    @Test func decoderTroubleDoesntCheckTheServer() async throws {
        let world = PlaybackWorld()
        let servers = SwitchingServers()
        world.servers = servers
        world.scripts[.mpv] = [.fail(EngineFailure(.decoder)), .play]
        let controller = world.makeController()
        controller.play(TestItems.live())
        #expect(await world.run(until: { controller.phase == .playing }))
        #expect(servers.calls == 0)
        await controller.stop()
    }
}
