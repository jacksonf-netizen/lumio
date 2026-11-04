import Foundation
import Testing
@testable import IPTVCore

@Suite("Fallback ladder")
struct FallbackLadderTests {
    func describe(_ plans: [PlaybackPlan]) -> [String] {
        plans.map { "\($0.source.providerID.rawValue):\($0.engine.rawValue):\($0.format?.rawValue ?? "-")" }
    }

    @Test func liveDefaultsToMpvTSThenHLSThenAVPlayer() {
        let plans = FallbackLadder.plans(for: TestItems.live())
        #expect(describe(plans) == ["prov-a:mpv:ts", "prov-a:mpv:m3u8", "prov-a:avPlayer:m3u8"])
    }

    @Test func respectsAllowedFormats() {
        let item = TestItems.live(sources: [TestItems.source(TestItems.a, 1, formats: [.ts])])
        #expect(describe(FallbackLadder.plans(for: item)) == ["prov-a:mpv:ts"])
    }

    @Test func startsFromWhatWorkedLastTime() {
        var source = TestItems.source(TestItems.a, 1)
        source.lastWorkingEngine = .avPlayer
        source.lastWorkingFormat = .m3u8
        let plans = FallbackLadder.plans(for: TestItems.live(sources: [source]))
        #expect(describe(plans) == ["prov-a:avPlayer:m3u8", "prov-a:mpv:m3u8", "prov-a:mpv:ts"])
    }

    @Test func perChannelEngineOverrideLocksTheEngine() {
        var source = TestItems.source(TestItems.a, 1)
        source.engineOverride = .mpv
        #expect(describe(FallbackLadder.plans(for: TestItems.live(sources: [source]))) == ["prov-a:mpv:ts", "prov-a:mpv:m3u8"])
    }

    @Test func otherProvidersFollowInOrder() {
        let item = TestItems.live(sources: [TestItems.source(TestItems.a, 1, formats: [.ts]), TestItems.source(TestItems.b, 2, formats: [.ts])])
        #expect(describe(FallbackLadder.plans(for: item)) == ["prov-a:mpv:ts", "prov-b:mpv:ts"])
    }

    @Test func vodOnlyOffersAVPlayerForContainersItCanOpen() {
        #expect(describe(FallbackLadder.plans(for: TestItems.movie(ext: "mp4"))) == ["prov-a:mpv:-", "prov-a:avPlayer:-"])
        #expect(describe(FallbackLadder.plans(for: TestItems.movie(ext: "mkv"))) == ["prov-a:mpv:-"])
    }

    @Test func backoffIsExponentialCappedAndJittered() {
        let settings = PlaybackSettings()
        #expect(settings.backoff(attempt: 1, jitter: 1) == 1)
        #expect(settings.backoff(attempt: 1, jitter: 0) == 0.5)
        #expect(settings.backoff(attempt: 3, jitter: 1) == 4)
        #expect(settings.backoff(attempt: 10, jitter: 1) == 15)
        #expect(settings.backoff(attempt: 10, jitter: 0) == 7.5)
    }
}

@Suite("Reconnect state machine", .serialized)
@MainActor
struct PlaybackControllerTests {
    @Test func playsAndHoldsAConnection() async throws {
        let world = PlaybackWorld()
        let controller = world.makeController()
        controller.play(TestItems.live())
        #expect(await world.run(until: { controller.phase == .playing }))
        #expect(await world.connections.usage(for: TestItems.a).inUse == 1)
        #expect(controller.redactedURL?.contains("secret") == false)
        #expect(world.history.successes.count == 1)
        await controller.stop()
        #expect(await world.connections.totalInUse == 0)
        #expect(world.counter.current == 0)
    }

    @Test func stallIsDetectedAndReconnectsAutomatically() async throws {
        let world = PlaybackWorld()
        let controller = world.makeController()
        controller.play(TestItems.live())
        #expect(await world.run(until: { controller.phase == .playing }))
        let engine = try #require(world.engine(.mpv))

        engine.flowing = false
        // Stall timeout is 8 s; the watchdog must react, not wait forever.
        #expect(await world.run(until: { controller.phase.isRecovering }, limit: 10))
        #expect(await world.run(until: { controller.phase == .playing }, limit: 10))
        #expect(engine.loads.count == 2)
        #expect(controller.reconnectCount == 1)
        #expect(world.counter.peak == 1)
        await controller.stop()
    }

