import Foundation
@testable import IPTVCore

/// A clock whose sleeps suspend until the test advances time past their deadline.
final class TestClock: AppClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var waiters: [UUID: (deadline: Date, continuation: CheckedContinuation<Void, Error>)] = [:]

    init(_ start: Date = .fixtureNow) { current = start }

    func now() -> Date { lock.withLock { current } }

    func sleep(for duration: Duration) async throws {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                let deadline = current.addingTimeInterval(seconds)
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if seconds <= 0 {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters[id] = (deadline, continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward and wakes every sleeper whose deadline has passed.
    func advance(by seconds: Double) {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            current.addTimeInterval(seconds)
            let ready = waiters.filter { $0.value.deadline <= current }
            for key in ready.keys { waiters.removeValue(forKey: key) }
            return ready.values.sorted { $0.deadline < $1.deadline }.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }
}

/// Counts streams open across all fake engines, to prove close-before-open.
final class StreamCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var open = 0
    private var peakValue = 0

    var current: Int { lock.withLock { open } }
    var peak: Int { lock.withLock { peakValue } }

    func opened() { lock.withLock { open += 1; peakValue = max(peakValue, open) } }
    func closed() { lock.withLock { open = max(0, open - 1) } }
    func resetPeak() { lock.withLock { peakValue = open } }
}

/// Scriptable engine. Each `load` takes the next behaviour from `script` (the last one repeats).
@MainActor
final class FakeEngine: PlaybackEngine {
    enum Behavior: Equatable {
        /// Emits `.playing` right away and then makes progress on every metrics sample.
        case play
        case fail(EngineFailure)
        /// Never starts (tests the open timeout).
        case hang
    }

    let kind: EngineKind
    let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation
    private let counter: StreamCounter

    var script: [Behavior]
    private(set) var loads: [EngineRequest] = []
    private(set) var stopCount = 0
    private(set) var loadID = 0
    private var isOpen = false
    /// When false, metrics stop advancing (a stall).
    var flowing = true
    private var position = 0.0

    var volume = 1.0
    var isMuted = false

    init(kind: EngineKind, script: [Behavior] = [.play], counter: StreamCounter) {
        self.kind = kind
        self.script = script
        self.counter = counter
        (events, continuation) = AsyncStream<EngineEvent>.makeStream()
    }

    @discardableResult
    func load(_ request: EngineRequest) -> Int {
        if isOpen { counter.closed() }
        loadID += 1
        loads.append(request)
        isOpen = true
        counter.opened()
        flowing = true
        position = 0
        let behavior = script.isEmpty ? .play : script.removeFirstOrLast()
        switch behavior {
        case .play:
            continuation.yield(EngineEvent(loadID: loadID, .playing))
        case .fail(let failure):
            continuation.yield(EngineEvent(loadID: loadID, .failed(failure)))
        case .hang:
            break
        }
        return loadID
    }

    func play() { continuation.yield(EngineEvent(loadID: loadID, .playing)) }
    func pause() { continuation.yield(EngineEvent(loadID: loadID, .paused)) }

    func stop() async {
        stopCount += 1
        if isOpen {
            isOpen = false
            counter.closed()
        }
        await Task.yield()
    }

    func seek(to seconds: Double) { position = seconds }
    func tracks() -> [MediaTrack] { [] }
    func select(_ track: MediaTrack?, kind: MediaTrack.Kind) {}
    func shutdown() { continuation.finish() }

    func metrics() -> PlaybackMetrics {
        if isOpen && flowing { position += 1 }
        return PlaybackMetrics(engine: kind, position: position, bufferSeconds: flowing ? 5 : 0)
    }

    /// Simulates the engine reporting an error on the current stream.
    func emitFailure(_ failure: EngineFailure) {
        continuation.yield(EngineEvent(loadID: loadID, .failed(failure)))
    }

    func emitEnd() {
        continuation.yield(EngineEvent(loadID: loadID, .endOfStream))
    }

    var loadedFormats: [String] { loads.map { $0.url.pathExtension } }
}

extension Array {
    mutating func removeFirstOrLast() -> Element {
        count > 1 ? removeFirst() : self[0]
    }
}

/// Builds URLs like `http://<provider>.test/live/<item>.<format>`.
struct FakeResolver: StreamURLResolver {
    func url(for source: PlaybackSource, content: PlaybackItem.Content, format: StreamFormat?) throws -> URL {
        URL(string: "http://\(source.providerID.rawValue).test/\(content.rawValue)/user/secret/\(source.itemID).\(format?.rawValue ?? source.containerExtension ?? "mp4")")!
    }
    func userAgent(for providerID: ProviderID) -> String { "Test" }
    func redactionCredentials(for providerID: ProviderID) -> [ProviderCredentials] {
        [ProviderCredentials(username: "user", password: "secret")]
    }
}

final class RecordingHistory: PlaybackHistoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var successes: [PlaybackPlan] = []
    private(set) var failures: [PlaybackPlan] = []

    func recordSuccess(_ plan: PlaybackPlan) async { lock.withLock { successes.append(plan) } }
    func recordFailure(_ plan: PlaybackPlan, error: EngineFailure) async { lock.withLock { failures.append(plan) } }
}