    @Test func fallsBackThroughFormatsThenEngines() async throws {
        let world = PlaybackWorld()
        world.scripts[.mpv] = [.fail(EngineFailure(.network))]
        world.scripts[.avPlayer] = [.play]
        let controller = world.makeController()
        controller.play(TestItems.live())
        #expect(await world.run(until: { controller.phase == .playing }))
        let mpv = try #require(world.engine(.mpv))
        #expect(mpv.loadedFormats == ["ts", "ts", "ts", "m3u8", "m3u8", "m3u8"])
        #expect(world.engine(.avPlayer)?.loadedFormats == ["m3u8"])
        #expect(controller.plan?.engine == .avPlayer)
        #expect(world.history.failures.count == 2)
        await controller.stop()
    }

    @Test func notFoundSkipsStraightToTheNextRung() async throws {
        let world = PlaybackWorld()
        world.scripts[.mpv] = [.fail(EngineFailure(.httpStatus(404))), .play]
        let controller = world.makeController()
        controller.play(TestItems.live())
        #expect(await world.run(until: { controller.phase == .playing }))
        #expect(world.engine(.mpv)?.loadedFormats == ["ts", "m3u8"])
        await controller.stop()
    }

    @Test func failsOverToAnotherProviderWhenOneIsBroken() async throws {
        let world = PlaybackWorld()
        await world.connections.setLimit(1, for: TestItems.a)
        await world.connections.setLimit(1, for: TestItems.b)
        // Provider A's stream is gone on every format and engine; B works.
        world.scripts[.mpv] = [.fail(EngineFailure(.httpStatus(404))), .fail(EngineFailure(.httpStatus(404))), .play]
        world.scripts[.avPlayer] = [.fail(EngineFailure(.httpStatus(404)))]
        let item = TestItems.live(sources: [TestItems.source(TestItems.a, 1, priority: 0), TestItems.source(TestItems.b, 2, priority: 1)])
        let controller = world.makeController()
        controller.play(item)
        #expect(await world.run(until: { controller.phase == .playing }))
        #expect(controller.plan?.source.providerID == TestItems.b)
        #expect(await world.connections.usage(for: TestItems.a).inUse == 0)
        #expect(await world.connections.usage(for: TestItems.b).inUse == 1)
        #expect(controller.notice?.contains("Provider B") == true)
        #expect(world.counter.peak == 1)
        await controller.stop()
    }

    @Test func aRefusingProviderIsSkippedStraightToTheNextProvider() async throws {
        let world = PlaybackWorld()
        world.scripts[.mpv] = [.fail(EngineFailure(.httpStatus(403))), .play]
        let item = TestItems.live(sources: [TestItems.source(TestItems.a, 1, priority: 0), TestItems.source(TestItems.b, 2, priority: 1)])
        let controller = world.makeController()
        controller.play(item)
        #expect(await world.run(until: { controller.phase == .playing }))
        // One refusal from A, then B: no time spent on A's HLS or AVPlayer.
        #expect(world.engine(.mpv)?.loads.map { $0.url.host() ?? "" } == ["prov-a.test", "prov-b.test"])
        #expect(world.engine(.avPlayer) == nil)
        await controller.stop()
    }

    @Test func withOneProviderARefusalStillTriesTheOtherFallbacks() async throws {
        let world = PlaybackWorld()
        world.scripts[.mpv] = [.fail(EngineFailure(.httpStatus(404))), .play]
        let controller = world.makeController()
        controller.play(TestItems.live())
        #expect(await world.run(until: { controller.phase == .playing }))
        #expect(world.engine(.mpv)?.loadedFormats == ["ts", "m3u8"])
        await controller.stop()
    }

    @Test func prefersAProviderWithAFreeSlot() async throws {
        let world = PlaybackWorld()
        _ = try await world.connections.acquire(TestItems.a, purpose: .tile(9)) // A is full
        let item = TestItems.live(sources: [TestItems.source(TestItems.a, 1, priority: 0), TestItems.source(TestItems.b, 2, priority: 1)])
        let controller = world.makeController()
        controller.play(item)
        #expect(await world.run(until: { controller.phase == .playing }))
        #expect(controller.plan?.source.providerID == TestItems.b)
        #expect(world.engine(.mpv)?.loads.count == 1)
        await controller.stop()
    }