/// System events the test can push.
final class TestSystemEvents: SystemEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<SystemEvent>.Continuation] = []

    func events() -> AsyncStream<SystemEvent> {
        let (stream, continuation) = AsyncStream<SystemEvent>.makeStream()
        lock.withLock { continuations.append(continuation) }
        return stream
    }

    func send(_ event: SystemEvent) {
        lock.withLock { continuations }.forEach { $0.yield(event) }
    }
}

/// One test world: clock, connections, engines and helpers to drive time.
@MainActor
final class PlaybackWorld {
    let clock = TestClock()
    let connections = ConnectionManager()
    let counter = StreamCounter()
    let history = RecordingHistory()
    let system = TestSystemEvents()
    /// Engines created per controller purpose and kind.
    private(set) var engines: [String: FakeEngine] = [:]
    /// Scripts applied to engines when they're created, by kind.
    var scripts: [EngineKind: [FakeEngine.Behavior]] = [:]

    func engine(_ kind: EngineKind, for purpose: ConnectionPurpose = .main) -> FakeEngine? {
        engines["\(purpose)-\(kind.rawValue)"]
    }

    func makeController(_ purpose: ConnectionPurpose = .main, settings: PlaybackSettings = PlaybackSettings()) -> PlaybackController {
        let deps = PlaybackDependencies(
            connections: connections, resolver: FakeResolver(), history: history, systemEvents: system, clock: clock,
            makeEngine: { [unowned self] kind in
                let engine = FakeEngine(kind: kind, script: self.scripts[kind] ?? [.play], counter: self.counter)
                self.engines["\(purpose)-\(kind.rawValue)"] = engine
                return engine
            },
            random: { 1 })
        return PlaybackController(purpose: purpose, settings: settings, dependencies: deps)
    }

    /// Lets queued main-actor work run.
    func settle() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// Advances time in small steps, letting work run between them.
    func run(seconds: Double, step: Double = 0.25) async {
        await settle()
        var elapsed = 0.0
        while elapsed < seconds {
            clock.advance(by: step)
            elapsed += step
            await settle()
        }
    }

    /// Runs until `condition` holds or `limit` simulated seconds pass. Returns whether it held.
    @discardableResult
    func run(until condition: () -> Bool, limit: Double = 120) async -> Bool {
        await settle()
        var elapsed = 0.0
        while !condition() && elapsed < limit {
            clock.advance(by: 0.25)
            elapsed += 0.25
            await settle()
        }
        return condition()
    }
}

enum TestItems {
    static let a = ProviderID("prov-a")
    static let b = ProviderID("prov-b")

    static func source(_ provider: ProviderID, _ id: Int, priority: Int = 0, formats: [StreamFormat] = [.ts, .m3u8]) -> PlaybackSource {
        PlaybackSource(providerID: provider, itemID: String(id), providerName: provider == a ? "Provider A" : "Provider B",
                       providerPriority: priority, allowedFormats: formats)
    }

    static func live(_ id: String = "epg:test", sources: [PlaybackSource]? = nil) -> PlaybackItem {
        PlaybackItem(id: id, title: id, content: .live, sources: sources ?? [source(a, 1)])
    }

    static func movie(ext: String = "mp4") -> PlaybackItem {
        var source = source(a, 500)
        source.containerExtension = ext
        return PlaybackItem(id: "movie:a:500", title: "Film", content: .movie, sources: [source])
    }
}