    @Test func reportsClearlyWhenNoProviderHasASlot() async throws {
        let world = PlaybackWorld()
        _ = try await world.connections.acquire(TestItems.a, purpose: .tile(8))
        _ = try await world.connections.acquire(TestItems.b, purpose: .tile(9))
        let item = TestItems.live(sources: [TestItems.source(TestItems.a, 1), TestItems.source(TestItems.b, 2)])
        let controller = world.makeController(.tile(0))
        controller.play(item)
        #expect(await world.run(until: { if case .failed = controller.phase { true } else { false } }))
        guard case .failed(let failure) = controller.phase else { return }
        #expect(failure.noConnection)
        #expect(world.engine(.mpv) == nil) // never opened a stream
    }

    @Test func openTimeoutCountsAsAFailedAttempt() async throws {
        let world = PlaybackWorld()
        world.scripts[.mpv] = [.hang, .play]
        let controller = world.makeController()
        controller.play(TestItems.live())
        #expect(await world.run(until: { controller.phase == .playing }, limit: 30))
        #expect(world.engine(.mpv)?.loads.count == 2)
        await controller.stop()
    }

    @Test func rapidZappingOnlyOpensTheChannelYouLandOn() async throws {
        let world = PlaybackWorld()
        await world.connections.setLimit(1, for: TestItems.a)
        let controller = world.makeController()
        for n in 1...10 {
            controller.play(TestItems.live("ch\(n)", sources: [TestItems.source(TestItems.a, n)]), debounce: true)
            await world.run(seconds: 0.1, step: 0.1)
        }
        #expect(await world.run(until: { controller.phase == .playing }))
        let engine = try #require(world.engine(.mpv))
        #expect(engine.loads.map { $0.url.deletingPathExtension().lastPathComponent } == ["10"])
        #expect(await world.connections.usage(for: TestItems.a).inUse == 1)
        await controller.stop()
        #expect(await world.connections.totalInUse == 0)
    }

    @Test func switchingChannelsClosesTheOldStreamFirst() async throws {
        let world = PlaybackWorld()
        await world.connections.setLimit(1, for: TestItems.a)
        let controller = world.makeController()
        for n in 1...5 {
            controller.play(TestItems.live("ch\(n)", sources: [TestItems.source(TestItems.a, n)]))
            #expect(await world.run(until: { controller.phase == .playing }))
        }
        #expect(world.counter.peak == 1)
        #expect(await world.connections.usage(for: TestItems.a).inUse == 1)
        await controller.stop()
        #expect(await world.connections.totalInUse == 0)
    }

    @Test func networkLossWaitsWithoutBurningAttemptsThenResumes() async throws {
        let world = PlaybackWorld()
        let controller = world.makeController()
        controller.play(TestItems.live())
        #expect(await world.run(until: { controller.phase == .playing }))
        let engine = try #require(world.engine(.mpv))

        world.system.send(.network(available: false))
        await world.settle()
        engine.emitFailure(EngineFailure(.network))
        #expect(await world.run(until: { controller.phase == .waitingForNetwork }))
        // Long outage: nothing is retried while offline.
        await world.run(seconds: 60, step: 1)
        #expect(engine.loads.count == 1)
        #expect(controller.phase == .waitingForNetwork)

        world.system.send(.network(available: true))
        #expect(await world.run(until: { controller.phase == .playing }))
        #expect(engine.loads.count == 2)
        await controller.stop()
    }

    @Test func sleepReleasesTheConnectionAndWakeResumes() async throws {
        let world = PlaybackWorld()
        let controller = world.makeController()
        controller.play(TestItems.live())
        #expect(await world.run(until: { controller.phase == .playing }))

        world.system.send(.willSleep)
        #expect(await world.run(until: { controller.phase == .suspended }))
        #expect(await world.connections.totalInUse == 0)
        #expect(world.counter.current == 0)

        world.system.send(.didWake)
        #expect(await world.run(until: { controller.phase == .playing }))
        #expect(await world.connections.totalInUse == 1)
        await controller.stop()
    }

    @Test func fullScreenTakesThePreviewsConnection() async throws {
        let world = PlaybackWorld()
        await world.connections.setLimit(1, for: TestItems.a)
        let preview = world.makeController(.preview)
        let main = world.makeController(.main)

        preview.play(TestItems.live())
        #expect(await world.run(until: { preview.phase == .playing }))

        main.play(TestItems.live())
        #expect(await world.run(until: { main.phase == .playing }))
        #expect(preview.phase == .preempted)
        #expect(world.engine(.mpv, for: .preview)?.stopCount ?? 0 >= 1)
        #expect(world.counter.peak == 1)
        #expect(await world.connections.usage(for: TestItems.a).purposes == [.main])

        await main.stop()
        await preview.stop()
        #expect(await world.connections.totalInUse == 0)
    }

    @Test func aStreamThatWasWorkingGetsAFreshBudgetAfterEachStall() async throws {
        var settings = PlaybackSettings()
        settings.attemptsPerRung = 2
        let world = PlaybackWorld()
        let controller = world.makeController(settings: settings)
        controller.play(TestItems.live())
        #expect(await world.run(until: { controller.phase == .playing }))
        let engine = try #require(world.engine(.mpv))
        for _ in 0..<4 {
            await world.run(seconds: 30, step: 1) // plays fine for a while
            engine.flowing = false
            #expect(await world.run(until: { controller.phase.isRecovering }, limit: 12))
            #expect(await world.run(until: { controller.phase == .playing }, limit: 12))
        }
        // Never fell back to another format: each stall was retried on the working rung.
        #expect(Set(engine.loadedFormats) == ["ts"])
        await controller.stop()
    }

    @Test func movieEndsCleanly() async throws {
        let world = PlaybackWorld()
        let controller = world.makeController()
        controller.play(TestItems.movie())
        #expect(await world.run(until: { controller.phase == .playing }))
        world.engine(.mpv)?.emitEnd()
        #expect(await world.run(until: { controller.phase == .ended }))
        #expect(await world.connections.totalInUse == 0)
    }

    @Test func liveEndOfStreamIsTreatedAsADrop() async throws {
        let world = PlaybackWorld()
        let controller = world.makeController()
        controller.play(TestItems.live())
        #expect(await world.run(until: { controller.phase == .playing }))
        world.engine(.mpv)?.emitEnd()
        #expect(await world.run(until: { controller.phase.isRecovering }))
        #expect(await world.run(until: { controller.phase == .playing }))
        await controller.stop()
    }

    @Test func randomisedChaosNeverLeaksConnections() async throws {
        let world = PlaybackWorld()
        await world.connections.setLimit(2, for: TestItems.a)
        await world.connections.setLimit(1, for: TestItems.b)
        let controllers = [world.makeController(.main), world.makeController(.preview), world.makeController(.tile(1))]
        var rng = SeededGenerator(seed: 42)
        let items = (1...6).map { n in
            TestItems.live("ch\(n)", sources: [TestItems.source(TestItems.a, n, priority: 0), TestItems.source(TestItems.b, 100 + n, priority: 1)])
        }
        for _ in 0..<150 {
            let controller = controllers.randomElement(using: &rng)!
            switch Int.random(in: 0..<6, using: &rng) {
            case 0, 1: controller.play(items.randomElement(using: &rng)!, debounce: Bool.random(using: &rng))
            case 2: await controller.stop()
            case 3:
                for kind in EngineKind.allCases {
                    world.engine(kind, for: controller.purpose)?.flowing = false
                }
            case 4: world.engine(.mpv, for: controller.purpose)?.emitFailure(EngineFailure(.network))
            default: break
            }
            await world.run(seconds: Double.random(in: 0.25...3, using: &rng))
            let usage = await world.connections.snapshot()
            #expect((usage[TestItems.a]?.inUse ?? 0) <= 2)
            #expect((usage[TestItems.b]?.inUse ?? 0) <= 1)
        }
        for controller in controllers { await controller.stop() }
        await world.settle()
        #expect(await world.connections.totalInUse == 0)
        #expect(world.counter.current == 0)
    }
}

/// Deterministic RNG so the chaos test is reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
